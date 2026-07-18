"""
Análise estática de Luau
========================
Roda o `luau-lsp analyze` com as definições de tipo do Roblox, no servidor.

Por que não basta o `check_syntax` do plugin: lá o teste é `loadstring`, ou seja,
o COMPILADOR. Ele pega erro de parse e mais nada. `part.Colour = ...` compila
perfeitamente — e é exatamente o erro que este projeto inteiro existe para
evitar. Todo o valor do `--!strict` que os guias mandam escrever depende de
alguém rodar o ANALISADOR, e o plugin não tem acesso a ele.

    loadstring     -> "é Luau válido?"
    luau-lsp       -> "Key 'Colour' not found in external type 'Part'"

Duas peças, baixadas uma vez e cacheadas em .cache/:
  - luau-lsp        o analisador (o `luau-analyze` de upstream perdeu o --defs)
  - globalTypes     os tipos de game/Instance/Part/... gerados do API dump

Se qualquer uma faltar (sem rede, download bloqueado), o check volta a ser o do
plugin — pior, mas honesto: quem chama recebe o aviso de que só houve parse.
"""

import asyncio
import os
import platform
import re
import shutil
import zipfile
from typing import Any, Dict, List, Optional, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
_CACHE_DIR = os.path.join(os.path.dirname(_HERE), ".cache")

_LSP_URL = "https://github.com/JohnnyMorganz/luau-lsp/releases/latest/download/luau-lsp-{plat}.zip"
_TYPES_URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"

_PLATFORMS = {"Windows": "win64", "Darwin": "macos", "Linux": "linux"}

# Lints que existem para higiene de projeto e só fariam barulho aqui: o agente
# manda trechos soltos, onde "variável não usada" e afins são normais. Erro de
# tipo é o que interessa.
_RUIDO = re.compile(r"\b(LocalUnused|ImportUnused|FunctionUnused|LocalShadow)\b")

_LINHA = re.compile(r"^(?P<arq>.*?)\((?P<lin>\d+),(?P<col>\d+)\):\s*(?P<msg>.*)$")


class _Analyzer:
    def __init__(self) -> None:
        self._exe: Optional[str] = None
        self._types: Optional[str] = None
        self._lock = asyncio.Lock()
        self._tried = False
        self._error: Optional[str] = None

    @property
    def status(self) -> Dict[str, Any]:
        return {"ready": bool(self._exe and self._types), "error": self._error}

    async def ensure(self) -> bool:
        if self._exe and self._types:
            return True
        async with self._lock:
            if self._exe and self._types:
                return True
            if self._tried:
                return False  # já falhou uma vez; não fica tentando a cada chamada
            self._tried = True
            try:
                await asyncio.to_thread(self._baixar)
            except Exception as exc:
                self._error = f"{type(exc).__name__}: {exc}"
                return False
            return bool(self._exe and self._types)

    def _baixar(self) -> None:
        import httpx

        os.makedirs(_CACHE_DIR, exist_ok=True)
        plat = _PLATFORMS.get(platform.system())
        if not plat:
            raise RuntimeError(f"sem binário do luau-lsp para {platform.system()}")

        exe_nome = "luau-lsp.exe" if plat == "win64" else "luau-lsp"
        exe = os.path.join(_CACHE_DIR, exe_nome)
        if not os.path.exists(exe):
            zip_path = os.path.join(_CACHE_DIR, f"luau-lsp-{plat}.zip")
            with httpx.Client(timeout=180, follow_redirects=True) as client:
                resp = client.get(_LSP_URL.format(plat=plat))
                resp.raise_for_status()
                with open(zip_path, "wb") as fh:
                    fh.write(resp.content)
            with zipfile.ZipFile(zip_path) as zf:
                for nome in zf.namelist():
                    if os.path.basename(nome) == exe_nome:
                        with zf.open(nome) as src, open(exe, "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        break
            os.remove(zip_path)
            if not os.path.exists(exe):
                raise RuntimeError("o zip do luau-lsp não trouxe o executável")
            os.chmod(exe, 0o755)

        tipos = os.path.join(_CACHE_DIR, "globalTypes.d.luau")
        if not os.path.exists(tipos):
            with httpx.Client(timeout=120, follow_redirects=True) as client:
                resp = client.get(_TYPES_URL)
                resp.raise_for_status()
                with open(tipos, "w", encoding="utf-8") as fh:
                    fh.write(resp.text)

        self._exe, self._types = exe, tipos

    async def analyze(self, source: str) -> Tuple[bool, List[str]]:
        """(ok, problemas). Chamar só depois de ensure() dar True."""
        import tempfile

        # O nome do arquivo aparece em toda linha de diagnóstico; um nome curto
        # deixa a saída legível para o modelo em vez de repetir um caminho temp.
        pasta = tempfile.mkdtemp(prefix="claybrick-check-")
        arq = os.path.join(pasta, "script.luau")
        try:
            with open(arq, "w", encoding="utf-8") as fh:
                fh.write(source)

            proc = await asyncio.create_subprocess_exec(
                self._exe, "analyze", f"--definitions={self._types}", arq,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            try:
                saida, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                return True, []  # analisador travou: não invente problema que não viu
        finally:
            shutil.rmtree(pasta, ignore_errors=True)

        problemas = []
        for linha in saida.decode("utf-8", "replace").splitlines():
            linha = linha.strip()
            if not linha or linha.startswith("[INFO]") or _RUIDO.search(linha):
                continue
            m = _LINHA.match(linha)
            if m:
                problemas.append(f"linha {m['lin']}, coluna {m['col']}: {m['msg']}")
            elif "error" in linha.lower():
                problemas.append(linha)
        return not problemas, problemas


ANALYZER = _Analyzer()
