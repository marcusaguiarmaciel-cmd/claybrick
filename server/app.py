"""
Claude Studio Bridge
====================
Servidor-ponte entre o plugin do Roblox Studio e o Claude.

A lógica do agente mora em agent/. Este arquivo é só a casca HTTP: recebe
mensagens, entrega eventos por long-poll e recolhe resultados de ferramenta.

Rode com:  .\run.ps1
"""

import asyncio
import socket
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from agent import config
from agent.apidump import DUMP
from agent.backends import anthropic_client, loop_for
from agent.luau_check import ANALYZER
from agent.session import Session
from agent.tools import TOOL_DEFS

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Aquece o API dump em background: a primeira chamada de lookup_api não
    # precisa esperar 4 MB de download.
    #
    # A referência da task fica guardada de propósito: o asyncio só mantém uma
    # referência fraca às tasks em execução, e sem isto o coletor de lixo pode
    # cancelar o download no meio.
    warmup = asyncio.create_task(DUMP.ensure_loaded())
    app.state.warmup = warmup
    yield


app = FastAPI(title="Claude Studio Bridge", lifespan=lifespan)

SESSIONS: Dict[str, Session] = {}


# --------------------------------------------------------------------------- #
# Quem pode falar com a ponte
# --------------------------------------------------------------------------- #
# Aqui existia um `CORSMiddleware(allow_origins=["*"])`, e ele era um buraco de
# verdade: qualquer site que o usuário abrisse no navegador podia fazer POST em
# 127.0.0.1 e mandar o Claude escrever script, rodar código e apagar coisa no
# place aberto. Bastava visitar a página errada.
#
# Tirar o CORS sozinho NÃO resolveria. O CORS decide quem pode LER a resposta,
# não quem pode ENVIAR: requisições "simples" (e um POST com JSON, depois do
# preflight liberado pelo curinga) chegam no servidor e o efeito colateral
# acontece de qualquer jeito, mesmo que o navegador jogue a resposta fora.
#
# O que resolve é notar que a ponte nunca deveria receber nada de um navegador.
# Quem fala com ela é o plugin, e o HttpService do Roblox não é um navegador: ele
# não manda Origin nem Sec-Fetch-*. Então esses cabeçalhos são a assinatura de
# quem não deveria estar aqui.
_BROWSER_FETCH = {"cross-site", "same-site", "same-origin"}


@app.middleware("http")
async def block_browser_requests(request: Request, call_next):
    origin = request.headers.get("origin")
    fetch_site = (request.headers.get("sec-fetch-site") or "").lower()

    # `sec-fetch-site: none` é a pessoa digitando a URL na barra de endereço —
    # é assim que o README manda conferir o /health, e é inofensivo. O que se
    # bloqueia é página chamando a ponte por trás.
    if origin or fetch_site in _BROWSER_FETCH:
        return JSONResponse(
            status_code=403,
            content={
                "detail": "A ponte só aceita o plugin do Studio. Uma página web "
                          "não deveria estar falando com ela."
            },
        )
    return await call_next(request)


def ensure_worker(session: Session) -> None:
    if session.worker is None or session.worker.done():
        session.worker = asyncio.create_task(loop_for(session.backend)(session))


async def stop_session(session_id: str) -> None:
    s = SESSIONS.pop(session_id, None)
    if not s:
        return
    s.cancelled = True
    for fut in s.pending.values():
        if not fut.done():
            fut.set_result(("Sessão encerrada.", True))
    if s.worker and not s.worker.done():
        await s.inbox.put(None)  # encerra o worker (fecha o cliente da assinatura)
        s.worker.cancel()
        try:
            await s.worker
        except BaseException:
            pass


# --------------------------------------------------------------------------- #
# Modelos de request
# --------------------------------------------------------------------------- #
class MessageIn(BaseModel):
    session_id: str
    message: str
    backend: Optional[str] = None
    place_context: Optional[str] = None


class ToolResultIn(BaseModel):
    session_id: str
    id: str
    content: str
    is_error: bool = False


class SessionIn(BaseModel):
    session_id: str


# --------------------------------------------------------------------------- #
# Endpoints
# --------------------------------------------------------------------------- #
@app.get("/health")
def health() -> Dict[str, Any]:
    try:
        import claude_agent_sdk  # noqa: F401
        sub_ok = True
    except ImportError:
        sub_ok = False
    return {
        "ok": True,
        # Assinatura. O plugin varre uma faixa de portas procurando a ponte, e
        # precisa distinguir "achei o Claybrick" de "achei um servidor local
        # qualquer que também responde /health". Sem isto ele poderia grudar no
        # servidor errado e falhar de um jeito muito confuso.
        "service": "claybrick",
        # A versão dos arquivos em disco. O plugin compara com a dele: se o
        # servidor já está numa versão nova e o plugin não, é porque o
        # instalador rodou e o Studio ainda está com o plugin velho na memória —
        # aí a única coisa que falta é reiniciar o Studio, e ele avisa isso.
        "version": config.VERSION,
        "default_backend": config.DEFAULT_BACKEND,
        "api_available": anthropic_client is not None,
        "api_model": config.API_MODEL,
        "effort": config.EFFORT,
        "subscription_available": sub_ok,
        "sessions": len(SESSIONS),
        "tools": len(TOOL_DEFS),
        "api_dump": DUMP.status,
        # O analisador é baixado sob demanda, na primeira checagem de sintaxe.
        # "ready: false" aqui logo após subir é o normal, não é falha.
        "luau_analyzer": ANALYZER.status,
    }


@app.get("/tools")
def tools() -> Dict[str, Any]:
    """As ferramentas e suas classes de permissão. O plugin lê isto ao iniciar
    para saber o que perguntar antes de executar."""
    return {
        "tools": [
            {"name": d["name"], "permission": d["permission"]} for d in TOOL_DEFS
        ]
    }


@app.post("/session/message")
async def session_message(body: MessageIn) -> Dict[str, Any]:
    backend = (body.backend or config.DEFAULT_BACKEND).lower()
    if backend not in ("api", "subscription"):
        raise HTTPException(400, "backend inválido (use 'api' ou 'subscription')")

    s = SESSIONS.get(body.session_id)
    if s is not None and s.backend != backend:
        await stop_session(body.session_id)
        s = None
    if s is None:
        s = Session(backend)
        SESSIONS[body.session_id] = s
    if s.busy or not s.inbox.empty():
        raise HTTPException(409, "Já há uma resposta em andamento nesta sessão.")

    if body.place_context:
        s.place_context = body.place_context
    ensure_worker(s)
    await s.inbox.put(body.message)
    return {"ok": True, "backend": backend}


@app.get("/session/poll")
async def session_poll(session_id: str) -> Dict[str, Any]:
    s = SESSIONS.get(session_id)
    if s is None:
        return {"type": "idle"}
    try:
        return await asyncio.wait_for(s.out.get(), timeout=config.POLL_TIMEOUT)
    except asyncio.TimeoutError:
        return {"type": "wait"}


@app.post("/session/tool_result")
async def session_tool_result(body: ToolResultIn) -> Dict[str, Any]:
    s = SESSIONS.get(body.session_id)
    if s is None:
        raise HTTPException(400, "Sessão desconhecida.")
    fut = s.pending.pop(body.id, None)
    if fut and not fut.done():
        fut.set_result((body.content, body.is_error))
    return {"ok": True}


@app.post("/session/cancel")
async def session_cancel(body: SessionIn) -> Dict[str, Any]:
    """Para o turno atual sem perder o histórico da conversa."""
    s = SESSIONS.get(body.session_id)
    if s is None:
        return {"ok": True}
    s.cancelled = True
    for fut in list(s.pending.values()):
        if not fut.done():
            fut.set_result(("Cancelado pelo usuário.", True))
    s.pending.clear()
    if s.turn and not s.turn.done():
        s.turn.cancel()
    return {"ok": True}


@app.post("/session/reset")
async def session_reset(body: SessionIn) -> Dict[str, Any]:
    await stop_session(body.session_id)
    return {"ok": True}


# --------------------------------------------------------------------------- #
# Porta
# --------------------------------------------------------------------------- #
# A porta preferida vive ocupada em máquina real: outro dev server, uma instância
# antiga da própria ponte, ou — no Windows — um serviço do sistema segurando
# 0.0.0.0:PORTA (o que faz o bind em 127.0.0.1 falhar com "acesso negado", e não
# com "porta em uso"). Exigir que o usuário edite o .env E a URL do plugin para
# contornar isso é perder a pessoa na primeira tentativa.
#
# Então: o servidor anda até a primeira porta livre da faixa, e o plugin varre a
# MESMA faixa até achar quem responde com a assinatura do /health. Ninguém
# configura nada.
#
# Os dois lados precisam concordar nesta faixa: se mexer aqui, mexa no
# PORT_BASE/PORT_SPAN do plugin (plugin/ClaudeStudio.luau).
PORT_SPAN = 10


def _can_bind(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind((host, port))
            return True
        except OSError:
            return False


def _pick_port() -> Optional[int]:
    for port in range(config.PORT, config.PORT + PORT_SPAN):
        if _can_bind(config.HOST, port):
            return port
    return None


def _warn_if_exposed() -> None:
    """
    A ponte não tem autenticação: quem alcança ela manda no Studio. Isso é
    aceitável porque ela só escuta em 127.0.0.1 — nada fora da máquina chega.
    Mas HOST é editável no .env, e um `HOST=0.0.0.0` transforma isso em "qualquer
    um na mesma rede escreve script e roda código no seu place". Ninguém faz essa
    troca entendendo o preço, então é preciso dizer o preço.
    """
    host = config.HOST.strip()
    if host in ("127.0.0.1", "localhost", "::1"):
        return
    print(
        f"\n  AVISO DE SEGURANÇA: HOST={host} — a ponte vai aceitar conexões de fora"
        "\n  desta máquina, e ela NÃO tem senha: quem alcançar ela manda no seu"
        "\n  Studio (escrever scripts, rodar código, apagar coisas)."
        "\n"
        "\n  Se não foi de propósito, ponha HOST=127.0.0.1 no .env.\n",
        flush=True,
    )


if __name__ == "__main__":
    import uvicorn

    _warn_if_exposed()
    port = _pick_port()

    if port is None:
        last = config.PORT + PORT_SPAN - 1
        print()
        print(f"  Nenhuma porta livre entre {config.PORT} e {last} — a ponte não sobe.")
        print()
        print("  Para ver quem está ocupando (num PowerShell):")
        print(f"      {config.PORT}..{last} | %{{ Get-NetTCPConnection -LocalPort $_ -EA SilentlyContinue }}")
        print()
        print("  Dá para apontar para outra faixa com PORT=<numero> no .env — mas aí")
        print("  o plugin não acha sozinho, e você precisa pôr a URL na caixa dele.")
        print()
        raise SystemExit(1)

    if port != config.PORT:
        # Não é erro, é o contorno funcionando. Mas some no meio dos logs do
        # uvicorn se não gritar, e a pessoa merece saber por que a porta mudou.
        #
        # flush porque o Python bufferiza stdout quando a saída não é um
        # terminal: sem isto a mensagem se perde justamente quando alguém está
        # capturando o log para entender o que aconteceu.
        print(
            f"\n  A porta {config.PORT} está ocupada. Subindo na {port}."
            "\n  Não precisa fazer nada: o plugin procura a ponte e acha sozinho.\n",
            flush=True,
        )

    uvicorn.run(app, host=config.HOST, port=port)
