# Segurança: o cliente é do jogador

> Quando algo passar do cliente para o servidor, quando houver dinheiro, item, dano ou progressão em jogo, ou quando você criar qualquer RemoteEvent.

Existe uma pessoa, agora, com um executor aberto no seu jogo. Ela lê todo
LocalScript, vê tudo que está em ReplicatedStorage, chama qualquer RemoteEvent
com qualquer argumento e roda qualquer função do cliente. Isso não é um cenário
extremo: é o normal de qualquer jogo com jogadores.

A pergunta certa nunca é "como impedir que ele mexa no cliente". Não dá. É:
**"o que ele consegue fazer de pior, e por que o servidor deixaria?"**

## A regra única

O cliente **pede**. O servidor **decide**. Não existe exceção para "só um
cliquezinho", "é só cosmético" ou "ninguém ia tentar isso".

```lua
-- ERRADO: o cliente diz quanto ganhou.
comprar.OnServerEvent:Connect(function(jogador, item, preco)
    dados[jogador].moedas -= preco       -- preco veio do cliente. Pode ser -9999.
    darItem(jogador, item)
end)

-- CERTO: o cliente diz o QUE quer; o servidor busca o preço e valida tudo.
comprar.OnServerEvent:Connect(function(jogador, itemId)
    if type(itemId) ~= "string" then return end   -- 1. tipo
    local item = CATALOGO[itemId]
    if not item then return end                   -- 2. existe mesmo?
    local perfil = perfis[jogador]
    if not perfil then return end
    if perfil.moedas < item.preco then return end -- 3. pode pagar?
    if perfil.itens[itemId] then return end       -- 4. já tem?

    perfil.moedas -= item.preco
    perfil.itens[itemId] = true
    darItem(jogador, item)
end)
```

Repare que o servidor nunca recebeu um número. Recebeu um identificador, e
descobriu o resto sozinho. **Sempre que um valor numérico atravessa a fronteira,
pergunte quem calculou.**

## Todo handler de remote começa igual

O primeiro argumento de `OnServerEvent` é o `Player`, e esse o Roblox garante.
Todos os outros são invenção livre do cliente.

1. **Tipo.** `type(x) ~= "number"` antes de comparar. Sem isso, mandar uma tabela
   onde você espera número derruba o handler, e às vezes com ele o script.
2. **Faixa.** Número existe em NaN, infinito e negativo. `x ~= x` detecta NaN.
3. **Posse.** O jogador realmente tem esse item, essa arma, esse pet?
4. **Distância.** Está perto o bastante da porta/loja/baú para interagir? Compare
   com `HumanoidRootPart.Position` no servidor, nunca com posição enviada.
5. **Cooldown.** No servidor. Debounce em LocalScript não existe para quem usa
   executor.
6. **Estado.** Está vivo? Já não comprou? A partida ainda está rolando?

```lua
local ultimoUso: {[Player]: number} = {}

local function podeUsar(jogador: Player, intervalo: number): boolean
    local agora = os.clock()
    if ultimoUso[jogador] and agora - ultimoUso[jogador] < intervalo then
        return false
    end
    ultimoUso[jogador] = agora
    return true
end

Players.PlayerRemoving:Connect(function(p) ultimoUso[p] = nil end)  -- não vaze
```

## Onde as coisas moram

| Serviço | Cliente vê? | O que pode ir |
|---|---|---|
| `ServerScriptService` | não | lógica de verdade, validação, catálogo de preços |
| `ServerStorage` | não | assets que o cliente não deve conhecer antes da hora |
| `ReplicatedStorage` | **sim** | módulos compartilhados, remotes, dados públicos |
| `StarterGui` / `StarterPlayer` | **sim** | UI e input |

"O cliente vê" inclui **ler o código-fonte dos ModuleScripts**. Um módulo de
preços em ReplicatedStorage não é vazamento grave; um módulo com a lógica de
"como validar" é um mapa do que burlar. Regra prática: se ler aquilo ajuda a
trapacear, é ServerScriptService.

## As armadilhas que mais aparecem

**RemoteFunction do servidor para o cliente.** `remote:InvokeClient(jogador)`
espera o cliente responder. Um cliente hostil simplesmente nunca responde, e a
sua thread do servidor fica pendurada para sempre. Use `RemoteEvent` nos dois
sentidos quando a resposta vier do cliente. `InvokeServer` (cliente chamando o
servidor) é seguro nesse aspecto.

**Backdoor em modelo grátis.** Um `require(123456789)` ou um `getfenv` escondido
num modelo da toolbox dá acesso ao seu servidor. Se você inserir asset com
`insert_asset`, **procure scripts dentro dele** antes de aceitar:
`find_instances` com `class_name = "Script"` no que acabou de inserir. Modelo com
script que você não leu não entra no place.

**Dano calculado no cliente.** O cliente manda "acertei fulano por 40". Ele vai
mandar 9999. O servidor precisa, no mínimo, validar arma equipada, cooldown de
ataque, distância entre os dois e se o alvo está vivo. Hit detection totalmente
no servidor é caro; hit detection *sem nenhuma* validação é jogo morto em uma
semana. O meio termo honesto: cliente reporta o alvo, servidor confere se aquilo
era fisicamente possível.

**Confiar em atributo ou Value dentro do Workspace.** O cliente enxerga e, se o
objeto pertence a ele em rede, às vezes altera. Estado que decide algo vive numa
tabela no servidor, não pendurado numa peça.

**Vazar dado de outro jogador.** `FireAllClients` com a mão de cartas de todo
mundo entrega o jogo inteiro para quem lê o tráfego. Mande a cada cliente só o
que ele pode saber.

## Sobre "anti-cheat"

Detecção no cliente serve para *conveniência*, nunca para *decisão*. Um
LocalScript que detecta speed hack pode ser desligado pelo próprio hacker.

Não banir a partir de detecção de cliente. O caminho é: validar no servidor
(o servidor simplesmente recusa o movimento impossível) e, se quiser telemetria,
registrar o evento suspeito e olhar padrão depois. Falso positivo banindo jogador
legítimo custa mais que o trapaceiro que você pegou.

Movimento é o caso clássico: em vez de detectar velocidade no cliente, o servidor
compara a distância percorrida entre dois instantes com o máximo plausível e
descarta o excedente (ou puxa o jogador de volta).

## Antes de entregar qualquer coisa com remote

- [ ] Todo argumento tem checagem de tipo
- [ ] Todo valor numérico foi calculado pelo servidor, não recebido
- [ ] Existe cooldown no servidor
- [ ] O jogador tem mesmo aquele item / está perto o bastante / está vivo
- [ ] Nenhuma lógica de validação mora em ReplicatedStorage
- [ ] Conexões e tabelas por jogador são limpas em `PlayerRemoving`
