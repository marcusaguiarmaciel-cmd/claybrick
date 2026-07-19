# Animação: personagem e objeto se mexendo

> Quando for animar personagem, NPC, arma, porta, máquina, ou tocar qualquer Animation.

Duas famílias, e confundir as duas é o erro de partida: **animação de rig**
(esqueleto com juntas, feita no editor de animação) e **movimento interpolado**
(`TweenService`, para porta, plataforma, UI). Porta girando não precisa de rig.
Personagem andando não se resolve com tween.

## O caminho atual

`Humanoid:LoadAnimation` está **deprecado**. Quem carrega é o `Animator`:

```lua
local humanoide = personagem:WaitForChild("Humanoid")
local animator = humanoide:FindFirstChildOfClass("Animator")
    or Instance.new("Animator", humanoide)

local anim = Instance.new("Animation")
anim.AnimationId = "rbxassetid://1234567890"

local faixa = animator:LoadAnimation(anim)
faixa.Looped = true
faixa.Priority = Enum.AnimationPriority.Action
faixa:Play(0.2)   -- 0.2s de fade de entrada, em vez de estalar no lugar
```

Para modelo **sem Humanoid** (uma máquina, um portão articulado), o par é
`AnimationController` + `Animator` dentro dele.

**Carregue uma vez e guarde.** `LoadAnimation` a cada ataque vaza memória e
engasga. O padrão é uma tabela de faixas montada no início:

```lua
local faixas = {}
for nome, id in pairs(IDS) do
    local a = Instance.new("Animation")
    a.AnimationId = id
    faixas[nome] = animator:LoadAnimation(a)
end
```

## Prioridade, ou por que a animação não aparece

Se duas animações mexem no mesmo membro, a de prioridade maior ganha. A ordem,
da menor para a maior:

`Core` → `Idle` → `Movement` → `Action` → `Action2` → `Action3` → `Action4`

O sintoma clássico: você toca a animação de ataque, ela é `Idle` ou `Core`, e a
animação de correr do Humanoid (que é `Movement`) passa por cima. Ataque é
`Action`. Se a animação simplesmente "não faz nada", **prioridade é a primeira
coisa a conferir**, antes de duvidar do ID.

Para animar só a metade de cima (atirar andando), a animação precisa ter sido
exportada mexendo apenas nas juntas do tronco e braços, com prioridade acima da
de movimento. Não existe máscara de camada aqui: quem resolve isso é o próprio
arquivo de animação.

## Misturar

`AdjustWeight` mistura duas faixas; `AdjustSpeed` acelera. O uso mais útil é
casar velocidade da animação com velocidade real, para o pé parar de patinar:

```lua
local base = 16   -- a velocidade em que a animação foi feita
faixaCorrer:AdjustSpeed(humanoide.WalkSpeed / base)
```

## Reagir a um momento da animação

Não use `task.wait(0.4)` para acertar o instante do golpe: a animação pode estar
com velocidade ajustada, e o número quebra. Use marcador, que é posto no editor
de animação e viaja junto com o arquivo:

```lua
faixaAtaque:GetMarkerReachedSignal("Impacto"):Connect(function()
    aplicarDano()
end)
```

`faixa.Stopped` e `faixa.Ended` avisam o fim. `faixa:Stop(0.15)` sai com fade;
`faixa:Stop(0)` corta seco.

## Onde tocar

Animação tocada no **servidor replica** para todos os clientes. Animação tocada
no cliente aparece só para ele. Isso dá o padrão de sempre:

- Ação que todos precisam ver (ataque, emote, morte): toque no **servidor**, ou
  toque no cliente do dono e avise o servidor para replicar aos demais.
- Feedback puramente local: cliente.

Tocar no cliente do próprio jogador responde na hora, sem esperar a rede. Se a
sensação de atraso importar (jogo de luta, shooter), toque local **e** mande o
servidor replicar para os outros.

## Permissão do asset

Uma animação só toca se pertencer ao dono do jogo (sua conta ou o grupo do jogo).
Animação de outra pessoa falha em silêncio ou dá erro de permissão. Se o usuário
pedir "põe essa animação da toolbox" e não tocar, quase sempre é isso, e a
solução é ele reenviar pela conta dele. Você não tem como contornar.

R6 e R15 têm esqueletos diferentes: animação de um **não** serve no outro.

## Objeto que não é personagem

Porta, plataforma, elevador, câmera: `TweenService`.

```lua
local TweenService = game:GetService("TweenService")

local info = TweenInfo.new(
    1.2,                            -- duração
    Enum.EasingStyle.Quad,          -- curva
    Enum.EasingDirection.Out,       -- desacelera no fim
    0, false, 0                     -- repetições, vai-e-volta, atraso
)

TweenService:Create(porta, info, {CFrame = alvoCFrame}):Play()
```

Tween em peça **ancorada** funciona limpo. Em peça não ancorada, ele briga com a
física e o resultado treme: ancore, ou use constraint.

`Linear` parece robótico. `Quad`/`Sine` com `Out` é o padrão que parece natural
em quase tudo. `Back` e `Elastic` dão personalidade, mas cansam se usados em
tudo.

## Custo

- Faixa carregada é barata parada; **muitos Humanoids animando ao mesmo tempo é
  caro**. NPC longe pode ter a animação parada sem ninguém notar.
- `Motor6D` é o que permite animar: rig sem Motor6D não anima, por mais correto
  que esteja o código.
- Tween em dezenas de objetos por frame pesa. Para muitos objetos iguais,
  considere um só tween num modelo soldado.

## Antes de entregar

- [ ] `Animator:LoadAnimation`, nunca `Humanoid:LoadAnimation`
- [ ] Faixas carregadas uma vez e guardadas
- [ ] `Priority` coerente com o que a animação faz
- [ ] Momento de impacto por marcador, não por `task.wait` cronometrado
- [ ] Fade de entrada e saída em vez de corte seco
- [ ] Quem precisa ver, vê (tocou no lado certo)
- [ ] Tween só em peça ancorada
