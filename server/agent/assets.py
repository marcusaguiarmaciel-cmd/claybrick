"""
Busca no Creator Store
======================
Resolve `search_assets`. Roda no SERVIDOR, como o lookup_api: é uma consulta HTTP
a um serviço da Roblox, não tem nada a ver com o place aberto.

Por que existe: o guia de modelagem manda procurar um modelo pronto antes de
empilhar peça, e `insert_asset` recebe um ID numérico. Sem busca, o único jeito
de o agente obter um ID era INVENTAR, o que ou falha no LoadAsset ou insere
qualquer coisa.

Por que FILTRA: a busca crua do toolbox devolve muito lixo, e lixo aqui é caro.
Medindo 160 modelos reais em 8 termos, 42% continham script (sistema disfarçado
de modelo, e vetor de backdoor), e numa busca por "bicycle" vieram um bicicletário,
um spawner, um modelo vazio e três com mais de 200 mil triângulos. Se o agente
recebe essa lista, ou ele escolhe mal ou desiste de procurar e volta a empilhar
peça na mão. O filtro existe para a instrução "procure antes de construir" valer
a pena de ser seguida.
"""

import asyncio
from typing import Any, Dict, List, Tuple

_SEARCH = "https://apis.roblox.com/toolbox-service/v1/marketplace/{category}"
_DETAILS = "https://apis.roblox.com/toolbox-service/v1/items/details"

# categoryId do toolbox. Os que fazem sentido para um agente que constrói cenário.
CATEGORIES = {"model": 10, "mesh": 40, "decal": 13, "audio": 3, "video": 62}

# Categoria de gameplay é sistema com script, não objeto. Quem pede "bicicleta"
# quer a bicicleta, não o spawner de bicicleta.
_CAT_DESCARTE = ("gameplay__", "audio__", "video__")

# Acima disso não é um prop: é uma cena inteira, ou densidade que derruba celular.
_TRIS_MAX = 60000


def _sinais(item: Dict[str, Any]) -> Dict[str, Any]:
    a = item.get("asset") or {}
    v = item.get("voting") or {}
    td = a.get("modelTechnicalDetails") or {}
    ic = td.get("instanceCounts") or {}
    ms = td.get("objectMeshSummary") or {}
    # Dois campos dizem a mesma coisa e hoje nunca divergem (conferido em 160
    # modelos). Ler os dois assim mesmo porque isto alimenta um AVISO DE
    # SEGURANÇA: se um dia a API mudar e só um deles for preenchido, o certo é
    # o aviso aparecer à toa, não sumir calado.
    scripts = ic.get("script", 0) or 0
    if not scripts and a.get("hasScripts"):
        scripts = 1

    return {
        "scripts": scripts,
        "meshes": ic.get("meshPart", 0) or 0,
        "tris": ms.get("triangles", 0) or 0,
        "votos": v.get("voteCount", 0) or 0,
        "pct": v.get("upVotePercent", 0) or 0,
        "endossado": bool(a.get("isEndorsed")),
        "aprovado": bool(a.get("isAssetHashApproved")),
        "tipos": [t.lower() for t in (a.get("objectTypes") or [])],
        "cat": (a.get("categoryPath") or "").lower(),
    }


def _nucleo(x: str) -> str:
    """A última palavra: em inglês é ela que diz o que a coisa É.

    Casar por substring seria armadilha: "bicycle" está dentro de "bicycle rack",
    e o bicicletário entraria como se fosse bicicleta. Já "wooden chair" e
    "chair" têm o mesmo núcleo e são a mesma coisa.
    """
    partes = x.strip().split()
    return partes[-1] if partes else ""


def _avaliar(item: Dict[str, Any], termo: str, estudar: bool) -> Tuple[int, List[str]]:
    """(nota, motivos). Nota negativa = descartar sem mostrar ao agente."""
    s = _sinais(item)
    nota, por = 0, []

    # ------------------------------------------------------------ eliminatórios
    if s["tris"] == 0 and s["meshes"] == 0:
        return -1, ["vazio"]
    if any(s["cat"].startswith(c) for c in _CAT_DESCARTE):
        return -1, ["é sistema, não objeto"]
    if not s["aprovado"]:
        return -1, ["não aprovado na moderação"]
    if s["tris"] > _TRIS_MAX:
        return -1, [f"{s['tris']} triângulos"]
    # Voto ruim COM amostra é o sinal mais honesto que existe aqui.
    if s["votos"] >= 10 and s["pct"] < 70:
        return -1, [f"{s['pct']}% de {s['votos']} votos"]

    # ------------------------------------------- é mesmo a coisa que foi pedida
    # objectTypes é a classificação da PRÓPRIA Roblox. Vale mais que o nome, que
    # é escrito por quem quer aparecer na busca ("Bicycle Bmx Rp City Vehicle").
    alvo = termo.lower().strip()
    if s["tipos"]:
        if any(t == alvo or _nucleo(t) == _nucleo(alvo) for t in s["tipos"]):
            nota += 40
            por.append("é " + "/".join(s["tipos"]))
        else:
            nota -= 25
            por.append("é " + "/".join(s["tipos"]) + f", não {alvo}")
    else:
        # 30% do acervo não tem classificação. Penalidade leve: cegueira não é
        # prova de que o modelo é ruim.
        nota -= 5
        por.append("sem classificação")

    # -------------------------------------------------------------------- script
    if s["scripts"] == 0:
        nota += 15
        por.append("sem scripts")
    elif s["scripts"] <= 3:
        nota -= 10
        por.append(f"{s['scripts']} scripts")
    else:
        nota -= 30
        por.append(f"{s['scripts']} scripts: é um sistema")

    # ------------------------------------- mesh ou peça, conforme a intenção
    if estudar:
        # Para APRENDER construção, mesh é um blob opaco: não ensina nada.
        if s["meshes"] == 0:
            nota += 30
            por.append("feito de peças")
        else:
            nota -= 40
            por.append(f"{s['meshes']} meshes: não dá para estudar")
    elif s["meshes"] > 0:
        nota += 15
        por.append(f"{s['meshes']} meshes")

    # ------------------------------------ votos como BÔNUS, nunca como exigência
    # 39% dos modelos não têm voto nenhum; exigir voto descartaria acervo bom.
    if s["votos"] >= 10 and s["pct"] >= 85:
        nota += 25
        por.append(f"{s['pct']}% de {s['votos']} votos")
    elif s["votos"] >= 10:
        nota += 10
        por.append(f"{s['pct']}% de {s['votos']} votos")

    if s["endossado"]:
        nota += 30
        por.append("ENDOSSADO pela Roblox")

    if 300 <= s["tris"] <= 20000:
        nota += 10

    return nota, por


def _fmt(item: Dict[str, Any], nota: int, motivos: List[str]) -> str:
    asset = item.get("asset") or {}
    creator = item.get("creator") or {}

    nome = asset.get("name") or "(sem nome)"
    linhas = [f"{nome} — id {asset.get('id')}"]
    linhas.append("    por " + (creator.get("name") or "?") + " · " + " · ".join(motivos))

    # Script sobrevivente ainda precisa de aviso: o filtro derruba o sistema com
    # 20 scripts, mas deixa passar o modelo com 1 ou 2, que ainda é código de
    # terceiro rodando no place do usuário.
    if _sinais(item)["scripts"]:
        linhas.append("    ⚠ CONTÉM SCRIPTS — código de terceiro. Avise o usuário antes de inserir.")

    desc = (asset.get("description") or "").strip().replace("\n", " ")
    if desc:
        linhas.append("    " + (desc[:120] + "…" if len(desc) > 120 else desc))

    return "\n".join(linhas)


async def search(args: Dict[str, Any]) -> str:
    import httpx

    keyword = (args.get("keyword") or "").strip()
    if not keyword:
        return "Erro: keyword é obrigatório."

    categoria = (args.get("category") or "model").lower()
    if categoria not in CATEGORIES:
        return f"Erro: category inválida. Use uma de: {', '.join(CATEGORIES)}."

    estudar = bool(args.get("para_estudar"))
    limit = max(1, min(int(args.get("limit") or 8), 20))

    # Pede mais do que vai mostrar: o filtro derruba entre 15% e 40% do que vem,
    # e devolver 3 resultados porque 5 eram lixo não ajuda ninguém.
    bruto = min(50, max(limit * 3, 20))

    try:
        async with httpx.AsyncClient(timeout=20) as client:
            resp = await client.get(
                _SEARCH.format(category=CATEGORIES[categoria]),
                params={"keyword": keyword, "limit": bruto},
            )
            resp.raise_for_status()
            ids = [str(d["id"]) for d in (resp.json().get("data") or []) if d.get("id")]

            if not ids:
                return (
                    f"Nenhum resultado para '{keyword}' em {categoria}. "
                    "Tente um termo mais genérico e em inglês — o acervo é majoritariamente em inglês."
                )

            det = await client.get(_DETAILS, params={"assetIds": ",".join(ids)})
            det.raise_for_status()
            itens: List[Dict[str, Any]] = det.json().get("data") or []
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        return (
            f"A busca falhou ({type(exc).__name__}: {exc}). "
            "O serviço do Creator Store pode estar fora. Construa com as peças e o CSG, "
            "ou peça um ID ao usuário."
        )

    if not itens:
        return f"A busca achou {len(ids)} ids para '{keyword}', mas os detalhes não vieram."

    # O filtro lê modelTechnicalDetails (triângulos, contagem de instâncias,
    # classificação), e isso só existe em MODELO. Mesh, decal e áudio vêm sem
    # nada disso, então pontuá-los reprovaria todos por "vazio" — foi exatamente
    # o que aconteceu na primeira versão. Nessas categorias devolvemos a lista
    # como veio, sem inventar julgamento que os dados não sustentam.
    if categoria != "model":
        vistos = [i for i in itens if (i.get("asset") or {}).get("isAssetHashApproved")][:limit]
        if not vistos:
            return f"Nenhum resultado aprovado para '{keyword}' em {categoria}."
        corpo = "\n\n".join(_fmt(i, 0, ["(sem filtro de qualidade nesta categoria)"]) for i in vistos)
        return f"{len(vistos)} resultados para '{keyword}' ({categoria}):\n\n" + corpo

    avaliados = [(_avaliar(i, keyword, estudar), i) for i in itens]
    bons = sorted(
        [(n, p, i) for (n, p), i in avaliados if n >= 0],
        key=lambda x: -x[0],
    )[:limit]
    cortados = len(avaliados) - len([1 for (n, _), _ in avaliados if n >= 0])

    if not bons:
        return (
            f"{len(itens)} resultados para '{keyword}', e nenhum passou no filtro de qualidade "
            "(vazios, sistemas com script, ou densidade alta demais para um prop).\n"
            "Tente outro termo, ou construa com as peças e o CSG."
        )

    if estudar:
        cabecalho = (
            f"{len(bons)} modelos FEITOS DE PEÇAS para '{keyword}' ({cortados} descartados). "
            "Insira com insert_asset e leia a estrutura com get_tree/get_properties:"
        )
    else:
        cabecalho = (
            f"{len(bons)} modelos para '{keyword}', melhores primeiro "
            f"({cortados} descartados por qualidade). Insira com insert_asset(asset_id=...):"
        )

    return cabecalho + "\n\n" + "\n\n".join(_fmt(i, n, p) for n, p, i in bons)
