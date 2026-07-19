# DataStores: perder save é o bug que não se perdoa

> Quando for salvar ou carregar qualquer progresso de jogador: moedas, inventário, nível, configurações, estatísticas.

Um bug de gameplay irrita. Um save perdido faz o jogador desinstalar e não
voltar. E o pior tipo de perda não é o servidor cair: é o seu código sobrescrever
dado bom com dado vazio, silenciosamente, e ninguém perceber por uma semana.

Duas verdades que mudam como você escreve isso:

1. **Toda chamada de DataStore é rede, e rede falha.** Sem `pcall`, um erro
   momentâneo vira exceção no meio do seu fluxo.
2. **Falha ao carregar não é dado vazio.** É "não sei". Tratar as duas coisas
   igual é exatamente como se apaga o save de alguém.

## O esqueleto que funciona

```lua
--!strict
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local loja = DataStoreService:GetDataStore("Jogadores_v1")

type Perfil = { moedas: number, nivel: number, itens: {[string]: boolean} }

local PADRAO: Perfil = { moedas = 0, nivel = 1, itens = {} }
local perfis: {[Player]: Perfil} = {}
-- Quem falhou ao CARREGAR nunca pode salvar por cima do que está no servidor.
local podeSalvar: {[Player]: boolean} = {}

local function tentar<T>(fn: () -> T, tentativas: number): (boolean, T?)
    for i = 1, tentativas do
        local ok, res = pcall(fn)
        if ok then return true, res end
        -- Backoff: repetir na mesma hora só gasta o orçamento contra a mesma
        -- indisponibilidade que acabou de derrubar a chamada.
        task.wait(2 ^ i)
    end
    return false, nil
end

local function carregar(jogador: Player)
    local chave = "u_" .. jogador.UserId
    local ok, dados = tentar(function()
        return loja:GetAsync(chave)
    end, 3)

    if not ok then
        -- NÃO cai no padrão. Dado bom pode existir lá; sobrescrever é que mata.
        podeSalvar[jogador] = false
        perfis[jogador] = table.clone(PADRAO)
        warn(("não carreguei %s; sessão em modo somente leitura"):format(jogador.Name))
        -- avise o jogador na UI: melhor ele sair do que jogar 1h e perder
        return
    end

    perfis[jogador] = (dados :: Perfil?) or table.clone(PADRAO)
    podeSalvar[jogador] = true
end

local function salvar(jogador: Player)
    local perfil = perfis[jogador]
    if not perfil or not podeSalvar[jogador] then return end

    local chave = "u_" .. jogador.UserId
    tentar(function()
        -- UpdateAsync, não SetAsync: ele lê e escreve numa operação só, então
        -- dois servidores mexendo no mesmo jogador não apagam um ao outro.
        return loja:UpdateAsync(chave, function(antigo)
            return perfil
        end)
    end, 3)
end
```

## SetAsync ou UpdateAsync

`UpdateAsync` quase sempre. Ele recebe o valor atual e devolve o novo, de forma
atômica: se outro servidor gravou entre a sua leitura e a sua escrita, sua função
roda de novo com o valor atualizado.

`SetAsync` é escrita cega. Use apenas quando o novo valor não depende em nada do
antigo. O caso clássico de perda é: servidor A lê 100 moedas, servidor B lê 100,
A grava 150, B grava 120 — as 50 de A evaporaram. `UpdateAsync` resolve isso.

Para somar, existe `IncrementAsync` (só inteiro).

## Quando salvar

- **`PlayerRemoving`**: o principal.
- **Periodicamente** (a cada 2–5 min): se o servidor morrer de vez,
  `PlayerRemoving` pode não rodar.
- **`game:BindToClose`**: shutdown e restart de servidor. Você tem ~30 segundos.

```lua
game:BindToClose(function()
    -- Serial com 30 jogadores estoura o tempo. Uma thread por jogador, e
    -- espera todas: o processo não pode morrer antes de o último gravar.
    local pendentes = 0
    for _, jogador in Players:GetPlayers() do
        pendentes += 1
        task.spawn(function()
            salvar(jogador)
            pendentes -= 1
        end)
    end
    while pendentes > 0 do task.wait() end
end)
```

Não salve a cada moeda ganha. Isso queima o orçamento de requisições e não
melhora nada: salve em intervalo e nos eventos de saída.

## Orçamento de requisições

O Roblox limita as chamadas por minuto (grosso modo, uma base fixa mais uma
parcela por jogador no servidor). Estourar não dá erro bonito: as chamadas
entram numa fila e começam a demorar muito.

Não decore os números; **pergunte**:

```lua
local Enum_ = Enum.DataStoreRequestType
if DataStoreService:GetRequestBudgetForRequestType(Enum_.UpdateAsync) < 1 then
    task.wait(1)   -- espere em vez de enfileirar
end
```

## Duplicação entre servidores (session locking)

O jogador entra no servidor A, e por lag de saída entra no B antes de A gravar.
Os dois têm perfil na memória, os dois gravam, e o jogador duplica item ou perde
progresso. A solução é marcar na própria chave qual `JobId` está com a sessão
aberta, e o servidor novo esperar a liberação antes de assumir.

Isso é chato de acertar à mão. Para jogo de verdade, a comunidade converge em
**ProfileStore / ProfileService**, que já resolve session locking, retry e
reconciliação de dados. Se o usuário está construindo algo sério com economia,
vale recomendar em vez de reimplementar mal.

## O que NÃO vai para o DataStore

- **Instâncias.** `Part`, `Model`, `Color3`, `Vector3`, `CFrame` não serializam.
  Converta para número e tabela: `{x = v.X, y = v.Y, z = v.Z}`.
- **Tabela com chave mista ou função.** Só array puro ou dicionário com chave
  string/número.
- **Blocos gigantes.** Existe teto por chave (na casa dos MB). Mundo inteiro do
  jogador salvo numa chave só é sinal de que precisa de várias chaves.
- **`nil` no meio de array.** Vira buraco e o comprimento fica imprevisível.

## Versione desde o primeiro dia

Chame de `"Jogadores_v1"` e guarde um campo de versão dentro do perfil. Quando
mudar o formato daqui a três meses, você vai precisar migrar em vez de quebrar:

```lua
local function migrar(perfil)
    if perfil.versao == nil then
        perfil.itens = perfil.itens or {}
        perfil.versao = 1
    end
    return perfil
end
```

## No Studio isso não roda por padrão

DataStore só funciona em Studio com **Game Settings → Security → Enable Studio
Access to API Services** ligado, e num place já publicado. Se o teste falhar com
"403" ou "cannot be accessed from Studio", é isso, e o usuário precisa ligar na
mão: você não tem como.

Em `run_code` (edit mode), teste a lógica de perfil com uma tabela falsa no lugar
da loja. A parte que vale testar de verdade é a sua, não a da Roblox.

## Antes de entregar

- [ ] Todo acesso está dentro de `pcall`, com retry
- [ ] Falha de carregamento bloqueia a gravação daquela sessão
- [ ] `UpdateAsync` onde o novo valor depende do antigo
- [ ] Salva em `PlayerRemoving`, em intervalo e em `BindToClose`
- [ ] `BindToClose` espera as gravações terminarem
- [ ] Nada de Instance, Vector3 ou CFrame cru no que é salvo
- [ ] A chave tem versão no nome
