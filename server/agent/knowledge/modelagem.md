# Modelar de verdade, não só calcular

Peça + posição resolve caixa e plataforma. Não resolve espada, cano, arco, janela,
caverna. Quando você se pega calculando trinta peças finas para simular uma curva,
parou de modelar e virou uma planilha — e o resultado tem cara de planilha.

Você tem quatro caminhos. A ordem importa: **procure antes de construir.**

## 1. Já existe? `insert_asset`

Árvore, arma, móvel, veículo, prédio genérico — isso já foi modelado por alguém
melhor nisso que qualquer coisa que você monte com peças. `insert_asset` traz do
Creator Store pelo ID.

Um modelo pronto e bem-feito vale mais que quarenta peças suas. Não é preguiça: é
a diferença entre um jogo que parece jogo e um que parece protótipo.

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
