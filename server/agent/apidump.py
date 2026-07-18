"""
API dump do Roblox
==================
Baixa e indexa o Full-API-Dump.json oficial para a ferramenta `lookup_api`.

Por que isto existe: sem uma fonte de verdade, o modelo chuta nomes de
propriedade que parecem plausíveis e não existem (`part.Colour`,
`humanoid.Speed`), e usa API deprecada que ainda "funciona" mas não deveria ser
escrita hoje. O dump resolve os dois: é a API exata da versão instalada, com os
deprecados marcados.

Fonte:
  https://setup.rbxcdn.com/versionQTStudio      -> hash da versão do Studio
  https://setup.rbxcdn.com/{hash}-API-Dump.json -> o dump (~4 MB)

O download acontece uma vez e fica em disco em .cache/. Se a rede estiver fora,
usa o cache mais recente que existir.

## Níveis de segurança

Importa mais do que parece. O plugin roda com PluginSecurity; o código que o
agente ESCREVE (Scripts do jogo) roda com segurança None. Então um membro
PluginSecurity é usável via run_code mas quebra num Script normal — e o agente
precisa saber a diferença antes de escrever, não depois.
"""

import asyncio
import difflib
import json
import os
from typing import Any, Dict, List, Optional, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
_CACHE_DIR = os.path.join(os.path.dirname(_HERE), ".cache")

_VERSION_URL = "https://setup.rbxcdn.com/versionQTStudio"
_DUMP_URL = "https://setup.rbxcdn.com/{version}-API-Dump.json"

# Segurança -> como o agente deve tratar
_USABLE_IN_SCRIPTS = {"None", None, ""}
_PLUGIN_ONLY = {"PluginSecurity", "LocalUserSecurity"}
# RobloxScriptSecurity / RobloxSecurity / NotAccessibleSecurity: inúteis, omitidos.
_HIDDEN = {"RobloxScriptSecurity", "RobloxSecurity", "NotAccessibleSecurity"}


class ApiDump:
    def __init__(self) -> None:
        self._classes: Dict[str, Dict[str, Any]] = {}
        self._enums: Dict[str, List[str]] = {}
        self._version: Optional[str] = None
        self._loaded = False
        self._lock = asyncio.Lock()
        self._error: Optional[str] = None

    # ------------------------------------------------------------------ carga
    async def ensure_loaded(self) -> None:
        if self._loaded:
            return
        async with self._lock:
            if self._loaded:
                return
            try:
                raw = await self._fetch()
            except Exception as exc:  # rede fora e sem cache
                self._error = str(exc)
                self._loaded = True
                return
            self._index(raw)
            self._loaded = True

    async def _fetch(self) -> Dict[str, Any]:
        os.makedirs(_CACHE_DIR, exist_ok=True)
        import httpx

        version: Optional[str] = None
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                resp = await client.get(_VERSION_URL)
                resp.raise_for_status()
                version = resp.text.strip()
        except Exception:
            version = None  # sem rede: cai no cache abaixo

        if version:
            cached = os.path.join(_CACHE_DIR, f"api-dump-{version}.json")
            if os.path.exists(cached):
                self._version = version
                with open(cached, "r", encoding="utf-8") as fh:
                    return json.load(fh)
            async with httpx.AsyncClient(timeout=90) as client:
                resp = await client.get(_DUMP_URL.format(version=version))
                resp.raise_for_status()
                data = resp.json()
            with open(cached, "w", encoding="utf-8") as fh:
                json.dump(data, fh)
            self._version = version
            return data

        newest = self._newest_cache()
        if newest:
            self._version = os.path.basename(newest)[9:-5] + " (cache; sem rede)"
            with open(newest, "r", encoding="utf-8") as fh:
                return json.load(fh)
        raise RuntimeError("sem rede e sem cache do API dump")

    def _newest_cache(self) -> Optional[str]:
        if not os.path.isdir(_CACHE_DIR):
            return None
        files = [
            os.path.join(_CACHE_DIR, f)
            for f in os.listdir(_CACHE_DIR)
            if f.startswith("api-dump-") and f.endswith(".json")
        ]
        return max(files, key=os.path.getmtime) if files else None

    def _index(self, raw: Dict[str, Any]) -> None:
        for cls in raw.get("Classes", []):
            self._classes[cls["Name"]] = cls
        for en in raw.get("Enums", []):
            self._enums[en["Name"]] = [i["Name"] for i in en.get("Items", [])]

    # ------------------------------------------------------------- utilidades
    @property
    def ready(self) -> bool:
        return self._loaded and bool(self._classes)

    @property
    def status(self) -> Dict[str, Any]:
        return {
            "ready": self.ready,
            "version": self._version,
            "classes": len(self._classes),
            "enums": len(self._enums),
            "error": self._error,
        }

    def _chain(self, class_name: str) -> List[Dict[str, Any]]:
        """A classe e seus ancestrais, do mais específico pro mais genérico."""
        out: List[Dict[str, Any]] = []
        cur = self._classes.get(class_name)
        seen = set()
        while cur and cur["Name"] not in seen:
            seen.add(cur["Name"])
            out.append(cur)
            cur = self._classes.get(cur.get("Superclass") or "")
        return out

    def _resolve_name(self, class_name: str) -> Optional[str]:
        """Aceita nome exato, ou tenta case-insensitive."""
        if class_name in self._classes:
            return class_name
        low = class_name.lower()
        for name in self._classes:
            if name.lower() == low:
                return name
        return None

    def suggest(self, class_name: str, limit: int = 5) -> List[str]:
        """Classes com nome parecido — para quando o agente erra o nome."""
        low = class_name.lower()
        hits = [n for n in self._classes if low in n.lower()]
        hits.sort(key=len)
        return hits[:limit]

    def suggest_members(
        self, class_name: str, name: str, member_type: str = "Property", limit: int = 4
    ) -> List[str]:
        """
        Membros parecidos com `name` na classe — o "você quis dizer" de uma
        propriedade que não existe.

        É o outro lado do lookup_api: aquele exige que o agente lembre de
        perguntar; este responde sem ser chamado, no momento em que ele errou.
        """
        resolved = self._resolve_name(class_name)
        if not resolved:
            return []
        names: List[str] = []
        for cls in self._chain(resolved):
            for m in cls.get("Members", []):
                if m.get("MemberType") != member_type:
                    continue
                marks, hide = self._flags(m)
                if hide or any(x.startswith("DEPRECADO") for x in marks):
                    continue
                names.append(m["Name"])

        # Diferença só de caixa é o erro mais comum e o mais fácil de resolver:
        # se houver, é a resposta, e mostrar alternativas difusas só atrapalha.
        low = name.lower()
        exact = [n for n in names if n.lower() == low]
        if exact:
            return exact[:limit]
        return difflib.get_close_matches(name, names, n=limit, cutoff=0.6)

    # ------------------------------------------------------------- formatação
    @staticmethod
    def _type_name(vt: Optional[Dict[str, Any]]) -> str:
        if not vt:
            return "()"
        cat, name = vt.get("Category"), vt.get("Name", "?")
        return f"Enum.{name}" if cat == "Enum" else name

    @classmethod
    def _params(cls, member: Dict[str, Any]) -> str:
        out = []
        for p in member.get("Parameters", []) or []:
            s = f"{p['Name']}: {cls._type_name(p.get('Type'))}"
            if "Default" in p:
                s += f" = {p['Default']}"
            out.append(s)
        return ", ".join(out)

    @staticmethod
    def _flags(member: Dict[str, Any]) -> Tuple[List[str], bool]:
        """(marcadores, esconder). Esconde o que é inacessível de qualquer jeito."""
        tags = member.get("Tags") or []
        sec = member.get("Security")
        read = write = sec if isinstance(sec, str) else None
        if isinstance(sec, dict):
            read, write = sec.get("Read"), sec.get("Write")

        if read in _HIDDEN and write in _HIDDEN:
            return [], True

        marks: List[str] = []
        if "Deprecated" in tags:
            marks.append("DEPRECADO — não use")
        if "ReadOnly" in tags or (write in _HIDDEN and read in _USABLE_IN_SCRIPTS):
            marks.append("somente leitura")
        if read in _PLUGIN_ONLY or write in _PLUGIN_ONLY:
            marks.append("só via plugin/run_code — NÃO funciona em Script do jogo")
        if "NotReplicated" in tags:
            marks.append("não replica")
        if "Yields" in tags:
            marks.append("yields")
        return marks, False

    def describe(
        self,
        class_name: str,
        member: Optional[str] = None,
        kind: str = "all",
        include_inherited: bool = True,
    ) -> str:
        if not self.ready:
            detail = f": {self._error}" if self._error else ""
            return (
                f"API dump indisponível{detail}. "
                "Confie na reflexão do Studio (get_properties) em vez de chutar."
            )

        resolved = self._resolve_name(class_name)
        if not resolved:
            near = self.suggest(class_name)
            msg = f"Classe '{class_name}' não existe na API do Roblox."
            if near:
                msg += " Você quis dizer: " + ", ".join(near) + "?"
            return msg

        chain = self._chain(resolved) if include_inherited else [self._classes[resolved]]
        header = resolved
        if len(chain) > 1:
            header += "  (herda: " + " > ".join(c["Name"] for c in chain[1:]) + ")"
        cls_tags = self._classes[resolved].get("Tags") or []
        if "Deprecated" in cls_tags:
            header += "\n⚠️  CLASSE DEPRECADA — procure a alternativa moderna."
        if "NotCreatable" in cls_tags:
            header += "\n⚠️  Não pode ser criada com Instance.new (é um serviço ou é interna)."
        if "Service" in cls_tags:
            header += "\n(serviço — pegue com game:GetService)"

        want = {
            "properties": {"Property"},
            "methods": {"Function"},
            "events": {"Event"},
        }.get(kind, {"Property", "Function", "Event", "Callback"})

        buckets: Dict[str, List[str]] = {"Property": [], "Function": [], "Event": [], "Callback": []}
        seen: set = set()
        filt = member.lower() if member else None

        # Um lookup sem filtro é "me mostre esta classe". Aí o que atrapalha é
        # ruído: os membros genéricos de Instance (Destroy, FindFirstChild,
        # GetChildren...) e os aliases deprecados enterram as poucas linhas que
        # de fato são sobre a classe pedida. Com filtro é o oposto: o agente
        # está perguntando de um membro específico, e "existe mas é deprecado" é
        # justo a resposta que ele precisa. Então os dois cortes só valem sem
        # filtro.
        skip_generic = filt is None and resolved != "Instance"
        omitted_generic = False

        for cls in chain:
            if skip_generic and cls["Name"] == "Instance":
                omitted_generic = True
                continue
            owner = "" if cls["Name"] == resolved else f"  (de {cls['Name']})"
            for m in cls.get("Members", []):
                mt = m.get("MemberType")
                if mt not in want or m["Name"] in seen:
                    continue
                if filt and filt not in m["Name"].lower():
                    continue
                marks, hide = self._flags(m)
                if hide:
                    continue
                if filt is None and any(x.startswith("DEPRECADO") for x in marks):
                    continue
                seen.add(m["Name"])

                if mt == "Property":
                    line = f"{m['Name']}: {self._type_name(m.get('ValueType'))}"
                elif mt in ("Function", "Callback"):
                    line = f"{m['Name']}({self._params(m)})"
                    ret = self._type_name(m.get("ReturnType"))
                    # 'null' é como o dump escreve void.
                    if ret not in ("()", "void", "null"):
                        line += f" -> {ret}"
                else:
                    line = f"{m['Name']}({self._params(m)})"

                if marks:
                    line += "   [" + "; ".join(marks) + "]"
                buckets[mt].append("  " + line + owner)

        titles = {
            "Property": "PROPRIEDADES", "Function": "MÉTODOS",
            "Event": "EVENTOS", "Callback": "CALLBACKS",
        }
        body = []
        for key in ("Property", "Function", "Event", "Callback"):
            if buckets[key]:
                body.append(titles[key] + "\n" + "\n".join(sorted(buckets[key])))

        footer = []
        if omitted_generic:
            footer.append(
                "(+ os membros padrão de Instance — Destroy, Clone, FindFirstChild, "
                "GetChildren, WaitForChild, IsA, GetAttribute, Changed... — omitidos "
                "aqui por serem óbvios. Passe member= para procurar entre eles.)"
            )
        if filt is None:
            footer.append("(membros deprecados omitidos; passe member= para checar um específico.)")

        if not body:
            extra = f" com '{member}' no nome" if member else ""
            hint = " (tente include_inherited=true)" if not include_inherited else ""
            return f"{header}\n\nNenhum membro{extra} encontrado{hint}."

        out = header + "\n\n" + "\n\n".join(body)
        if footer:
            out += "\n\n" + "\n".join(footer)
        return out

    def describe_enum(self, name: str) -> Optional[str]:
        items = self._enums.get(name)
        if not items:
            return None
        return f"Enum.{name}\n  " + "\n  ".join(items)


DUMP = ApiDump()


async def lookup(args: Dict[str, Any]) -> str:
    """Handler da ferramenta lookup_api. Roda no servidor, não no plugin."""
    await DUMP.ensure_loaded()
    class_name = (args.get("class_name") or "").strip()
    if not class_name:
        return "Erro: class_name é obrigatório."

    # Conveniência: lookup_api("Material") ou ("Enum.Material") devolve o enum.
    bare = class_name[5:] if class_name.startswith("Enum.") else class_name
    if class_name.startswith("Enum.") or bare not in DUMP._classes:
        enum = DUMP.describe_enum(bare)
        if enum:
            return enum

    return DUMP.describe(
        class_name,
        member=args.get("member"),
        kind=(args.get("kind") or "all"),
        include_inherited=args.get("include_inherited", True),
    )
