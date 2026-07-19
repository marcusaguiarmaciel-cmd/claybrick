# Física: mover sem quebrar a simulação

> Quando algo tiver que cair, colidir, ser empurrado, flutuar, girar ou seguir alguém. E sempre que pensar em BodyVelocity.

O erro que define código de física velho no Roblox é usar os **BodyMovers**
(`BodyVelocity`, `BodyPosition`, `BodyGyro`, `BodyThrust`). Estão deprecados há
anos. Modelo treinado em fórum antigo cospe eles por reflexo, e eles ainda
"funcionam", o que é pior: o usuário só descobre que está em cima de API morta
quando algo se comporta estranho.

## A tabela de tradução

| Não use | Use | Para |
|---|---|---|
| `BodyVelocity` | `LinearVelocity` | manter velocidade constante |
| `BodyPosition` | `AlignPosition` | puxar até uma posição |
| `BodyGyro` | `AlignOrientation` | manter/girar para uma orientação |
| `BodyAngularVelocity` | `AngularVelocity` | giro constante |
| `BodyForce`/`BodyThrust` | `VectorForce` | força contínua |
| `part.Velocity` | `part.AssemblyLinearVelocity` | ler/setar velocidade |

Todo constraint moderno trabalha com **Attachment**, não direto na peça:

```lua
local anexo = Instance.new("Attachment")
anexo.Parent = parte

local vel = Instance.new("LinearVelocity")
vel.Attachment0 = anexo
vel.MaxForce = 100000
vel.VectorVelocity = Vector3.new(0, 50, 0)
vel.Parent = parte
```

`MaxForce` baixo demais é o motivo número um de "o constraint não faz nada": ele
não consegue vencer a gravidade e a massa.

## Impulso, não teletransporte

Para um empurrão único (explosão, pulo, knockback), não crie constraint: aplique
impulso e siga a vida.

```lua
-- Impulso leva a massa em conta: mesma força, peças de massas diferentes
-- reagem diferente, que é o que a pessoa espera ver.
parte:ApplyImpulse(direcao.Unit * forca * parte.AssemblyMass)
```

Setar `AssemblyLinearVelocity` direto também funciona e ignora massa. Use quando
quiser velocidade exata (um projétil), não quando quiser força (uma explosão).

## Ancorado, colisão e consulta

- `Anchored = true`: a física não mexe. Peça de cenário deve ser ancorada; peça
  ancorada que você quer mover, você move por `CFrame`, não por força.
- `CanCollide`: bate em coisa.
- `CanTouch`: dispara `Touched`.
- `CanQuery`: aparece em raycast.

Essas três são independentes, e separá-las resolve muita coisa: um trigger de
área é `CanCollide = false`, `CanTouch = true`. Um efeito decorativo é
`CanCollide = false`, `CanTouch = false`, `CanQuery = false`, e assim para de
custar nas três contas.

**Uma "assembly" é o conjunto de peças unidas** por solda ou constraint. Massa,
velocidade e dono de rede são da assembly inteira, não da peça. Por isso
`AssemblyLinearVelocity` tem esse nome.

## Grupo de colisão

Para "o inimigo não empurra o jogador" ou "a bala atravessa o aliado", não fique
inventando lógica: use grupo de colisão.

```lua
local PhysicsService = game:GetService("PhysicsService")

PhysicsService:RegisterCollisionGroup("Inimigos")
PhysicsService:CollisionGroupSetCollidable("Inimigos", "Inimigos", false)

parte.CollisionGroup = "Inimigos"   -- na peça, não via método antigo do service
```

## Raycast, e por que `Touched` te trai

`Touched` **perde objeto rápido**. Uma bala a 200 studs/s pula o outro lado da
parede entre dois quadros e nunca toca em nada. Além disso, `Touched` dispara
várias vezes e exige debounce.

Para projétil, use raycast entre a posição anterior e a atual, a cada passo:

```lua
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = {atirador, projetil}
params.IgnoreWater = true

local resultado = workspace:Raycast(posAnterior, posAtual - posAnterior, params)
if resultado then
    acertou(resultado.Instance, resultado.Position, resultado.Normal)
end
```

Existem também `workspace:Blockcast` e `workspace:Spherecast` para quando o
projétil tem grossura, e `workspace:GetPartBoundsInBox` para área.

`RaycastParams.Exclude` (ignora a lista) e `Include` (só considera a lista):
`Include` costuma ser mais rápido quando você sabe exatamente no que quer bater.

## Propriedades físicas do material

Atrito e quique não são globais: são do material da peça.

```lua
parte.CustomPhysicalProperties = PhysicalProperties.new(
    0.7,   -- densidade (afeta massa e flutuação)
    0.3,   -- atrito
    0.5,   -- elasticidade (quique)
    1, 1   -- pesos de atrito e elasticidade na mistura entre dois materiais
)
```

Gelo escorregadio é atrito baixo. Bola que quica é elasticidade alta. Caixa que
boia é densidade abaixo de ~1.

`workspace.Gravity` é 196.2 por padrão, o equivalente a 9,8 na escala do Roblox.
Mudar isso muda o jogo inteiro, e o pulo do personagem junto.

## Juntar peças

- **`WeldConstraint`**: cola duas peças na posição em que estão. É o que você
  quer em 90% dos casos.
- **`Weld`** (o antigo, com `C0`/`C1`): só quando precisar controlar o offset na
  mão.
- **`Motor6D`**: solda que pode ser animada. Personagem e qualquer coisa que
  anime precisa disso, não de `WeldConstraint`.
- Para um modelo inteiro se mover junto, solde tudo e deixe uma peça como
  `PrimaryPart`, ou use `Model:PivotTo()`.

Peça ancorada não solda com física: se uma das duas está `Anchored`, o conjunto
não cai.

## Quem simula

Física de objeto com dono de rede no cliente responde na hora, mas o cliente
manda na posição dela. Objeto que decide partida fica com o servidor.
Detalhe em `lookup_guide("networking")`.

## Em edit mode nada disso roda

`run_code` roda com a simulação parada: peça não cai, `Touched` não dispara,
constraint não puxa. Dá para conferir se o constraint foi **criado certo** (ler
de volta `Attachment0`, `MaxForce`, `Anchored`), mas comportamento físico só em
playtest. Diga isso ao usuário em vez de afirmar que testou.

## Antes de entregar

- [ ] Zero BodyMover; só constraints modernos
- [ ] Constraint com `Attachment` e `MaxForce` suficiente
- [ ] `CanCollide`/`CanTouch`/`CanQuery` ajustados de propósito
- [ ] Projétil rápido usa raycast, não `Touched`
- [ ] `Touched` (quando usado) tem debounce
- [ ] Cenário ancorado
- [ ] Se o comportamento físico não foi testado, isso foi dito
