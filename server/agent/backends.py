"""
Backends
========
- "api"          -> chave da API da Anthropic (pago por token).
- "subscription" -> Claude Agent SDK, rodando o Claude Code logado na assinatura
                    Pro/Max do usuário (cota da assinatura).

Os dois usam o MESMO system prompt e as MESMAS ferramentas. A diferença é só
quem paga e quem roda o loop do agente.
"""

import asyncio
import atexit
import contextvars
import os
import tempfile
from typing import Any, Dict, List, Optional

from . import config
from .prompt import build_system_prompt
from .session import Session, call_tool
from .tools import TOOL_DEFS, api_tool_defs


# --------------------------------------------------------------------------- #
# Backend "api"
# --------------------------------------------------------------------------- #
try:
    from anthropic import AsyncAnthropic

    anthropic_client = AsyncAnthropic(api_key=config.API_KEY) if config.API_KEY else None
except ImportError:
    anthropic_client = None


def _system_blocks(session: Session) -> List[Dict[str, Any]]:
    """
    System prompt como blocos, com o breakpoint de cache no fim.

    O prompt (identidade + método + guias de Luau/arquitetura) passa de 4096
    tokens, que é o mínimo cacheável do Opus 4.8 — então o cache pega. Ele é
    byte-idêntico entre requisições da sessão, o que é o requisito: cache é
    prefix match, e qualquer byte diferente invalida tudo depois.

    Por isso o contexto do place NÃO entra aqui: ele muda, e mudaria o prefixo.
    Vai como mensagem `role: "system"` no fim do histórico (ver run_api_turn).
    """
    return [{
        "type": "text",
        "text": build_system_prompt(),
        "cache_control": {"type": "ephemeral"},
    }]


# --------------------------------------------------------------------------- #
# Compactação
# --------------------------------------------------------------------------- #
COMPACT_BETA = "compact-2026-01-12"

# Compactação é beta e só existe nestes modelos. Mandar o beta em qualquer outro
# derruba a requisição inteira — então, fora da lista, a gente não manda (e a
# conversa volta a crescer até estourar o contexto).
COMPACT_MODELS = (
    "claude-fable-5", "claude-mythos-5",
    "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
    "claude-sonnet-5", "claude-sonnet-4-6",
)
COMPACTION_ON = config.API_MODEL in COMPACT_MODELS


def _move_cache_breakpoint(messages: List[Dict[str, Any]]) -> None:
    """
    Deixa um único breakpoint de cache no fim do histórico, e move ele a cada
    volta do loop.

    Sem isto só o system prompt é cacheado, e a conversa inteira — que num turno
    agêntico vira dezenas de tool_results — é reprocessada a preço cheio a cada
    requisição. Com ele, o prefixo escrito na volta anterior é lido a 0,1x.

    Um breakpoint rolante basta: cache é prefix match, então a entrada gravada na
    volta anterior é justamente um prefixo desta. Marcar o bloco antigo também
    só gastaria um dos 4 breakpoints por requisição.
    """
    for msg in messages:
        content = msg.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    block.pop("cache_control", None)

    for msg in reversed(messages):
        content = msg.get("content")
        # As mensagens `role: "system"` têm content de texto puro, sem blocos —
        # não dá para marcar, então o breakpoint recua para a mensagem anterior.
        if isinstance(content, list) and content and isinstance(content[-1], dict):
            content[-1]["cache_control"] = {"type": "ephemeral"}
            return


def _usage_totals(usage: Any) -> Dict[str, int]:
    """
    Soma as iterações da requisição.

    Com compactação ligada, um único request pode render várias iterações (a
    compactação é uma delas) — e o usage de topo conta só as que não são
    compactação. Somar `iterations` é a única contagem fiel do que foi cobrado.
    """
    def field(obj: Any, name: str) -> Any:
        value = obj.get(name) if isinstance(obj, dict) else getattr(obj, name, None)
        return value or 0

    iterations = field(usage, "iterations")
    totals = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}
    for part in (iterations or [usage]):
        totals["input"] += field(part, "input_tokens")
        totals["output"] += field(part, "output_tokens")
        totals["cache_read"] += field(part, "cache_read_input_tokens")
        totals["cache_write"] += field(part, "cache_creation_input_tokens")
    return totals


def _close_dangling_tools(session: Session) -> None:
    """
    Fecha ferramentas que ficaram penduradas quando o turno morreu no meio.

    Um cancelamento ou um erro de rede pode parar o loop com a última mensagem do
    assistente pedindo ferramentas que nunca receberam resultado. A API recusa
    (400) toda mensagem seguinte de uma conversa nesse estado — ou seja, a sessão
    fica inutilizável, o oposto do que /session/cancel promete. Os resultados
    saem todos numa mensagem só, então é tudo ou nada: se a última mensagem é do
    assistente e tem tool_use, nenhum resultado chegou.
    """
    messages = session.messages
    if not messages or messages[-1].get("role") != "assistant":
        return
    content = messages[-1].get("content")
    if not isinstance(content, list):
        return
    dangling = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"]
    if not dangling:
        return
    messages.append({"role": "user", "content": [
        {
            "type": "tool_result",
            "tool_use_id": b["id"],
            "content": "O turno foi interrompido antes desta ferramenta rodar.",
            "is_error": True,
        }
        for b in dangling
    ]})


async def run_api_turn(session: Session, user_message: str) -> None:
    session.messages.append({"role": "user", "content": user_message})

    # O contexto do place é volátil, então vai DEPOIS do histórico cacheado,
    # como instrução de operador. Isso preserva o prefixo (a alternativa —
    # reescrever o system prompt — invalidaria o cache da conversa inteira).
    if session.place_context:
        session.messages.append({
            "role": "system",
            "content": "Contexto do place aberto agora:\n\n" + session.place_context,
        })
        session.place_context = None

    while True:
        if session.cancelled:
            return

        _move_cache_breakpoint(session.messages)

        kwargs: Dict[str, Any] = dict(
            model=config.API_MODEL,
            max_tokens=config.MAX_TOKENS,
            system=_system_blocks(session),
            tools=api_tool_defs(),
            messages=session.messages,
            thinking={"type": "adaptive", "display": "summarized"},
            output_config={"effort": config.EFFORT},
        )

        # Compactação: quando o histórico passa de COMPACT_AT tokens de entrada,
        # o servidor resume a conversa antiga sozinho e devolve o resumo como um
        # bloco `compaction`. A partir daí ele descarta o que veio antes do bloco
        # e continua do resumo — sem isto a sessão morre de 400 ao encher o
        # contexto. O gatilho é checado no início de cada iteração de sampling,
        # então um turno agêntico longo pode compactar mais de uma vez sozinho.
        if COMPACTION_ON:
            kwargs["betas"] = [COMPACT_BETA]
            kwargs["context_management"] = {
                "edits": [{
                    "type": "compact_20260112",
                    "trigger": {"type": "input_tokens", "value": config.COMPACT_AT},
                }]
            }

        # Streaming: max_tokens é grande e um turno agêntico é longo — sem stream
        # a requisição bate no timeout de HTTP. Também deixa o raciocínio e o
        # texto aparecerem no chat enquanto acontecem.
        async with anthropic_client.beta.messages.stream(**kwargs) as stream:
            async for event in stream:
                if session.cancelled:
                    break
                if event.type == "content_block_delta":
                    if event.delta.type == "thinking_delta":
                        await session.out.put({"type": "thinking", "text": event.delta.thinking})
                    elif event.delta.type == "text_delta":
                        await session.out.put({"type": "text", "text": event.delta.text})
                    elif event.delta.type == "compaction_delta":
                        # O resumo chega inteiro num delta só, não token a token.
                        await session.out.put({"type": "compaction"})
            resp = await stream.get_final_message()

        # O content vai INTEIRO de volta para o histórico, com o bloco de
        # compactação junto: é ele que a API usa para substituir o que foi
        # compactado. Filtrar só o texto perderia o resumo em silêncio.
        content = [b.model_dump() for b in resp.content]
        session.messages.append({"role": "assistant", "content": content})

        await session.out.put({"type": "usage", **_usage_totals(resp.usage)})

        if resp.stop_reason == "refusal":
            await session.out.put({"type": "error", "message": "O modelo recusou este pedido."})
            return

        tool_uses = [b for b in content if b.get("type") == "tool_use"]
        if not tool_uses:
            return

        # Todos os resultados voltam numa ÚNICA mensagem de usuário — separá-los
        # ensina o modelo a parar de paralelizar.
        results = []
        for tu in tool_uses:
            c, err = await call_tool(session, tu["name"], tu.get("input") or {}, config.TOOL_TIMEOUT)
            results.append({
                "type": "tool_result",
                "tool_use_id": tu["id"],
                "content": c,
                "is_error": err,
            })
        session.messages.append({"role": "user", "content": results})


async def api_loop(session: Session) -> None:
    while True:
        user_msg = await session.inbox.get()
        if user_msg is None:
            return
        session.busy = True
        session.cancelled = False
        try:
            if anthropic_client is None:
                await session.out.put({
                    "type": "error",
                    "message": "ANTHROPIC_API_KEY não configurada em server/.env — "
                               "ou use o backend Assinatura.",
                })
            else:
                session.turn = asyncio.current_task()
                await run_api_turn(session, user_msg)
        except asyncio.CancelledError:
            await session.out.put({"type": "error", "message": "Cancelado."})
        except Exception as exc:
            await session.out.put({"type": "error", "message": f"Erro API: {type(exc).__name__}: {exc}"})
        # Vale para todo turno que não terminou sozinho — cancelamento, erro de
        # rede, timeout. É no-op quando o histórico já está fechado.
        _close_dangling_tools(session)
        session.turn = None
        await session.out.put({"type": "done"})
        session.busy = False


# --------------------------------------------------------------------------- #
# Backend "subscription"
# --------------------------------------------------------------------------- #
_current_session: contextvars.ContextVar = contextvars.ContextVar("current_session")

# O agente do Claude Code fica TRAVADO nas ferramentas do Roblox. Sem isto ele
# teria Bash/Read/Write no PC do usuário — que não é o que ninguém pediu.
DISALLOWED_TOOLS = [
    "Bash", "BashOutput", "KillShell", "Read", "Write", "Edit", "MultiEdit",
    "NotebookEdit", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "TodoWrite",
    "ExitPlanMode", "Agent",
]

_sub_server = None
_sub_allowed: List[str] = []
_sub_ready = False


def _ensure_subscription() -> None:
    global _sub_server, _sub_allowed, _sub_ready
    if _sub_ready:
        return
    try:
        from claude_agent_sdk import tool as sdk_tool, create_sdk_mcp_server
    except ImportError as exc:
        raise RuntimeError("claude-agent-sdk não instalado. Rode: pip install claude-agent-sdk") from exc

    def make_tool(defn):
        name = defn["name"]

        @sdk_tool(name, defn["description"], defn["input_schema"])
        async def handler(args):
            session = _current_session.get()
            content, is_error = await call_tool(session, name, args, config.TOOL_TIMEOUT)
            return {"content": [{"type": "text", "text": content}], "is_error": is_error}

        return handler

    tools = [make_tool(d) for d in TOOL_DEFS]
    _sub_server = create_sdk_mcp_server(name="roblox", version="2.0.0", tools=tools)
    _sub_allowed = [f"mcp__roblox__{d['name']}" for d in TOOL_DEFS]
    _sub_ready = True


_PROMPT_FILE: Optional[str] = None


def _subscription_system_prompt():
    """
    O prompt vai num ARQUIVO, não numa string.

    O SDK roda o Claude Code como subprocesso e passa `--system-prompt <texto>` na
    linha de comando. O Windows corta a linha de comando em 32.767 caracteres, e
    o nosso prompt (identidade + método + os guias de Luau, orientação, Studio,
    modelagem e arquitetura) passa disso. O CreateProcess falha, e o SDK traduz o
    erro como "Claude Code not found at: ..." — apontando para um executável que
    está lá, inteiro. Ou seja: a mensagem mente, e o backend inteiro morre sem
    explicação.

    `--system-prompt-file` passa só o caminho. O prompt pode crescer à vontade.
    """
    global _PROMPT_FILE
    texto = build_system_prompt()

    # SDK antigo não conhece o formato de arquivo: receberia o dict, não casaria
    # com nenhum ramo, e o agente rodaria SEM system prompt — sem erro, só
    # burro. Melhor voltar para a string (que pode estourar a linha de comando,
    # mas falha alto em vez de baixo).
    try:
        from claude_agent_sdk.types import SystemPromptFile  # noqa: F401
    except Exception:
        return texto

    if _PROMPT_FILE is None:
        fd, caminho = tempfile.mkstemp(prefix="claybrick-prompt-", suffix=".md", text=True)
        os.close(fd)
        _PROMPT_FILE = caminho
        atexit.register(lambda: _remover(caminho))

    with open(_PROMPT_FILE, "w", encoding="utf-8") as fh:
        fh.write(texto)
    return {"type": "file", "path": _PROMPT_FILE}


def _remover(caminho: str) -> None:
    try:
        os.unlink(caminho)
    except OSError:
        pass


async def _drain_with_error(session: Session, msg: str) -> None:
    while True:
        user_msg = await session.inbox.get()
        if user_msg is None:
            return
        session.busy = True
        await session.out.put({"type": "error", "message": msg})
        await session.out.put({"type": "done"})
        session.busy = False


async def subscription_loop(session: Session) -> None:
    try:
        _ensure_subscription()
        from claude_agent_sdk import (
            ClaudeAgentOptions, ClaudeSDKClient, AssistantMessage, TextBlock,
            ThinkingBlock,
        )
    except Exception as exc:
        await _drain_with_error(session, f"Assinatura indisponível: {exc}")
        return

    _current_session.set(session)

    opt_kwargs: Dict[str, Any] = dict(
        system_prompt=_subscription_system_prompt(),
        mcp_servers={"roblox": _sub_server},
        allowed_tools=list(_sub_allowed),
        disallowed_tools=list(DISALLOWED_TOOLS),
        permission_mode="default",
        max_turns=config.MAX_TURNS,
    )
    if config.SUBSCRIPTION_MODEL:
        opt_kwargs["model"] = config.SUBSCRIPTION_MODEL

    try:
        options = ClaudeAgentOptions(**opt_kwargs)
    except TypeError:
        opt_kwargs.pop("model", None)
        options = ClaudeAgentOptions(**opt_kwargs)

    try:
        async with ClaudeSDKClient(options=options) as client:
            while True:
                user_msg = await session.inbox.get()
                if user_msg is None:
                    return
                session.busy = True
                session.cancelled = False
                if session.place_context:
                    user_msg = (
                        "Contexto do place aberto agora:\n\n"
                        + session.place_context
                        + "\n\n---\n\n"
                        + user_msg
                    )
                    session.place_context = None
                try:
                    await client.query(user_msg)
                    async for msg in client.receive_response():
                        if session.cancelled:
                            break
                        if isinstance(msg, AssistantMessage):
                            # O raciocínio é cobrado como saída de qualquer jeito, exibido
                            # ou não. Filtrar só TextBlock escondia de graça o que o
                            # usuário já pagou para o modelo pensar.
                            for b in msg.content:
                                if isinstance(b, ThinkingBlock):
                                    pensou = (getattr(b, "thinking", "") or "").strip()
                                    if pensou:
                                        await session.out.put({"type": "thinking", "text": pensou})
                            text = "\n".join(
                                b.text for b in msg.content if isinstance(b, TextBlock)
                            ).strip()
                            if text:
                                await session.out.put({"type": "message", "text": text})
                except Exception as exc:
                    await session.out.put({
                        "type": "error",
                        "message": f"Erro assinatura: {type(exc).__name__}: {exc}",
                    })
                await session.out.put({"type": "done"})
                session.busy = False
    except Exception as exc:
        await _drain_with_error(session, f"Falha ao iniciar assinatura: {exc}")


def loop_for(backend: str):
    return subscription_loop if backend == "subscription" else api_loop
