# Arquitetura de um jogo Roblox

## A fronteira cliente-servidor é a decisão mais importante

Todo bug de segurança em Roblox nasce de confiar no cliente. O cliente é do
jogador; ele pode mentir sobre qualquer coisa.

- **Servidor** (`Script`, `RunContext = Server`): autoridade. Dinheiro, inventário,
  dano, progressão, validação. Nunca aceite um valor do cliente sem checar.
- **Cliente** (`LocalScript`): input, câmera, UI, efeitos visuais, previsão.
  Tudo aqui é dica, não verdade.

Regra prática: o cliente pede, o servidor decide. Um `RemoteEvent` chamado
`GiveCoins` que o servidor obedece cegamente é um exploit. O certo é o cliente
mandar "tentei pegar a moeda X" e o servidor conferir se a moeda X existe, se o
jogador está perto o bastante e se ela já não foi pega.

## Onde as coisas moram

| Serviço | O que vai aqui | Replica pro cliente? |
|---|---|---|
| `ServerScriptService` | Scripts do servidor | Não |
| `ServerStorage` | Assets/módulos só do servidor | Não |
| `ReplicatedStorage` | Módulos e remotes compartilhados | Sim |
| `StarterPlayer.StarterPlayerScripts` | LocalScripts que rodam uma vez por jogador | Sim |
| `StarterPlayer.StarterCharacterScripts` | Scripts que rodam a cada respawn | Sim |
| `StarterGui` | UI, copiada pro PlayerGui a cada respawn | Sim |
| `Workspace` | O mundo 3D | Sim |
| `Lighting` | Iluminação e atmosfera | Sim |

Se um segredo (tabela de loot, chave de API, lógica anti-cheat) estiver em
`ReplicatedStorage`, o cliente lê. Use `ServerStorage`.

## Comunicação

- `RemoteEvent` — mensagem sem resposta, nos dois sentidos. O padrão.
- `RemoteFunction` — pergunta com resposta. **Evite chamar cliente→servidor
  esperando retorno**: se o cliente não responder, o servidor trava naquela
  thread. Do servidor pro cliente é pior ainda — nunca faça.
- `BindableEvent`/`BindableFunction` — só dentro do mesmo contexto. Não cruza a
  fronteira.

Guarde os remotes numa pasta em `ReplicatedStorage` e crie-os no servidor
(assim o cliente sempre encontra, mas use `WaitForChild`).

```lua
-- servidor
local Remotes = Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = ReplicatedStorage

-- cliente
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
```

Sempre valide o que chega num remote. O primeiro argumento de
`OnServerEvent` é o `Player`, e o Roblox garante esse — todo o resto é suspeito.

```lua
Remote.OnServerEvent:Connect(function(player, amount)
    if typeof(amount) ~= "number" or amount ~= amount or amount < 0 then
        return -- lixo, incluindo NaN
    end
    ...
end)
```

## Estrutura típica de um projeto sério

```
ReplicatedStorage/
  Remotes/           RemoteEvents e RemoteFunctions
  Shared/            módulos usados pelos dois lados (config, tipos, util)
ServerScriptService/
  Main.luau          um Script que inicializa os sistemas, em ordem
  Systems/           ModuleScripts: um por sistema (Combat, Economy, Data)
ServerStorage/
  Assets/            modelos que o servidor clona
StarterPlayer/
  StarterPlayerScripts/
    Client.luau      um LocalScript que inicializa os controllers
    Controllers/     ModuleScripts do cliente
```

**Um único ponto de entrada por contexto.** Vinte Scripts soltos em
`ServerScriptService` rodam em ordem indefinida e viram um pesadelo de
dependência. Um `Main` que dá `require` nos sistemas na ordem certa é
determinístico e fácil de ler.

## Persistência (DataStore)

`DataStoreService` só funciona no servidor, e não funciona em Studio a menos que
"Enable Studio Access to API Services" esteja ligado nas configurações do jogo.

Erros de DataStore são normais, não excepcionais — a rede falha. Sempre
`pcall`, sempre com retry:

```lua
local function saveWithRetry(key, value, tries)
    tries = tries or 3
    for attempt = 1, tries do
        local ok, err = pcall(store.SetAsync, store, key, value)
        if ok then return true end
        if attempt == tries then
            warn(("Falha ao salvar %s: %s"):format(key, tostring(err)))
            return false, err
        end
        task.wait(2 ^ attempt) -- backoff
    end
end
```

Use `UpdateAsync` (não `SetAsync`) quando o novo valor depende do antigo — é
atômico e resolve corrida entre servidores.

Salve em `PlayerRemoving` **e** em `game:BindToClose()`, senão o último jogador
a sair num shutdown perde o progresso.

## Performance

- `Workspace:GetDescendants()` num mapa grande é caro. Prefira
  `CollectionService:GetTagged("Moeda")`.
- Um `RunService.Heartbeat` por sistema, não um por objeto. Itere a lista dentro
  de um loop só.
- `Instance.new("Part", parent)` (com o pai no construtor) é mais lento que
  setar `.Parent` por último. E setar `.Parent` por último evita replicação
  parcial: monte o objeto inteiro, depois pendure na árvore.
- Não faça `while true do task.wait() end` para coisas que podem ser eventos.
