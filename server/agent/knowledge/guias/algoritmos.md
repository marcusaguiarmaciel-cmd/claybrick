# Algoritmos, no tamanho que um jogo Roblox pede

> Quando precisar achar o mais próximo, gerar mapa, ordenar ranking, espalhar trabalho pesado no tempo, ou quando algo ficar lento com muitos objetos.

Aqui não se trata de decorar estrutura de dados. Trata-se de reconhecer os três
ou quatro padrões que aparecem em jogo de verdade, e de saber a hora em que
"funciona com 10" vira "trava com 100".

A conta que importa: **o que é O(n²) morre**. Quarenta jogadores comparados dois
a dois são 1600 comparações por quadro. Cem projéteis contra cem inimigos são
10 mil. É esse o formato de quase toda queda de FPS causada por script.

## Escolher a estrutura certa

```lua
-- Array: ordem importa, você percorre tudo. #t funciona.
local fila = {"a", "b", "c"}

-- Dicionário: você BUSCA por chave. Achar é imediato, não percorre.
local porId = {[123] = jogadorA, [456] = jogadorB}
```

O erro mais comum é usar array onde a pergunta é "esse aqui está na lista?":

```lua
-- ERRADO: percorre a lista inteira a cada checagem
for _, id in banidos do
    if id == alvo then ... end
end

-- CERTO: uma consulta, custo constante
local banidos = {[123] = true, [456] = true}
if banidos[alvo] then ... end
```

Sempre que se pegar escrevendo um `for` só para descobrir se algo existe, o certo
era um dicionário. `table.find` tem o mesmo problema em laço apertado.

**Remover do meio de um array** custa: `table.remove(t, i)` desloca todo o resto.
Numa lista grande onde a ordem não importa, troque pelo último e corte o fim:

```lua
t[i] = t[#t]
t[#t] = nil
```

## Achar o mais próximo sem comparar todo mundo

A versão ingênua percorre todos os alvos por NPC. Com 50 NPCs e 50 alvos são
2500 comparações por volta.

Para muitos objetos, divida o mundo em células e só olhe as células vizinhas:

```lua
local CELULA = 50

local function chave(pos: Vector3): string
    return math.floor(pos.X / CELULA) .. "_" .. math.floor(pos.Z / CELULA)
end

local grade: {[string]: {BasePart}} = {}

local function inserir(p: BasePart)
    local k = chave(p.Position)
    grade[k] = grade[k] or {}
    table.insert(grade[k], p)
end

-- Buscar olha só as 9 células ao redor, não o mapa inteiro
local function perto(pos: Vector3): {BasePart}
    local achados = {}
    local cx, cz = math.floor(pos.X / CELULA), math.floor(pos.Z / CELULA)
    for dx = -1, 1 do
        for dz = -1, 1 do
            for _, p in grade[(cx + dx) .. "_" .. (cz + dz)] or {} do
                table.insert(achados, p)
            end
        end
    end
    return achados
end
```

Antes de escrever isso, considere a saída pronta: `workspace:GetPartBoundsInRadius`
já faz consulta espacial no motor, que é mais rápido que qualquer grade em Luau.
A grade vale quando o que você guarda não são peças, ou quando precisa de dados
próprios junto.

## Espalhar trabalho pesado no tempo

Gerar 5000 peças num quadro trava o Studio e o jogo. A solução não é otimizar o
laço: é **fatiar**.

```lua
local function gerarEmFatias(total: number, porQuadro: number, fazer: (number) -> ())
    local i = 0
    while i < total do
        local fim = math.min(i + porQuadro, total)
        for j = i + 1, fim do
            fazer(j)
        end
        i = fim
        task.wait()   -- devolve o quadro; o jogo continua respondendo
    end
end
```

Esse padrão vale para geração de mapa, carregamento de inventário grande e
qualquer laço que passe de alguns milissegundos. Em `run_code` ele é ainda mais
importante: laço sem `task.wait` **trava o Studio do usuário**.

## Ordenar ranking

```lua
table.sort(lista, function(a, b)
    return a.pontos > b.pontos   -- decrescente
end)
```

Dois cuidados que geram bug de verdade:

- A função **precisa ser uma ordem estrita**. Devolver `>=` faz `table.sort`
  lançar "invalid order function"; e empates com critério inconsistente também.
  Para empate, desempate por algo único: `if a.pontos == b.pontos then return a.id < b.id end`.
- Não ordene a cada quadro. Ranking é lento e ninguém percebe se atualiza a cada
  segundo.

Para "os 10 maiores" de uma lista enorme, ordenar tudo é desperdício: uma
passada guardando os 10 melhores resolve.

## Busca em grade: labirinto, cômodos, inundação

BFS (fila) acha o caminho mais curto em grade e é a base de gerar labirinto,
achar região conectada e "quais blocos estão presos".

```lua
local function bfs(inicio: Vector2, passavel: (Vector2) -> boolean)
    local fila = {inicio}
    local visto = {[inicio.X .. "_" .. inicio.Y] = true}
    local i = 1
    while i <= #fila do              -- índice em vez de table.remove(fila, 1)
        local atual = fila[i]; i += 1
        for _, d in {Vector2.new(1,0), Vector2.new(-1,0), Vector2.new(0,1), Vector2.new(0,-1)} do
            local viz = atual + d
            local k = viz.X .. "_" .. viz.Y
            if not visto[k] and passavel(viz) then
                visto[k] = true
                table.insert(fila, viz)
            end
        end
    end
    return visto
end
```

Repare no `i` avançando em vez de `table.remove(fila, 1)`: remover do começo
desloca o array inteiro toda vez, e transforma um BFS linear em quadrático.

**Não escreva A\* para NPC andar no mundo.** O `PathfindingService` já faz isso,
com a geometria real. Busca própria é para grade lógica sua: tabuleiro,
inventário, mapa de tiles.

## Geração procedural

`math.noise` é ruído Perlin, e é o que dá terreno com cara de terreno em vez de
aleatório picado:

```lua
local altura = math.noise(x / 40, z / 40, semente) * 30
```

Dividir a entrada controla a escala (número maior = relevo mais suave). Somar
duas ou três oitavas com escalas diferentes dá detalhe.

Use semente fixa (`Random.new(semente)`) sempre que o mapa precisar ser
reproduzível: sem isso, um bug de geração é impossível de investigar.

## Guardar resultado caro

Se a mesma conta se repete com a mesma entrada, guarde:

```lua
local cache = {}
local function caro(chave)
    if cache[chave] == nil then
        cache[chave] = calcular(chave)
    end
    return cache[chave]
end
```

Serve para caminho calculado, resultado de raycast do mesmo quadro, dado de
configuração derivado. Cuidado com cache que cresce sem parar: se a chave for
posição do jogador, você criou um vazamento.

## Antes de entregar

- [ ] Nenhuma busca linear onde cabia dicionário
- [ ] Nada de O(n²) sobre listas que crescem com o número de jogadores
- [ ] Laço pesado fatiado com `task.wait`
- [ ] Nenhum `table.remove(t, 1)` dentro de laço
- [ ] Comparador de `table.sort` com ordem estrita e desempate
- [ ] Geração com semente, quando precisa ser reproduzível
- [ ] Cache com limite, se a chave for aberta
