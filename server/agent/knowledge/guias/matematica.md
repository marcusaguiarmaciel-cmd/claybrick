# Matemática que aparece todo dia no Roblox

> Quando precisar de ângulo, distância, direção, suavização, órbita, mira, curva, ou aleatoriedade que não repete feio.

Não é matemática difícil. É um punhado de ferramentas que resolvem oitenta por
cento dos problemas de geometria de jogo, e que, quando faltam, viram vinte
linhas de `if` tentando adivinhar o que um produto escalar responde numa linha.

## Vector3: as quatro operações que importam

```lua
local distancia     = (a - b).Magnitude   -- distância entre dois pontos
local direcao       = (alvo - eu).Unit    -- de mim até o alvo, comprimento 1
local alinhamento   = a:Dot(b)            -- o quanto apontam para o mesmo lado
local perpendicular = a:Cross(b)          -- vetor perpendicular aos dois
```

**`Magnitude` tem raiz quadrada dentro.** Comparando distâncias em laço apertado,
compare o quadrado e evite a raiz:

```lua
local d = alvo.Position - eu.Position
-- mesmo resultado que d.Magnitude < alcance, sem pagar a raiz quadrada
if d:Dot(d) < alcance * alcance then
    perseguir(alvo)
end
```

## Dot: "está na minha frente?" e "qual o ângulo?"

Com os dois vetores normalizados, o produto escalar é o cosseno do ângulo entre
eles: `1` mesma direção, `0` perpendicular, `-1` oposto.

```lua
local paraAlvo = (alvo.Position - npc.Position).Unit
local frente = npc.CFrame.LookVector

if frente:Dot(paraAlvo) > 0.5 then       -- 0.5 = cos(60°): cone de 120°
    -- está no campo de visão
end

local angulo = math.deg(math.acos(math.clamp(frente:Dot(paraAlvo), -1, 1)))
```

O `math.clamp` não é frescura: erro de ponto flutuante devolve `1.0000001`, e
`math.acos` disso é `nan`, que contamina tudo em silêncio.

**`Cross` responde "esquerda ou direita"**: o sinal de
`frente:Cross(paraAlvo).Y` diz para que lado o NPC precisa virar.

## CFrame: posição e rotação juntas

```lua
CFrame.new(pos)                          -- só posição
CFrame.lookAt(pos, alvo)                 -- em pos, olhando para alvo
CFrame.Angles(0, math.rad(90), 0)        -- rotação, em RADIANOS
```

`CFrame.Angles` recebe radianos. Passar `90` em vez de `math.rad(90)` é o erro
mais comum de todos, e não dá erro nenhum: só gira quase 5157 graus.

**A ordem da multiplicação muda tudo:**

```lua
local noLocal = base * deslocamento   -- desloca no espaço LOCAL da base (frente dela)
local noMundo = deslocamento * base   -- desloca no espaço do MUNDO
```

Para "3 studs à frente do jogador", é `raiz.CFrame * CFrame.new(0, 0, -3)`. E é
`-3` porque **a frente é o -Z**; isso e o resto de orientação estão em
`lookup_guide("orientacao")`.

Vetores úteis de um CFrame: `LookVector` (frente), `RightVector`, `UpVector`.
`cf.Position` tira só a posição.

Converter entre espaços:

```lua
local local_ = base:ToObjectSpace(mundo)   -- "onde isso está, na visão da base"
local mundo_ = base:ToWorldSpace(local_)
local ponto = base:PointToWorldSpace(Vector3.new(0, 5, 0))
```

## Interpolar, e o bug que quase todo mundo escreve

`a:Lerp(b, alpha)` funciona em `Vector3`, `CFrame` e `Color3`. Com `alpha` de 0 a 1.

O erro clássico é suavizar com alpha constante por quadro:

```lua
-- ERRADO: depende do FPS. A 120 quadros aproxima o DOBRO de rápido que a 60.
RunService.Heartbeat:Connect(function()
    camera.CFrame = camera.CFrame:Lerp(alvo, 0.1)
end)

-- CERTO: mesma velocidade real em qualquer FPS.
RunService.Heartbeat:Connect(function(dt)
    local alpha = 1 - math.exp(-8 * dt)   -- 8 = o quão "duro" é o acompanhamento
    camera.CFrame = camera.CFrame:Lerp(alvo, alpha)
end)
```

Esse `1 - math.exp(-k * dt)` é a linha mais útil deste guia. Serve para câmera,
mira, barra de vida, qualquer coisa que "persegue" um valor.

## Curvas prontas

Não escreva sua função de easing: o `TweenService` expõe a dele para qualquer
número.

```lua
local t = TweenService:GetValue(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
```

Para trajetória curva (granada, salto, câmera passeando), Bézier quadrática de
três pontos resolve quase sempre:

```lua
local function bezier(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
    return (1 - t) ^ 2 * p0 + 2 * (1 - t) * t * p1 + t ^ 2 * p2
end
```

O ponto do meio (`p1`) puxa a curva; para um arco, use o meio do caminho com Y
mais alto.

## Círculo, órbita e distribuição

```lua
-- n objetos igualmente espaçados num círculo
for i = 1, n do
    local ang = (i / n) * math.pi * 2
    local pos = centro + Vector3.new(math.cos(ang) * raio, 0, math.sin(ang) * raio)
end
```

Ponto aleatório dentro de um círculo: usar `math.random() * raio` **concentra
tudo no meio**. A correção é a raiz:

```lua
local r = raio * math.sqrt(math.random())
```

## Aleatoriedade

Prefira `Random.new()` a `math.random`: é um gerador próprio, não compartilha
estado com o resto do jogo, e aceita semente.

```lua
local rng = Random.new()
local rng2 = Random.new(12345)   -- semente fixa: mesmo mapa toda vez
rng:NextNumber(0.8, 1.2)
rng:NextInteger(1, 6)
```

Semente fixa é o que permite mapa procedural reproduzível, e é o que torna um
bug de geração possível de investigar.

Sorteio com pesos, para loot:

```lua
local function sortear(itens: {{nome: string, peso: number}}, rng: Random)
    local total = 0
    for _, it in itens do total += it.peso end
    local corte = rng:NextNumber() * total
    for _, it in itens do
        corte -= it.peso
        if corte <= 0 then return it.nome end
    end
    return itens[#itens].nome   -- borda do ponto flutuante
end
```

## Utilitários que evitam gambiarra

```lua
local preso    = math.clamp(v, min, max)  -- prenda em faixa, sempre que houver limite
local sinal    = math.sign(v)             -- -1, 0 ou 1
local redondo  = math.round(v)            -- e math.floor / math.ceil
local resto    = math.fmod(a, b)          -- ângulo dando volta
local maisPerto = math.huge               -- valor inicial de "menor distância"
```

`math.clamp` em volta de vida, munição e volume elimina uma classe inteira de
bug.

## Antes de entregar

- [ ] Nada de `CFrame.Angles` com graus
- [ ] `math.acos` sempre com `clamp` antes
- [ ] Suavização por quadro usa `dt`, não alpha fixo
- [ ] Comparação de distância em laço usa o quadrado
- [ ] `Random.new` no lugar de `math.random` onde a semente importa
- [ ] Valores com limite passam por `math.clamp`
