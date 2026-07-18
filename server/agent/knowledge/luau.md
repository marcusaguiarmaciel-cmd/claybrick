# Luau moderno e idiomático

Luau é o dialeto de Lua 5.1 do Roblox, com tipos graduais, compound assignment,
continue e várias otimizações. Escreva Luau de hoje, não Lua de 2015.

## Tipos

Comece todo script com `--!strict`. O analisador do Studio pega erros reais
antes de você rodar. Se `--!strict` gerar ruído demais num arquivo legado, use
`--!nonstrict`, mas em código novo não tem desculpa.

```lua
--!strict

export type Item = {
    id: string,
    nome: string,
    preco: number,
    tags: { string }, -- array de string
}

local function comprar(jogador: Player, item: Item): (boolean, string?)
    if item.preco < 0 then
        return false, "preço inválido"
    end
    return true, nil
end
```

- `?` = pode ser nil (`string?`).
- `{ T }` = array. `{ [K]: V }` = dicionário.
- `export type` deixa outro módulo importar com `Modulo.Item`.
- Retorno múltiplo se escreve `(boolean, string?)`.

## Padrão de ModuleScript

```lua
--!strict

local Inventario = {}
Inventario.__index = Inventario

export type Inventario = typeof(setmetatable({} :: {
    itens: { Item },
    dono: Player,
}, Inventario))

function Inventario.new(dono: Player): Inventario
    return setmetatable({ itens = {}, dono = dono }, Inventario)
end

function Inventario:adicionar(item: Item)
    table.insert(self.itens, item)
end

return Inventario
```

Um ModuleScript retorna **uma coisa** e é cacheado: o `require` só roda o corpo
na primeira vez, e todo mundo depois recebe a mesma referência. Isso é feature
(singleton de graça) e armadilha (estado global acidental).

`require` do servidor e do cliente são caches SEPARADOS — um ModuleScript em
`ReplicatedStorage` vira duas instâncias, uma em cada lado. Não espere que
escrever nele de um lado apareça no outro.

## task, não wait

A biblioteca `task` substituiu as globais antigas. Elas ainda funcionam mas são
mais lentas e imprecisas.

| Não use | Use |
|---|---|
| `wait(n)` | `task.wait(n)` |
| `spawn(f)` | `task.spawn(f)` |
| `delay(n, f)` | `task.delay(n, f)` |
| `wait()` em loop de render | `RunService.Heartbeat:Wait()` |

`task.defer` roda no fim do frame atual; `task.spawn` roda **imediatamente**,
até o primeiro yield. A diferença importa quando você está no meio de um
Changed.

## Erros

`pcall` para o que pode falhar de verdade (rede, DataStore, input do usuário).
Não embrulhe tudo em pcall — engolir erro de lógica esconde bug.

```lua
local ok, resultado = pcall(funcaoQuePodefFalhar, arg)
if not ok then
    warn("falhou:", resultado)
    return
end
```

Para erro do programador, prefira `assert` ou `error` — quer que estoure alto e
cedo:

```lua
local function setHealth(h: number)
    assert(h >= 0, "health não pode ser negativo")
    ...
end
```

## Conexões vazam

Toda `:Connect()` segura uma referência. Se você conecta a cada spawn e nunca
desconecta, o jogo degrada até morrer.

```lua
local conexoes: { RBXScriptConnection } = {}

table.insert(conexoes, humanoid.Died:Connect(aoMorrer))

-- na limpeza:
for _, c in conexoes do
    c:Disconnect()
end
table.clear(conexoes)
```

`Instance:Destroy()` desconecta o que estava ligado *àquela instância*, mas não
desconecta o que ela conectou em outras. Use `:Once()` quando o evento só
interessa uma vez.

## Iteração

Luau permite iterar direto, sem `pairs`/`ipairs`:

```lua
for _, jogador in Players:GetPlayers() do  -- generalizado, funciona
```

Continue usando `ipairs` se você precisa parar no primeiro nil de um array
esparso, e `pairs` se a ordem não importa e a tabela é dicionário. Mas em código
novo, `for _, v in t do` é o idioma.

## Sintaxe que é Luau, não Lua

Luau não é Lua 5.1. Se você escrever Lua clássico aqui, funciona — mas fica com
cara de código velho e mais longo do que precisa.

```lua
-- Interpolação de string: use isto, não `.. x ..`
local nome = "Ana"
print(`Bem-vinda, {nome}! Você tem {contador} moedas.`)
print(`Soma: {a + b}`)                    -- aceita expressão

-- Atribuição composta
pontos += 10
vida -= dano
nome ..= " (morto)"

-- continue existe (em Lua 5.1 não existe)
for _, p in pecas do
    if not p:IsA("BasePart") then continue end
    p.Anchored = true
end

-- Congelar constantes: erro na hora se alguém tentar escrever
local CONFIG = table.freeze({ velocidade = 16, pulo = 50 })
```

`string.format` continua válido quando você quer controlar casas decimais
(`%.2f`) ou alinhamento. Para concatenar texto com valor, a interpolação com
crase é o idioma.

## Coisas deprecadas que você NÃO deve usar

| Antigo | Atual |
|---|---|
| `BodyVelocity`, `BodyPosition`, `BodyGyro` | `LinearVelocity`, `AlignPosition`, `AlignOrientation` |
| `part.Rotation` para girar | `part.CFrame` com `CFrame.Angles` |
| `game.Workspace` | `game:GetService("Workspace")` (ou o global `workspace`) |
| `Humanoid.MaxHealth` sem checar | ok, mas prefira `Humanoid:TakeDamage()` a mexer em Health |
| `FindFirstChild` em loop apertado | cache a referência fora do loop |
| `:remove()` | `:Destroy()` |
| `Model.PrimaryPart` + `SetPrimaryPartCFrame` | `Model:PivotTo()` / `Model:GetPivot()` |
| `mouse.Hit` para input novo | `UserInputService` / `ContextActionService` |

Quando estiver em dúvida se algo existe ou está deprecado, use `lookup_api` —
ele lê a API de verdade da versão instalada e marca o que é deprecado.

## CFrame na prática

```lua
-- posicionar sem girar
part.CFrame = CFrame.new(0, 10, 0)

-- posicionar E girar (graus -> radianos)
part.CFrame = CFrame.new(0, 10, 0) * CFrame.Angles(0, math.rad(90), 0)

-- olhar para um alvo
part.CFrame = CFrame.lookAt(part.Position, alvo.Position)

-- mover um modelo inteiro (não itere as partes!)
modelo:PivotTo(CFrame.new(0, 10, 0))

-- offset relativo ao próprio objeto: 5 studs "pra frente"
part.CFrame = part.CFrame * CFrame.new(0, 0, -5)
```

Multiplicação de CFrame não é comutativa: `a * b` aplica `b` no espaço local de
`a`. `CFrame.new(pos) * CFrame.Angles(...)` gira em torno do próprio objeto;
inverter a ordem gira em torno da origem do mundo.

## Tween

```lua
local TweenService = game:GetService("TweenService")
local info = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
TweenService:Create(part, info, { Position = Vector3.new(0, 20, 0) }):Play()
```

Tween não funciona em part com `Anchored = false` se a física estiver brigando.
Ancore, ou use constraints.
