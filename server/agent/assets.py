"""
Busca no Creator Store
======================
Resolve `search_assets`. Roda no SERVIDOR, como o lookup_api: é uma consulta HTTP
a um serviço da Roblox, não tem nada a ver com o place aberto.

Por que existe: o guia de modelagem manda procurar um modelo pronto antes de
empilhar peça, e `insert_asset` recebe um ID numérico. Sem busca, o único jeito
de o agente obter um ID era INVENTAR — o que ou falha no LoadAsset ou insere
qualquer coisa. Ou seja, a instrução era impossível de cumprir com honestidade.

São duas chamadas: a busca devolve só IDs, e os detalhes (nome, criador, votos,
se tem script) vêm de um segundo endpoint.
"""

import asyncio
from typing import Any, Dict, List

_SEARCH = "https://apis.roblox.com/toolbox-service/v1/marketplace/{category}"
_DETAILS = "https://apis.roblox.com/toolbox-service/v1/items/details"

# categoryId do toolbox. Os que fazem sentido para um agente que constrói cenário.
CATEGORIES = {"model": 10, "mesh": 40, "decal": 13, "audio": 3, "video": 62}


def _fmt(item: Dict[str, Any]) -> str:
    asset = item.get("asset") or {}
    creator = item.get("creator") or {}
    voting = item.get("voting") or {}

    nome = asset.get("name") or "(sem nome)"
    linha = [f"{nome} — id {asset.get('id')}"]

    autor = creator.get("name") or "?"
    if creator.get("isVerifiedCreator"):
        autor += " ✓"
    detalhe = [f"por {autor}"]

    if voting.get("showVotes") and voting.get("voteCount"):
        detalhe.append(f"{voting.get('upVotePercent')}% de {voting['voteCount']} votos")
    if asset.get("isEndorsed"):
        detalhe.append("ENDOSSADO pela Roblox")

    tris = ((asset.get("modelTechnicalDetails") or {}).get("objectMeshSummary") or {}).get("triangles")
    if tris:
        detalhe.append(f"{tris} triângulos")

    linha.append("    " + " · ".join(detalhe))

    # Modelo com script roda código de terceiro dentro do place do usuário no
    # primeiro playtest. Não dá para o agente inserir isso sem dizer.
    if asset.get("hasScripts"):
        linha.append("    ⚠ CONTÉM SCRIPTS — código de terceiro. Avise o usuário antes de inserir.")

    desc = (asset.get("description") or "").strip().replace("\n", " ")
    if desc:
        linha.append("    " + (desc[:150] + "…" if len(desc) > 150 else desc))

    return "\n".join(linha)


async def search(args: Dict[str, Any]) -> str:
    import httpx

    keyword = (args.get("keyword") or "").strip()
    if not keyword:
        return "Erro: keyword é obrigatório."

    categoria = (args.get("category") or "model").lower()
    if categoria not in CATEGORIES:
        return f"Erro: category inválida. Use uma de: {', '.join(CATEGORIES)}."

    limit = max(1, min(int(args.get("limit") or 8), 20))
    params: Dict[str, Any] = {"keyword": keyword, "limit": limit}
    if args.get("verified_only"):
        params["creatorType"] = "VerifiedCreator"

    try:
        async with httpx.AsyncClient(timeout=20) as client:
            resp = await client.get(_SEARCH.format(category=CATEGORIES[categoria]), params=params)
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

    cabecalho = f"{len(itens)} resultados para '{keyword}' ({categoria}). Insira com insert_asset(asset_id=...):"
    return cabecalho + "\n\n" + "\n\n".join(_fmt(i) for i in itens)
