"""
Guias sob demanda
=================
Conhecimento profundo de domínio (segurança, datastores, física, UI...) fica em
knowledge/guias/*.md e só entra no contexto quando a tarefa pede, via a
ferramenta `lookup_guide`.

O motivo é o mesmo do `lookup_api`: enfiar 682 classes no system prompt seria
pior do que consultar a API real na hora. Vinte guias densos sempre ligados
custariam ~40k tokens por sessão, comeriam um terço do orçamento antes da
primeira mensagem e — o que importa mais — diluiriam a atenção do modelo entre
vinte assuntos quando a tarefa é um só.

O índice é montado lendo a pasta. Guia novo = arquivo novo, sem tocar em código.

Formato de cada arquivo:

    # Título do guia
    > Uma linha dizendo quando abrir este guia.

    ...conteúdo...

A linha `>` vira a descrição no índice do system prompt. É ela que o modelo lê
para decidir se precisa do guia, então vale escrevê-la pensando no gatilho
("quando for salvar dados de jogador") e não no rótulo ("sobre datastores").
"""

import os
from typing import Any, Dict, List, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
_GUIAS = os.path.join(_HERE, "knowledge", "guias")


def _slugs() -> List[str]:
    try:
        nomes = os.listdir(_GUIAS)
    except OSError:
        return []
    return sorted(n[:-3] for n in nomes if n.endswith(".md"))


def _ler(slug: str) -> str:
    # basename corta qualquer "../" antes de virar caminho: o argumento vem do
    # modelo, e um slug com travessia sairia da pasta de guias para o disco.
    seguro = os.path.basename(slug.strip().lower())
    if not seguro or not seguro.replace("-", "").replace("_", "").isalnum():
        return ""
    caminho = os.path.join(_GUIAS, seguro + ".md")
    if os.path.dirname(os.path.abspath(caminho)) != os.path.abspath(_GUIAS):
        return ""
    try:
        with open(caminho, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _resumo(texto: str) -> str:
    for linha in texto.splitlines():
        limpa = linha.strip()
        if limpa.startswith(">"):
            return limpa.lstrip("> ").strip()
    return ""


def indice() -> List[Tuple[str, str]]:
    """[(slug, resumo)] de todos os guias em disco, para o system prompt."""
    saida = []
    for slug in _slugs():
        texto = _ler(slug)
        if texto:
            saida.append((slug, _resumo(texto) or "(sem resumo)"))
    return saida


def indice_formatado() -> str:
    linhas = indice()
    if not linhas:
        return ""
    largura = max(len(s) for s, _ in linhas)
    return "\n".join("  %-*s  %s" % (largura, s, r) for s, r in linhas)


async def lookup(args: Dict[str, Any]) -> str:
    slug = str(args.get("guide") or "").strip().lower()
    if not slug:
        return "Faltou o argumento 'guide'. Disponíveis:\n" + indice_formatado()

    texto = _ler(slug)
    if not texto:
        # Mesma ideia do "você quis dizer" das escritas: devolver a lista custa
        # uma volta e evita o modelo desistir do guia por ter errado o nome.
        return (
            "Não existe guia '%s'. Disponíveis:\n%s" % (slug, indice_formatado())
        )
    return texto
