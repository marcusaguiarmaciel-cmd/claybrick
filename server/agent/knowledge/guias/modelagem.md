# Modelar de verdade, não só calcular

> Quando for construir forma no mundo: arma, veículo, prédio, cenário, terreno. Leia ANTES de empilhar peça.

Peça + posição resolve caixa e plataforma. Não resolve espada, cano, arco, janela,
caverna. Quando você se pega calculando trinta peças finas para simular uma curva,
parou de modelar e virou uma planilha — e o resultado tem cara de planilha.

Você tem quatro caminhos. A ordem importa: **procure antes de construir.**

## 1. Já existe? `search_assets` e depois `insert_asset`

Árvore, arma, móvel, veículo, prédio genérico — isso já foi modelado por alguém
melhor nisso que qualquer coisa que você monte com peças.

```
search_assets(keyword="oak tree")   -> nome, ID, criador, votos
insert_asset(asset_id=580221169)    -> entra no place
```

**Busque em inglês.** O acervo é quase todo em inglês, e "árvore" acha muito
menos que "tree".

**Nunca invente um ID.** Número chutado ou falha no carregamento, ou traz uma
coisa completamente diferente da que você prometeu. O ID vem da busca, sempre.

A busca **já vem filtrada e ordenada**: some o que está vazio, o que é sistema de
script disfarçado de modelo, o que tem densidade alta demais para um prop, e o que
os votos reprovaram. Ela também confere a classificação da própria Roblox, então
"bicycle" não devolve bicicletário. Cada resultado traz o motivo de estar ali.
Confie na ordem: o primeiro é o melhor pelos critérios que dá para medir.

Se o resultado disser **CONTÉM SCRIPTS**, é código de terceiro que vai rodar no
place do usuário no primeiro playtest. Diga a ele antes de inserir.

## Forma orgânica não se constrói com peça. Nunca.

Isto não é preferência, é o que o acervo mostra. Numa busca por bicicleta, de 25
modelos, **um** era feito de peças: todo o resto é mesh, porque quem sabe modelar
sabe que bicicleta com peça fica ruim. O mesmo vale para árvore, animal, pessoa,
capacete, planta.

Se você se pegar montando forma orgânica com Part e Wedge, **pare e busque**. Não
existe capricho suficiente para salvar aquilo: você vai entregar uma coisa
funcional que não parece a coisa. Peça e CSG são para o que é geométrico — banco,
poste, mesa, muro, prédio, escada.

E quando quiser **aprender proporção** de algo geométrico, `search_assets` com
`para_estudar=true` devolve só modelos feitos de peças. Insira um, leia com
`get_tree` e `get_properties`, veja os tamanhos reais, apague. É a forma mais
barata de descobrir que o assento do banco fica a 1,7 stud do chão em vez de
chutar.

Um modelo pronto e bem-feito vale mais que quarenta peças suas. Não é preguiça: é
a diferença entre um jogo que parece jogo e um que parece protótipo.

## Quantas peças a coisa precisa ter

O motivo mais comum de uma construção sua "chegar perto e ainda ficar feia" não é
proporção nem cor: é **densidade**. Você monta a silhueta certa com poucas peças,
para, e entrega. O acervo mostra outro patamar.

Medindo 328 modelos do Creator Store feitos de peças (sem mesh), em 12 termos:

| Percentil | Peças equivalentes |
|---|---|
| 25% | ~23 |
| mediana | ~79 |
| 75% | ~300 |

Uma construção sua de 12 peças fica **abaixo do quartil inferior de tudo que
existe publicado**. Não é um pouco mais simples: é mais simples que 75% do acervo.

O orçamento acompanha o assunto, não o seu cansaço:

- Objeto de forma simples (caixa, porta, mesa, banco): 10 a 30 peças. Aqui pouco
  é certo, e os modelos mais usados do acervo vivem nessa faixa.
- Objeto com mecanismo ou estrutura repetida (cadeira, poste, escada, cerca,
  espada): 40 a 150.
- Cenário ou construção (casa, loja, praça): 300 para cima. Uma casa de 40 peças
  é uma maquete, não uma casa.

Depois de construir, `inspect_space` devolve o número de peças. **Compare com a
faixa antes de entregar.** Se ficou abaixo, você não terminou: falta o detalhe
que separa a silhueta do objeto. Parafuso, moldura, junta, ripa, quina chanfrada,
espessura de borda. É isso que o olho lê como "modelado".

E o inverso vale: se um objeto simples passou de 300 peças, você está montando na
mão o que devia ser um `subtract` ou um mesh.

> A medida vem dos triângulos que a Roblox publica, convertidos a peça
> equivalente. Serve para dizer em que faixa você está, não para bater ponto:
> forma redonda gasta muito mais triângulo que bloco, então em construção cheia
> de cilindro a contagem real de peças é menor que a estimada.

## 2. Forma esculpida? `solid_op` (CSG)

É o Union/Negate do Studio. É o que transforma "peça" em "objeto".

- **`subtract`** — o que mais rende. Buraco, vão, janela, cano oco, encaixe,
  fresta. Você posiciona a peça que vai virar o buraco e subtrai.
- **`union`** — junta o que já está posicionado numa peça só.
- **`intersect`** — fica só a sobreposição. Bom para chanfro e para cortar uma
  forma dentro de outra.

Cano oco = cilindro maior, cilindro menor dentro, `subtract`. Muro com janela =
bloco, bloco menor no lugar do vão, `subtract`. Isso é uma operação, não trinta
peças.

Regras que evitam frustração:

- **Posicione tudo ANTES.** A operação usa onde as peças estão agora.
- **As peças são consumidas.** O resultado herda nome, cor e material da base.
- **Precisa haver sobreposição real.** Peça que não encosta na outra não subtrai
  nada, e CSG recusa volume degenerado.
- **Colisão não segue a forma sozinha.** Buraco atravessável pede
  `collision_fidelity: "PreciseConvexDecomposition"`; sem isso o vão fica
  invisível para o jogador mas sólido para o corpo dele. `Hull` é o barato, para
  o que é maciço.
- Não empilhe união sobre união sem necessidade — cada camada é geometria mais
  cara.

## 3. É chão, montanha, caverna, rio? `terrain_fill`

Terreno não é peça. Não está na árvore, não tem path, e é o que faz um mapa
parecer um lugar em vez de um tabuleiro. Peça verde esticada nunca vira grama.

- `block`, `ball`, `cylinder`, `wedge` — as formas primitivas.
- Material de verdade: `Grass`, `Rock`, `Sand`, `Water`, `Snow`, `Mud`, `Basalt`,
  `LeafyGrass`.
- **`Air` apaga.** É assim que se cava: preencha a montanha com `Rock`, depois
  passe `Air` por dentro e você tem caverna. Túnel é um cilindro de `Air`.

Ilha = `ball` de `Rock` grande, `ball` de `Sand` menor por cima, `Air` por baixo
da linha d'água. Sobreponha as formas; terreno funde sozinho, sem emenda.

## 4. Só então: peça e matemática

Estrutura, plataforma, parede, grade, escada — aí sim `create_instance` num
`batch`. É rápido, é barato e é reversível.

Continue valendo o que sempre valeu: `Anchored = true` em tudo que é estrutura,
propriedades antes do `Parent`, e a convenção do -Z para o que tem frente.

`solid_op`, `terrain_fill` e `insert_asset` também são ops de `batch`. Então
esculpir é uma transação, não uma sequência de permissões: crie o muro e o bloco
do vão com `id`, e subtraia um do outro no mesmo lote.

```json
[{"op":"create_instance","id":"$muro","class_name":"Part", "...": "..."},
 {"op":"create_instance","id":"$vao", "class_name":"Part", "...": "..."},
 {"op":"solid_op","operation":"subtract","base_path":"$muro","parts":["$vao"]}]
```

## 5. Depois de construir, MEÇA

Você não enxerga o que fez. `inspect_space` é como você confere: ele devolve o
tamanho real do conjunto, o que ficou com `Anchored=false` (e vai cair), o que
está atravessando o que, e o que está boiando no ar.

Rode antes de entregar. Uma casa que saiu com 3 studs de altura, uma parede
enfiada dentro da outra, um móvel a 40 studs do chão: tudo isso aparece ali, em
número, e não aparece em lugar nenhum se você só reler o próprio código.

Ele também devolve `parts`. Confira contra a faixa da seção de densidade antes de
dizer que acabou, e confira `smallest_part`: se a sua menor peça tem 1 stud ou
mais, não existe detalhe nenhum na construção. Detalhe vive entre 0,1 e 0,4 stud.

## Acabamento é o que separa protótipo de asset

Forma certa com acabamento errado ainda parece protótipo:

- **`Material`** faz mais pela aparência que `Color`. `Neon`, `Glass`, `Metal`,
  `Wood`, `Concrete`, `Fabric` mudam como a luz responde. `SmoothPlastic` é o
  padrão sem graça — e é o que denuncia peça não pensada.
- **`Transparency` + `Neon`** = luz, sem PointLight.
- Peça pequena não precisa de colisão: `CanCollide = false` em decoração, e o
  jogador não tropeça no que é enfeite.
- `CanQuery = false` em coisa decorativa alivia raycast.
- Chanfro e vinco são o que fazem parecer modelado. Um `subtract` de chanfro nas
  quinas de uma caixa muda mais a leitura do objeto do que qualquer cor.

## O que você não consegue fazer, e é honesto dizer

Você não modela vértice a vértice, não pinta textura e não esculpe malha
orgânica. Para personagem, criatura ou objeto muito detalhado, o caminho é
`insert_asset` ou um mesh feito em Blender.

Prometer uma espada linda com peça e CSG e entregar um retângulo pontudo é pior
que dizer "para isto o certo é um mesh; posso montar a versão em CSG por
enquanto, ou você importa um modelo".
