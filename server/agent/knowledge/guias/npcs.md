# NPCs: andar, perceber e decidir

> Quando fizer inimigo, aliado, animal, vendedor que anda, ou qualquer coisa que se mova sozinha e reaja ao jogador.

Três problemas separados, e vale resolver um de cada vez: **como ele anda**
(navegação), **o que ele sabe** (percepção) e **o que ele faz com isso**
(decisão). NPC ruim quase sempre é NPC com os três embolados no mesmo `while`.

## Andar

Para linha reta e curta, `Humanoid:MoveTo` resolve e é barato. Não desvia de
nada: se tiver parede no caminho, ele empurra a parede até desistir.

Com obstáculo, use `PathfindingService`:

```lua
local PathfindingService = game:GetService("PathfindingService")

local caminho = PathfindingService:CreatePath({
    AgentRadius = 2,        -- meia largura do NPC; pequeno demais e ele raspa
    AgentHeight = 5,
    AgentCanJump = true,
    AgentMaxSlope = 45,
    Costs = { Agua = 20 },  -- material com custo alto: evita, mas usa se precisar
})

local function irAte(npc: Model, destino: Vector3): boolean
    local raiz = npc.PrimaryPart
    local humanoide = npc:FindFirstChildOfClass("Humanoid")
    if not raiz or not humanoide then return false end

    local ok = pcall(function()
        caminho:ComputeAsync(raiz.Position, destino)
    end)
    if not ok or caminho.Status ~= Enum.PathStatus.Success then
        return false   -- sem caminho: não finja que deu certo
    end

    for _, ponto in caminho:GetWaypoints() do
        if ponto.Action == Enum.PathWaypointAction.Jump then
            humanoide.Jump = true
        end
        humanoide:MoveTo(ponto.Position)
        -- MoveToFinished tem timeout próprio; sem ele, NPC preso trava a rotina
        local chegou = humanoide.MoveToFinished:Wait()
        if not chegou then return false end
    end
    return true
end
```

Três armadilhas aqui:

- **`ComputeAsync` é caro.** Não recalcule por frame. Recalcule em intervalo
  (0,3–1 s) **ou** quando o alvo tiver se afastado o bastante do destino antigo.
- **O caminho envelhece.** Porta que fechou, ponte que caiu: escute
  `caminho.Blocked` e recalcule em vez de andar contra a parede.
- **`MoveToFinished` devolve `false` no timeout** de 8 s. Trate: NPC entalado que
  fica esperando para sempre é o bug clássico.

## Perceber

Distância é o filtro barato; visão é o caro. Faça nessa ordem.

```lua
local function enxerga(npc: BasePart, alvo: BasePart, alcance: number): boolean
    local delta = alvo.Position - npc.Position
    if delta.Magnitude > alcance then return false end   -- barato, corta cedo

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {npc.Parent}     -- não bata em si mesmo

    local hit = workspace:Raycast(npc.Position, delta, params)
    return hit ~= nil and hit.Instance:IsDescendantOf(alvo.Parent)
end
```

Para achar o jogador mais próximo, itere `Players:GetPlayers()` e compare
`Magnitude` — não use `GetDescendants` do Workspace. E confira `Humanoid.Health > 0`
antes de perseguir: NPC caçando cadáver é engraçado uma vez.

## Decidir: máquina de estados

O `if` aninhado dentro do loop vira intratável na terceira condição. Estado
nomeado com uma função por estado se lê e se estende:

```lua
type Estado = "patrulhando" | "perseguindo" | "atacando" | "voltando"

local function pensar(npc)
    local alvo = jogadorMaisProximo(npc, ALCANCE_VISAO)

    if npc.estado == "patrulhando" then
        if alvo then npc.estado = "perseguindo" end

    elseif npc.estado == "perseguindo" then
        if not alvo then
            npc.estado = "voltando"
        elseif distancia(npc, alvo) < ALCANCE_ATAQUE then
            npc.estado = "atacando"
        elseif distancia(npc, npc.casa) > LEASH then
            npc.estado = "voltando"   -- não persegue o jogador pelo mapa inteiro
        end

    elseif npc.estado == "atacando" then
        if not alvo or distancia(npc, alvo) > ALCANCE_ATAQUE * 1.3 then
            npc.estado = "perseguindo"   -- histerese: sai com folga maior do
        end                              -- que entrou, senão ele oscila
    end
end
```

Duas coisas que fazem diferença de acabamento: **leash** (limite de perseguição,
senão o inimigo do spawn te segue até o chefe) e **histerese** (a distância para
sair de um estado é maior que a para entrar, senão o NPC vibra entre dois
estados na fronteira).

Rode o `pensar` em intervalo (0,1–0,3 s), não por frame. Decisão de IA não
precisa de 60 Hz; movimento sim, e quem cuida disso é o Humanoid.

## Custo, quando são muitos

`Humanoid` é caro. Vinte NPCs com Humanoid completo pesam de verdade, e a maior
parte do custo é de coisa que um zumbi não usa.

- Desligue os `HumanoidStateType` que não usam: `Climbing`, `Swimming`,
  `Ragdoll`, `PlatformStand`. `humanoide:SetStateEnabled(estado, false)`.
- NPC decorativo (peixe, pássaro, gente de fundo) não precisa de Humanoid:
  `CFrame` interpolado ou `AlignPosition`/`AlignOrientation` resolve.
- NPC longe do jogador pode pensar bem mais devagar, ou não pensar. Ninguém vê.
- Um único laço central iterando a lista de NPCs bate um `while` por NPC.

## Animação

`Humanoid:LoadAnimation` está deprecado. O caminho atual é o `Animator`:

```lua
local animator = humanoide:FindFirstChildOfClass("Animator")
    or Instance.new("Animator", humanoide)
local faixa = animator:LoadAnimation(animacao)
faixa.Looped = true
faixa:Play()
```

Carregue as faixas **uma vez**, no início, e guarde. `LoadAnimation` a cada
ataque vaza e engasga.

## Onde o NPC roda

No **servidor**, sempre, se ele causa dano ou decide qualquer coisa. NPC
controlado pelo cliente é NPC que o jogador controla.

Se o movimento ficar tremido para quem assiste, o problema é taxa de atualização,
não o lado: reduza a frequência de recálculo e deixe a interpolação para o
cliente, mas mantenha a decisão no servidor.

## Antes de entregar

- [ ] `ComputeAsync` dentro de `pcall`, com `Status` conferido
- [ ] Caminho recalculado por intervalo/evento, nunca por frame
- [ ] `MoveToFinished` com o retorno tratado
- [ ] `caminho.Blocked` escutado
- [ ] Leash e histerese nos estados
- [ ] Estados de Humanoid não usados desligados
- [ ] Faixas de animação carregadas uma vez só
- [ ] A decisão mora no servidor
