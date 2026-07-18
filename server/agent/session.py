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
"""

import asyncio
import uuid
from typing import Any, Dict, List, Optional

from .tools import permission_of

# Ferramentas resolvidas no SERVIDOR, sem ida ao plugin.
from . import apidump

SERVER_SIDE = {"lookup_api": apidump.lookup}


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


async def call_tool(session: Session, name: str, tool_input: dict, timeout: float):
    """
    Executa uma ferramenta. Se ela for do servidor (lookup_api), resolve aqui.
    Senão, enfileira um job e espera o plugin executar dentro do Studio.
    """
    handler = SERVER_SIDE.get(name)
    if handler is not None:
        try:
            return await handler(tool_input or {}), False
        except Exception as exc:
            return f"Erro em {name}: {exc}", True

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
    return content, is_error
