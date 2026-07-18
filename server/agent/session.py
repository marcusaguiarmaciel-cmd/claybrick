"""
Sessões e a ponte de ferramentas
================================
O plugin do Studio só faz requisições de SAÍDA (não dá para o servidor chamar o
Studio). Então invertemos: o servidor enfileira "jobs" e o plugin busca via
long-poll, executa lá dentro e devolve o resultado.

    plugin  --POST /session/message-->  servidor
    plugin  <--GET  /session/poll-----  {"type":"tool", ...}
    plugin  --POST /session/tool_result-> servidor
    plugin  <--GET  /session/poll-----  {"type":"done"}

Quem decide sobre PERMISSÃO é o plugin, não o servidor. O servidor só carimba a
classe de permissão da ferramenta no evento; o plugin, que tem a UI e as
preferências do usuário, decide se executa direto ou se abre o card de
aprovação. Isso mantém o estado de permissão num lugar só.

Algumas ferramentas resolvem AQUI, sem ida ao Studio: as que consultam a API do
Roblox, o Creator Store ou o analisador de Luau. E todo resultado que volta do
plugin passa por um enriquecimento — é onde uma propriedade inventada vira um
"você quis dizer".
"""

import asyncio
import json
import re
import uuid
from typing import Any, Dict, List, Optional, Tuple

from . import apidump, assets, luau_check
from .tools import permission_of


class Session:
    def __init__(self, backend: str) -> None:
        self.backend = backend
        self.out: asyncio.Queue = asyncio.Queue()      # eventos -> plugin
        self.inbox: asyncio.Queue = asyncio.Queue()    # mensagens do usuário -> worker
        self.pending: Dict[str, asyncio.Future] = {}   # tool_id -> resultado
        self.worker: Optional[asyncio.Task] = None
        self.turn: Optional[asyncio.Task] = None       # turno atual (para cancelar)
        self.busy = False
        self.messages: List[Dict[str, Any]] = []       # histórico (backend api)
        self.place_context: Optional[str] = None       # injetado pelo plugin
        self.cancelled = False


# --------------------------------------------------------------------------- #
# check_syntax: parse no plugin, tipos aqui
# --------------------------------------------------------------------------- #
_NUM_LINHA = re.compile(r"^ *\d+ \| ?", re.MULTILINE)


async def _check_syntax(args: Dict[str, Any], session: "Session") -> Tuple[str, bool]:
    """
    O `check_syntax` que o agente chama. Duas camadas:

      1. o plugin compila (loadstring) — pega erro de parse, e é o único caminho
         quando o analisador não está disponível;
      2. o luau-lsp analisa com os tipos do Roblox — é quem pega `part.Colour`,
         argumento de tipo errado e campo que não existe.

    Erro de parse curto-circuita: com o arquivo quebrado, a análise de tipo só
    produziria ruído em cima do mesmo erro.
    """
    source = args.get("source")
    path = args.get("path")

    bruto, erro = await call_tool(session, "check_syntax", args, 120, server_side=False)
    if erro:
        return bruto, True
    try:
        parse = json.loads(bruto)
    except ValueError:
        return bruto, False
    if not parse.get("ok"):
        return bruto, True  # não compila: o erro de sintaxe é a resposta

    if not await luau_check.ANALYZER.ensure():
        parse["type_check"] = (
            "indisponível — só a sintaxe foi verificada. Erro de TIPO (propriedade "
            "que não existe, argumento errado) NÃO foi checado aqui."
        )
        if luau_check.ANALYZER.status.get("error"):
            parse["type_check_error"] = luau_check.ANALYZER.status["error"]
        return json.dumps(parse, ensure_ascii=False), False

    if not source and path:
        lido, err_src = await call_tool(session, "get_source", {"path": path}, 120, server_side=False)
        if err_src:
            return bruto, False
        try:
            source = _NUM_LINHA.sub("", json.loads(lido).get("source") or "")
        except ValueError:
            return bruto, False

    ok, problemas = await luau_check.ANALYZER.analyze(source or "")
    if ok:
        parse["type_check"] = "ok — sintaxe e tipos conferidos com a API real do Roblox."
        return json.dumps(parse, ensure_ascii=False), False

    parse["ok"] = False
    parse["type_check"] = "FALHOU"
    parse["problems"] = problemas
    return json.dumps(parse, ensure_ascii=False), True


async def _lookup_api(args: Dict[str, Any], session: "Session") -> str:
    return await apidump.lookup(args)


async def _search_assets(args: Dict[str, Any], session: "Session") -> str:
    return await assets.search(args)


SERVER_SIDE = {
    "lookup_api": _lookup_api,
    "search_assets": _search_assets,
    "check_syntax": _check_syntax,
}


# --------------------------------------------------------------------------- #
# Enriquecimento: propriedade que não existe vira "você quis dizer"
# --------------------------------------------------------------------------- #
_ENRIQUECE = {"create_instance", "set_property", "batch"}


def _anotar(node: Any) -> bool:
    """Anda no resultado e anexa sugestões a cada `failed_properties`."""
    mudou = False
    if isinstance(node, dict):
        falhas, classe = node.get("failed_properties"), node.get("class")
        if isinstance(falhas, dict) and isinstance(classe, str):
            for prop in list(falhas):
                perto = apidump.DUMP.suggest_members(classe, prop)
                if perto:
                    falhas[prop] = f"{falhas[prop]}  →  em {classe} existe: {', '.join(perto)}"
                    mudou = True
        for v in node.values():
            mudou = _anotar(v) or mudou
    elif isinstance(node, list):
        for v in node:
            mudou = _anotar(v) or mudou
    return mudou


async def _enriquecer(name: str, content: str) -> str:
    if name not in _ENRIQUECE or "failed_properties" not in content:
        return content
    try:
        data = json.loads(content)
    except (ValueError, TypeError):
        return content
    await apidump.DUMP.ensure_loaded()
    return json.dumps(data, ensure_ascii=False) if _anotar(data) else content


# --------------------------------------------------------------------------- #
async def call_tool(
    session: Session,
    name: str,
    tool_input: dict,
    timeout: float,
    server_side: bool = True,
) -> Tuple[str, bool]:
    """
    Executa uma ferramenta. Se ela for do servidor, resolve aqui; senão, enfileira
    um job e espera o plugin executar dentro do Studio.

    `server_side=False` força o caminho do plugin. É o que deixa uma ferramenta
    do servidor delegar para a sua metade no Studio sem se chamar em loop.
    """
    handler = SERVER_SIDE.get(name) if server_side else None
    if handler is not None:
        try:
            res = await handler(tool_input or {}, session)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            return f"Erro em {name}: {exc}", True
        # Um handler pode devolver só o texto (sucesso) ou (texto, is_error) —
        # sem isso, uma checagem que falhou voltaria carimbada como sucesso.
        return res if isinstance(res, tuple) else (res, False)

    if session.cancelled:
        return "Cancelado pelo usuário.", True

    tool_id = uuid.uuid4().hex
    fut = asyncio.get_running_loop().create_future()
    session.pending[tool_id] = fut
    await session.out.put({
        "type": "tool",
        "id": tool_id,
        "name": name,
        "input": tool_input,
        "permission": permission_of(name),
    })
    try:
        content, is_error = await asyncio.wait_for(fut, timeout=timeout)
    except asyncio.TimeoutError:
        session.pending.pop(tool_id, None)
        return (
            f"A ferramenta '{name}' expirou ({timeout:.0f}s) — o plugin não respondeu. "
            "O usuário pode ter deixado o card de permissão aberto, ou a operação é "
            "pesada demais. Considere quebrar em passos menores.",
            True,
        )
    except asyncio.CancelledError:
        session.pending.pop(tool_id, None)
        raise
    return await _enriquecer(name, content), is_error
