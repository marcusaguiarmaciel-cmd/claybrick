# Studio além do básico

> Quando for mexer em modelo/pivô, material, iluminação da cena, organização do place, ou quando precisar entender o que o playtest do Studio realmente faz.

O essencial do editor (edit mode, `Anchored`, atributos, tags, `WaitForChild`)
está sempre no seu contexto. Aqui está o resto: o que aparece quando o trabalho
deixa de ser um script e vira um place.

## Modelo, pivô e caixa

Mover um modelo peça por peça é erro. `Model` tem operação própria:

```lua
modelo:PivotTo(CFrame.new(destino))          -- move o modelo inteiro
local cf: CFrame = modelo:GetPivot()          -- onde ele está

local cf, tamanho = modelo:GetBoundingBox()   -- caixa orientada pelo pivô
local tam: Vector3 = modelo:GetExtentsSize()  -- só o tamanho, alinhado ao mundo
```

O **pivô** é o ponto de referência do modelo, e é ele que define como o modelo
gira e encaixa. Modelo com pivô no lugar errado é o motivo de "a porta gira em
torno do nada". `WorldPivot` ajusta.

`PrimaryPart` ainda importa para código antigo e para soldar, mas `PivotTo` já
funciona sem ele.

Para posicionar sobre o chão sem enterrar, `GetExtentsSize().Y / 2` é a metade da
altura que você precisa somar.

## Colisão e detalhe de malha

Duas propriedades que resolvem muita reclamação de "atravessa a parede" e "está
pesado":

- **`CollisionFidelity`** em `MeshPart`/`Union`: `Box` (barato, caixa),
  `Hull` (casca convexa), `Default`, `PreciseConvexDecomposition` (caro e
  detalhado). Decoração deve ser `Box`, ou `CanCollide = false` e acabou.
- **`RenderFidelity`**: `Automatic` reduz o detalhe com a distância. Deixe
  `Precise` só no que fica perto da câmera.

Union tem custo maior que MeshPart equivalente. Se a forma é definitiva e
aparece muito, mesh ganha.

## Materiais

`SurfaceAppearance` dentro de um `MeshPart` substitui a textura por um conjunto
PBR (cor, normal, rugosidade, metal). É o que dá aparência moderna.

`MaterialService` + `MaterialVariant` permite redefinir um material do Roblox
(todo `Plastic` do jogo, por exemplo) sem tocar em cada peça. Serve para dar
identidade visual ao place inteiro de uma vez.

## Iluminação da cena

`Lighting.Technology` (`Voxel`, `ShadowMap`, `Future`) muda tudo: qualidade,
sombra e custo. `Future` é o bonito e o caro. Isso é escolha do place, não de uma
peça, e trocar altera a cara do jogo inteiro. Se for mudar, avise o usuário.

`Atmosphere`, `Sky`, `ClockTime`, `Ambient`, `OutdoorAmbient` e `Fog` definem o
clima. Detalhe visual em `lookup_guide("vfx")`.

## Organização do place

Um place que só você entende é um place que o usuário não consegue manter:

- `Workspace` limpo, com pastas por área (`Mapa`, `Spawns`, `NPCs`).
- Assets que o cliente não deve ver em `ServerStorage`; módulos compartilhados em
  `ReplicatedStorage`.
- Nome que diz o que é. `Part`, `Part1`, `Model2` espalhados pelo Workspace é
  dívida imediata.
- `Model` para agrupar o que é uma coisa só; `Folder` para agrupar o que é uma
  lista.

`Archivable = false` faz o objeto não ser copiado por `Clone` nem salvo. Útil
para coisa gerada em runtime que não deve virar parte do arquivo.

## Ctrl+Z, e por que ele funciona aqui

Cada ferramenta de escrita, e cada `batch`, vira um waypoint de undo do Studio.
Isso é o que permite o usuário confiar em você: ele sabe que dá para voltar.

Duas consequências práticas:

- **`batch` é melhor que 40 chamadas soltas** também por isso: vira um undo só,
  com rótulo. Quarenta waypoints obrigam quarenta Ctrl+Z.
- O que `run_code` e `run_playtest` fazem **nem sempre é reversível**. Aí o undo
  não é garantia, e você precisa avisar antes, não depois.

## Play, Run e Play Here não são a mesma coisa

- **Run**: inicia a simulação **sem** personagem. Física roda, scripts de
  servidor rodam. É o que `run_playtest` faz.
- **Play**: insere seu personagem e roda cliente e servidor na mesma sessão.
- **Play Here**: igual, mas nascendo onde a câmera está.
- **Team Test**: várias instâncias, servidor de verdade separado do cliente.

Isso importa porque **em Play o cliente e o servidor dividem o mesmo processo**,
e bug de replicação pode não aparecer. "Funcionou no Play" não prova que
funciona com cliente separado. Quando o assunto é replicação ou segurança, o
teste honesto é Team Test, e quem faz isso é o usuário.

E o principal: **parar a simulação não restaura o place**. O que caiu, caiu; o
que os scripts criaram, ficou. Por isso `run_code` em edit mode é o teste
preferido e `run_playtest` é o último recurso.

## Publicar e configurar

Coisas que só o usuário pode fazer, e que você deve **pedir** em vez de tentar:

- Ligar **Enable Studio Access to API Services** (sem isso, DataStore não roda no
  Studio).
- Ligar **HTTP Requests**, se o jogo for usar.
- Publicar o place (DataStore precisa de um place publicado).
- Enviar animação/áudio pela conta dona do jogo, para o asset ter permissão.

Quando algo falhar por um desses motivos, diga qual é e o caminho no menu. Não
fique tentando contornar: não tem como.

## Team Create

Se o usuário estiver em Team Create, outras pessoas podem estar editando ao mesmo
tempo. Mudança grande sem avisar pode atropelar o trabalho de alguém. Na dúvida,
prefira `batch` rotulado (fica claro no histórico) e diga o que vai fazer antes
de fazer.

## Antes de entregar

- [ ] Modelo movido com `PivotTo`, não peça por peça
- [ ] Pivô no lugar que faz sentido para como o objeto gira
- [ ] `CollisionFidelity` coerente com o uso
- [ ] Hierarquia com nomes e pastas que o usuário entende
- [ ] Escritas agrupadas em `batch` rotulado
- [ ] O que exige ação do usuário (API Services, publicar) foi dito com o caminho
