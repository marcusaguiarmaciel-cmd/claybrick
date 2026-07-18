# O Studio como editor

Você trabalha em **edit mode**, não dentro do jogo rodando. Boa parte dos bugs
que um agente entrega vem de esquecer essa diferença.

## Edit mode não é o jogo

Quando você usa `run_code`, não existe:

- **jogador** — `Players.LocalPlayer` é `nil`, não há `Character`, não há `Humanoid`
- **física simulando** — nada cai, nada colide de verdade
- **eventos de gameplay** — nada de `PlayerAdded`, `Touched`, `Heartbeat` valendo

O que existe: a árvore de instâncias, as propriedades e o `require` de
ModuleScript. É por isso que a lógica pura (economia, inventário, cálculo, dano)
se testa aqui, barato e sem sujeira — e por que só o que depende de runtime de
verdade justifica `run_playtest`, que é destrutivo.

Escreva o código para ser testável assim: lógica em ModuleScript puro, e o
Script/LocalScript só liga os fios. Um módulo que chama `LocalPlayer` na primeira
linha não dá pra testar em edit mode.

## Anchored: o bug que só aparece depois que você entregou

Peça nova nasce com `Anchored = false`. Em edit mode ela fica parada e parece
certa. No primeiro playtest, ela **cai**.

Plataforma, parede, chão, decoração, qualquer coisa estrutural: **`Anchored = true`**,
sempre. Deixe solto só o que tem que se mexer de verdade.

Isso é o tipo de coisa que você não vê e o usuário vê. Ao criar peça, decida
Anchored conscientemente — não por omissão.

## Três interruptores diferentes, que todo mundo confunde

- **`CanCollide`** — se bate fisicamente.
- **`CanTouch`** — se dispara `Touched`. **`CanCollide = false` NÃO desliga o
  `Touched`.** Um coletável atravessável continua detectando o toque, e é assim
  que ele deve ser.
- **`CanQuery`** — se aparece em raycast e `GetPartBoundsInBox`.

"Passa através mas coleta" = `CanCollide = false`, `CanTouch = true`. É o padrão
de moeda, checkpoint e zona de gatilho.

`Massless` só importa em peça solta grudada em algo.

## Propriedades antes do Parent

```lua
local p = Instance.new("Part")
p.Size = Vector3.new(4, 1, 4)
p.Anchored = true
p.Position = Vector3.new(0, 10, 0)
p.Parent = workspace       -- por último, sempre
```

Parentear primeiro faz cada propriedade seguinte disparar mudança e replicação.
Parentear por último entrega o objeto pronto. Num `batch` de 200 peças isso é a
diferença entre instantâneo e travar o Studio.

## Attributes, não IntValue pendurado

`SetAttribute` / `GetAttribute` / `GetAttributeChangedSignal` vivem em qualquer
`Instance`. Não crie `IntValue`/`StringValue` filho para guardar dado — isso é
padrão de 2015.

```lua
moeda:SetAttribute("Valor", 10)
local v = moeda:GetAttribute("Valor")
moeda:GetAttributeChangedSignal("Valor"):Connect(...)
```

Atributos replicam, aparecem no painel de Propriedades e o usuário consegue
editar à mão. Um `Folder` cheio de `IntValue` não tem nenhuma dessas vantagens.

## Tags: já estão na Instance

```lua
moeda:AddTag("Coletavel")
if moeda:HasTag("Coletavel") then ... end
CollectionService:GetTagged("Coletavel")          -- para buscar todas
CollectionService:GetInstanceAddedSignal("Coletavel"):Connect(ligar)
```

`AddTag`, `HasTag`, `RemoveTag` e `GetTags` são métodos de `Instance` — não
precisa passar pelo `CollectionService` para marcar. O Service continua sendo
quem **busca** e quem avisa quando algo é marcado.

Tag + `GetInstanceAddedSignal` é o jeito de fazer "todo objeto com esta marca
ganha este comportamento", inclusive os criados depois. É muito melhor que
percorrer o Workspace procurando por nome.

## `game:GetService()`, não `game.Players`

```lua
local Players = game:GetService("Players")          -- sempre funciona
local rs = game:GetService("ReplicatedStorage")
```

`game.Players` depende do serviço já existir na árvore. `GetService` cria se
precisar. Em código de plugin e em edit mode isso importa mais ainda.

## WaitForChild: onde precisa e onde atrapalha

- **Cliente esperando algo replicado** — `WaitForChild`. O objeto pode não ter
  chegado ainda.
- **Servidor lendo o que você mesmo acabou de criar** — índice direto. O objeto
  já está lá; `WaitForChild` só adiciona ruído.

`WaitForChild` sem timeout que nunca resolve trava calado. Se o objeto pode
legitimamente não existir, passe timeout e trate o `nil`.

## StreamingEnabled

Com streaming ligado, **o cliente pode não ter a peça** que existe no servidor.
Código de cliente que assume `workspace.Mapa.Porta` existir quebra longe da
origem. No cliente, prefira tag + sinal a caminho fixo.

## Ctrl+Z é do usuário

Cada ferramenta sua é um waypoint de undo, e cada `batch` é um só. Isso é feito
para o usuário poder desfazer você. Um `batch` coeso não é só mais barato — é o
que torna o seu trabalho reversível num gesto.
