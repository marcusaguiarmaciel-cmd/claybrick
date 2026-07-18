"""
Registro de ferramentas
=======================
Uma única definição serve aos dois backends (API e assinatura) e ao plugin.

Cada ferramenta declara uma CLASSE DE PERMISSÃO. O plugin usa essa classe, junto
com o modo escolhido pelo usuário, para decidir se executa direto ou se abre um
card de aprovação. O servidor não guarda estado de permissão: quem manda é o
plugin, que é onde a UI e as preferências do usuário vivem.

  READ     Não modifica nada. Nunca pergunta, em nenhum modo.
  WRITE    Modifica o place. Pergunta no modo "ask". Desfazível com Ctrl+Z.
  EXECUTE  Roda código arbitrário ou simulação. Pergunta em "ask" e em
           "acceptEdits" — só o modo "bypass" libera sem perguntar. Pode ter
           efeitos que o Ctrl+Z NÃO desfaz.
"""

from typing import Any, Dict, List

READ = "read"
WRITE = "write"
EXECUTE = "execute"


def _tool(name: str, perm: str, description: str, properties: Dict[str, Any],
          required: List[str] | None = None) -> Dict[str, Any]:
    return {
        "name": name,
        "permission": perm,
        "description": description,
        "input_schema": {
            "type": "object",
            "properties": properties,
            **({"required": required} if required else {}),
        },
    }


_PATH = {"type": "string", "description": "Path separado por pontos, ex: 'Workspace.Mapa.Chao'."}

TOOL_DEFS: List[Dict[str, Any]] = [
    # ----------------------------------------------------------------- leitura
    _tool(
        "get_tree", READ,
        "Retorna a árvore de instâncias (nome, classe, path) a partir de um path. "
        "Use para se orientar antes de mexer em qualquer coisa.",
        {
            "path": {"type": "string", "description": "Path raiz. Padrão 'game'."},
            "max_depth": {"type": "integer", "description": "Profundidade. Padrão 3."},
        },
    ),
    _tool(
        "get_place_info", READ,
        "Informações gerais do place: nome, PlaceId, contagem de instâncias e scripts por "
        "serviço, e quais capacidades o plugin tem nesta versão do Studio.",
        {},
    ),
    _tool(
        "get_selection", READ,
        "Retorna as instâncias atualmente selecionadas no Studio. Útil quando o usuário diz "
        "'isso aqui' ou 'o que eu selecionei'.",
        {},
    ),
    _tool(
        "set_selection", READ,
        "Seleciona instâncias no Studio e foca a câmera nelas. Não modifica o place — serve "
        "para MOSTRAR ao usuário o que você fez. Use depois de criar algo.",
        {"paths": {"type": "array", "items": {"type": "string"}}},
        ["paths"],
    ),
    _tool(
        "get_properties", READ,
        "Lê propriedades de uma instância. Sem 'names', retorna um conjunto comum para a classe.",
        {
            "path": _PATH,
            "names": {"type": "array", "items": {"type": "string"},
                      "description": "Propriedades específicas. Omita para o conjunto padrão."},
        },
        ["path"],
    ),
    _tool(
        "find_instances", READ,
        "Procura instâncias por classe e/ou nome dentro de um ancestral.",
        {
            "class_name": {"type": "string", "description": "Filtra por IsA(class_name)."},
            "name": {"type": "string", "description": "Nome exato."},
            "name_contains": {"type": "string", "description": "Substring do nome (case-insensitive)."},
            "ancestor_path": {"type": "string", "description": "Onde procurar. Padrão 'game'."},
            "limit": {"type": "integer", "description": "Padrão 100."},
        },
    ),
    _tool(
        "get_source", READ,
        "Lê o código de um Script/LocalScript/ModuleScript. Retorna com números de linha, "
        "que é o que patch_source espera.",
        {
            "path": _PATH,
            "start_line": {"type": "integer", "description": "Primeira linha (1-based). Para arquivos grandes."},
            "end_line": {"type": "integer", "description": "Última linha, inclusiva."},
        },
        ["path"],
    ),
    _tool(
        "search_source", READ,
        "Busca um padrão (Lua pattern) dentro do código de todos os scripts sob um ancestral. "
        "É o seu grep: use para achar onde algo é definido ou usado antes de mudar.",
        {
            "pattern": {"type": "string", "description": "Lua pattern. Escape mágicos com %."},
            "ancestor_path": {"type": "string", "description": "Padrão 'game'."},
            "ignore_case": {"type": "boolean", "description": "Padrão false."},
            "max_results": {"type": "integer", "description": "Padrão 50."},
        },
        ["pattern"],
    ),
    _tool(
        "lookup_api", READ,
        "Consulta a API REAL do Roblox: propriedades, métodos e eventos de uma classe, com "
        "tipos, se é read-only e se está deprecado. SEMPRE use isto quando não tiver CERTEZA "
        "absoluta de que uma propriedade existe. Não chute nomes de propriedade.",
        {
            "class_name": {"type": "string", "description": "Ex: 'Part', 'Humanoid', 'TweenService'."},
            "member": {"type": "string", "description": "Filtra por um membro específico (substring)."},
            "kind": {"type": "string", "enum": ["all", "properties", "methods", "events"],
                     "description": "Padrão 'all'."},
            "include_inherited": {"type": "boolean", "description": "Inclui herdados. Padrão true."},
        },
        ["class_name"],
    ),
    _tool(
        "check_syntax", READ,
        "Compila código Luau SEM executar e retorna o erro de sintaxe, se houver. Rápido e "
        "sem efeito colateral. Rode isto em todo script que escrever, ANTES de considerá-lo pronto.",
        {
            "source": {"type": "string", "description": "Código a compilar. Ou use 'path'."},
            "path": {"type": "string", "description": "Compila o código de um script já existente."},
        },
    ),
    _tool(
        "get_output", READ,
        "Lê o Output do Studio (prints, warnings, erros), do mais recente para o mais antigo. "
        "Use depois de run_code ou de um playtest para ver o que aconteceu de verdade.",
        {
            "limit": {"type": "integer", "description": "Quantas mensagens. Padrão 50."},
            "only_errors": {"type": "boolean", "description": "Só erros e warnings. Padrão false."},
            "since_marker": {"type": "string", "description": "Só mensagens após este marcador (veja run_code)."},
        },
    ),
    _tool(
        "get_project_memory", READ,
        "Lê as anotações que você deixou sobre este projeto em sessões anteriores. Elas moram "
        "dentro do próprio place, então sobrevivem a reinícios. LEIA ISTO no começo de um "
        "trabalho não-trivial.",
        {},
    ),

    # ----------------------------------------------------------------- escrita
    _tool(
        "create_instance", WRITE,
        "Cria uma instância. Retorna o path criado. Para vários objetos de uma vez, prefira "
        "batch — é um só undo e uma só permissão.",
        {
            "class_name": {"type": "string"},
            "parent_path": {"type": "string", "description": "Padrão 'Workspace'."},
            "name": {"type": "string"},
            "properties": {"type": "object", "description": "Ver formato de valores no system prompt."},
        },
        ["class_name"],
    ),
    _tool(
        "delete_instance", WRITE,
        "Remove uma instância (Parent=nil). Desfazível.",
        {"path": _PATH},
        ["path"],
    ),
    _tool(
        "set_property", WRITE,
        "Define uma propriedade. Ver formato de valores no system prompt.",
        {
            "path": _PATH,
            "name": {"type": "string"},
            "value": {"description": "Escalar JSON ou objeto {type, value}."},
        },
        ["path", "name", "value"],
    ),
    _tool(
        "set_source", WRITE,
        "Reescreve o código INTEIRO de um script. Para mudanças pontuais em script grande, use "
        "patch_source — gasta menos e não arrisca perder o resto do arquivo.",
        {"path": _PATH, "source": {"type": "string"}},
        ["path", "source"],
    ),
    _tool(
        "patch_source", WRITE,
        "Substitui um trecho exato do código por outro, igual a um find-and-replace. "
        "'old_text' precisa bater LITERALMENTE (com indentação) e aparecer uma única vez. "
        "Passa pelo ScriptEditorService, então respeita o editor aberto.",
        {
            "path": _PATH,
            "old_text": {"type": "string", "description": "Trecho exato a substituir."},
            "new_text": {"type": "string", "description": "Substituto."},
            "replace_all": {"type": "boolean", "description": "Substitui todas as ocorrências. Padrão false."},
        },
        ["path", "old_text", "new_text"],
    ),
    _tool(
        "move_instance", WRITE,
        "Muda o Parent de uma instância.",
        {"path": _PATH, "new_parent_path": {"type": "string"}},
        ["path", "new_parent_path"],
    ),
    _tool(
        "rename_instance", WRITE,
        "Renomeia uma instância.",
        {"path": _PATH, "new_name": {"type": "string"}},
        ["path", "new_name"],
    ),
    _tool(
        "clone_instance", WRITE,
        "Clona uma instância (com os filhos). Bom para repetir estruturas prontas.",
        {
            "path": _PATH,
            "parent_path": {"type": "string", "description": "Destino. Padrão: mesmo pai do original."},
            "name": {"type": "string", "description": "Nome do clone."},
            "count": {"type": "integer", "description": "Quantos clones. Padrão 1."},
        },
        ["path"],
    ),
    _tool(
        "set_attribute", WRITE,
        "Define um Attribute. Attributes são a forma idiomática de anexar dados a instâncias — "
        "prefira isto a criar IntValue/StringValue escondidos.",
        {
            "path": _PATH,
            "name": {"type": "string"},
            "value": {"description": "Escalar ou {type, value}. null remove o attribute."},
        },
        ["path", "name"],
    ),
    _tool(
        "set_tags", WRITE,
        "Adiciona ou remove tags do CollectionService. Tags são como se liga comportamento a "
        "objetos em escala — melhor que procurar por nome.",
        {
            "path": _PATH,
            "add": {"type": "array", "items": {"type": "string"}},
            "remove": {"type": "array", "items": {"type": "string"}},
        },
        ["path"],
    ),
    _tool(
        "batch", WRITE,
        "Executa várias operações de escrita como UMA transação: um só undo, uma só permissão. "
        "É assim que se constrói um projeto — não faça 40 chamadas separadas de create_instance. "
        "Cada op é {op, ...} com os mesmos argumentos da ferramenta correspondente. "
        "Ops: create_instance, delete_instance, set_property, set_source, move_instance, "
        "rename_instance, clone_instance, set_attribute, set_tags. "
        "Numa op de create você pode passar 'id': '$meu_id' e referenciar depois em parent_path "
        "ou path como '$meu_id' — resolve o path do que acabou de ser criado.",
        {
            "ops": {"type": "array", "items": {"type": "object"}},
            "label": {"type": "string", "description": "Rótulo do undo, ex: 'Criar sistema de portas'."},
            "stop_on_error": {"type": "boolean", "description": "Padrão true."},
        },
        ["ops"],
    ),
    _tool(
        "set_project_memory", WRITE,
        "Grava anotações sobre este projeto DENTRO do place, para você mesmo ler em sessões "
        "futuras. Guarde decisões de arquitetura, convenções e o porquê das coisas — não "
        "guarde o que dá para ler do código. Sobrescreve o conteúdo inteiro.",
        {"content": {"type": "string", "description": "Markdown. Reescreva por completo."}},
        ["content"],
    ),
    _tool(
        "insert_asset", WRITE,
        "Insere um asset do Roblox pelo ID (modelo, mesh, imagem) via InsertService.",
        {
            "asset_id": {"type": "integer"},
            "parent_path": {"type": "string", "description": "Padrão 'Workspace'."},
        },
        ["asset_id"],
    ),

    # -------------------------------------------------------------- modelagem
    _tool(
        "solid_op", WRITE,
        "Modelagem sólida (CSG): funde, subtrai ou intersecta peças, como o Union/Negate do "
        "Studio. É assim que se esculpe forma de verdade — janela num muro, cano oco, chanfro, "
        "encaixe — em vez de empilhar dezenas de peças calculadas na mão.\n"
        "  union     = funde base + parts numa peça só\n"
        "  subtract  = corta o volume de parts PARA FORA da base (buraco, vão, recorte)\n"
        "  intersect = fica só o volume onde base e parts se sobrepõem\n"
        "A base e as parts são CONSUMIDAS: viram a peça nova, que herda o nome, a cor e o "
        "material da base. Posicione tudo onde deve ficar ANTES de operar — a operação usa a "
        "posição atual das peças.",
        {
            "operation": {"type": "string", "enum": ["union", "subtract", "intersect"]},
            "base_path": {**_PATH, "description": "A peça que dá nome, cor e material ao resultado."},
            "parts": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Paths das outras peças da operação. Serão consumidas.",
            },
            "name": {"type": "string", "description": "Nome do resultado. Padrão: o nome da base."},
            "collision_fidelity": {
                "type": "string",
                "enum": ["Default", "Hull", "Box", "PreciseConvexDecomposition"],
                "description": "Como a colisão acompanha a forma. 'Hull' é barato; "
                               "'PreciseConvexDecomposition' respeita buracos e concavidades.",
            },
        },
        ["operation", "base_path", "parts"],
    ),
    _tool(
        "terrain_fill", WRITE,
        "Esculpe terreno de verdade (grama, rocha, água, areia) com as formas primitivas do "
        "Terrain. Terreno NÃO é peça: não vive na árvore, não tem path, e é o jeito certo de "
        "fazer chão, montanha, caverna, rio e ilha — peça esticada não passa por terreno.",
        {
            "shape": {"type": "string", "enum": ["block", "ball", "cylinder", "wedge"]},
            "position": {
                "type": "object",
                "description": "Centro, em studs: {x, y, z}.",
                "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "z": {"type": "number"}},
                "required": ["x", "y", "z"],
            },
            "size": {
                "type": "object",
                "description": "Para block e wedge: {x, y, z} em studs.",
                "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "z": {"type": "number"}},
            },
            "radius": {"type": "number", "description": "Para ball e cylinder."},
            "height": {"type": "number", "description": "Para cylinder."},
            "orientation": {
                "type": "object",
                "description": "Rotação em GRAUS: {x, y, z}. Só para block, wedge e cylinder.",
                "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "z": {"type": "number"}},
            },
            "material": {
                "type": "string",
                "description": "Nome do Enum.Material: Grass, Rock, Sand, Water, Snow, Mud, "
                               "Basalt, LeafyGrass... 'Air' APAGA o terreno da região (é assim "
                               "que se cava caverna e túnel).",
            },
        },
        ["shape", "position", "material"],
    ),

    # --------------------------------------------------------------- execução
    _tool(
        "run_code", EXECUTE,
        "Executa Luau dentro do Studio em edit mode e retorna o que foi devolvido, o que foi "
        "impresso e qualquer erro. É a sua ferramenta mais poderosa.\n"
        "Use para: TESTAR um ModuleScript de verdade (require + asserts) sem entrar em "
        "playtest; gerar geometria em massa; usar serviços que não têm ferramenta própria.\n"
        "O código roda com permissão de plugin. 'game' e os serviços estão disponíveis. "
        "Dê return no que quiser inspecionar. Mudanças feitas aqui entram num waypoint de undo, "
        "mas nem tudo é reversível — pense antes.",
        {
            "code": {"type": "string", "description": "Código Luau. Pode usar return."},
            "label": {"type": "string", "description": "O que isto faz, para o undo e para o usuário ler."},
            "timeout": {"type": "number", "description": "Segundos. Padrão 10."},
        },
        ["code"],
    ),
    _tool(
        "run_playtest", EXECUTE,
        "Inicia uma simulação no Studio (equivale ao botão Run): a física roda e os Scripts do "
        "servidor executam de verdade.\n"
        "ATENÇÃO — isto é DESTRUTIVO: parar a simulação NÃO restaura o place. O que a física "
        "derrubar e os scripts criarem PERMANECE, e o Ctrl+Z não desfaz de forma confiável. "
        "Só use quando o comportamento em runtime for realmente o objeto do teste, avise o "
        "usuário antes, e prefira run_code com require+asserts para testar lógica.",
        {
            "duration": {"type": "number", "description": "Segundos rodando antes de parar sozinho. Padrão 3."},
            "capture_output": {"type": "boolean", "description": "Devolve o Output gerado. Padrão true."},
        },
    ),
]

TOOLS_BY_NAME: Dict[str, Dict[str, Any]] = {d["name"]: d for d in TOOL_DEFS}
TOOL_NAMES = set(TOOLS_BY_NAME)


def permission_of(name: str) -> str:
    """Classe de permissão de uma ferramenta. Desconhecida => trata como EXECUTE."""
    d = TOOLS_BY_NAME.get(name)
    return d["permission"] if d else EXECUTE


def api_tool_defs() -> List[Dict[str, Any]]:
    """Definições no formato da API Anthropic (sem o campo 'permission')."""
    return [
        {"name": d["name"], "description": d["description"], "input_schema": d["input_schema"]}
        for d in TOOL_DEFS
    ]
