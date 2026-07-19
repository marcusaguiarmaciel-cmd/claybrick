# Luau avançado

> Quando for escrever classe/OOP, tipo genérico, módulo que outros módulos usam, ou quando precisar espremer desempenho de código Luau.

O básico (tipos, `task`, conexões, iteração, deprecados) está sempre no seu
contexto. Aqui está o que vem depois: o que permite escrever um módulo que outra
pessoa usa sem se machucar.

## Classe com metatable

O padrão consagrado, com os tipos que fazem o autocomplete e o `check_syntax`
trabalharem a seu favor:

```lua
--!strict
local Inimigo = {}
Inimigo.__index = Inimigo

export type Inimigo = typeof(setmetatable(
    {} :: {
        vida: number,
        maxVida: number,
        modelo: Model,
    },
    Inimigo
))

function Inimigo.new(modelo: Model, vida: number): Inimigo
    return setmetatable({
        vida = vida,
        maxVida = vida,
        modelo = modelo,
    }, Inimigo)
end

function Inimigo.levarDano(self: Inimigo, quanto: number): boolean
    self.vida = math.max(0, self.vida - quanto)
    return self.vida == 0
end

return Inimigo
```

`export type` é o que permite outro módulo escrever `local e: Inimigo.Inimigo`.
Sem isso, o tipo morre dentro do arquivo.

Declarar com `function Inimigo.levarDano(self: Inimigo, ...)` em vez de
`Inimigo:levarDano(...)` é o que dá ao analisador o tipo do `self`. Quem chama
continua usando `inimigo:levarDano(10)` normalmente.

## Genéricos

```lua
local function primeiro<T>(lista: {T}): T?
    return lista[1]
end

local function mapear<T, U>(lista: {T}, f: (T) -> U): {U}
    local saida = table.create(#lista)   -- pré-aloca: evita realocar crescendo
    for i, v in lista do
        saida[i] = f(v)
    end
    return saida
end
```

`table.create(n)` e `table.create(n, valor)` importam em lista grande: sem
pré-alocar, a tabela é realocada várias vezes enquanto cresce.

## Tipos que evitam bug de verdade

**União marcada** obriga a tratar cada caso, e o analisador cobra:

```lua
type Resultado<T> =
    { ok: true, valor: T }
    | { ok: false, erro: string }

local function pegar(id: number): Resultado<string>
    if id <= 0 then
        return { ok = false, erro = "id inválido" }
    end
    return { ok = true, valor = "item" .. id }
end

local r = pegar(5)
if r.ok then
    print(r.valor)     -- aqui o analisador SABE que valor existe
else
    warn(r.erro)
end
```

Isso é bem melhor que devolver `nil` e deixar quem chama adivinhar o motivo.

Outros que valem o hábito:

```lua
type Somente = { read nome: string }        -- campo só de leitura
local x = y :: Tipo                          -- cast, quando você sabe mais que o analisador
local n = assert(tonumber(s), "não é número")  -- estreita o tipo e falha alto
```

Evite `any`. Ele desliga a verificação de tudo que encosta nele, e o
`check_syntax` para de te ajudar exatamente onde você mais precisava.

## Congelar o que é constante

```lua
local CONFIG = table.freeze({
    VELOCIDADE = 16,
    DANO = 10,
})
```

Tabela congelada lança erro se alguém tentar escrever nela. Configuração
compartilhada entre módulos deveria ser congelada por padrão: descobrir na hora
que alguém mutou a config global é bem melhor do que caçar isso depois.

`table.clone` faz cópia rasa (e desfaz o congelamento na cópia). Para cópia
profunda, escreva a recursão: não existe pronta.

## Multiplos retornos, e onde eles somem

```lua
local function dois(): (number, number)
    return 1, 2
end

local t = {dois()}          -- {1, 2}
local t2 = {dois(), 9}      -- {1, 9}  <- só o PRIMEIRO sobrevive!
print(select("#", dois()))  -- 2
```

Chamada que não está na última posição é truncada para um valor. Essa é a causa
de bug silencioso em `table.insert(t, f())` quando `f` devolve dois valores.

Variádicos:

```lua
local function log(formato: string, ...: any)
    local args = table.pack(...)
    for i = 1, args.n do ... end    -- args.n, não #args: aguenta nil no meio
end
```

## Desempenho de Luau

Em ordem de impacto real:

- **`local` vence global.** Acesso a global passa por tabela; local é registrador.
  `local abs = math.abs` antes de um laço apertado é ganho de verdade.
- **`--!native`** no topo compila a função para código nativo. Vale em código
  numérico pesado (geração de terreno, física própria); não vale em código que
  só chama API do Roblox.
- **`--!optimize 2`** liga otimização agressiva no arquivo.
- **Evite criar tabela dentro de laço por quadro.** Cada uma é lixo para o
  coletor. Reaproveite uma tabela e limpe.
- `table.concat` para juntar muitas strings; `..` em laço cria uma string nova a
  cada volta.
- `string.format` é mais legível e costuma ser melhor que concatenação em cadeia.

Meça antes de acreditar. `os.clock()` em volta do trecho, com `run_code`, resolve
a dúvida em trinta segundos, e o número é bem mais convincente que a intuição.

## Corrotinas, além do task

`task.spawn` cobre quase tudo. Corrotina crua serve quando você precisa
**pausar e retomar** de fora, tipo uma sequência de cutscene ou um iterador:

```lua
local co = coroutine.create(function()
    for i = 1, 3 do
        coroutine.yield(i)
    end
end)
print(select(2, coroutine.resume(co)))   -- 1
```

Erro dentro de corrotina não sobe para quem criou: `coroutine.resume` devolve
`false, mensagem` e o erro morre ali se você não olhar. `task.spawn` propaga o
erro para o Output, que é quase sempre o que você quer.

## Módulo: contrato antes de conveniência

- `require` **guarda o resultado**: o módulo roda uma vez por lado, e todos os
  scripts recebem a mesma tabela. Estado dentro de módulo é estado global
  compartilhado.
- Um módulo não deve rodar efeito colateral pesado no corpo. Exponha `iniciar()`.
- Devolva uma tabela com funções nomeadas, não uma função solta, quando houver
  chance de crescer.
- Ciclo de `require` entre dois módulos trava. Se A precisa de B e B precisa de
  A, o desenho está errado: extraia o que os dois usam para um terceiro.

## Antes de entregar

- [ ] `--!strict` no topo e `check_syntax` rodado
- [ ] Nada de `any` onde dava para tipar
- [ ] Classe com `export type` e `self` tipado
- [ ] Configuração compartilhada congelada
- [ ] Nenhuma chamada de múltiplos retornos truncada por engano
- [ ] Nenhum `require` circular
- [ ] Otimização feita com medida, não com achismo
