# Networking: o que atravessa a rede, e a que custo

> Quando criar RemoteEvent/RemoteFunction, sincronizar estado entre servidor e clientes, mexer com física de objeto que o jogador controla, ou notar lag/atraso.

Rede no Roblox tem duas contas: **quantas vezes** você manda e **quanto** manda
cada vez. A segunda quase sempre importa menos que a primeira. Vinte remotes por
segundo com um número cada machucam mais que um remote por segundo com uma tabela
de vinte números.

## Qual objeto usar

| Objeto | Direção | Espera resposta | Quando |
|---|---|---|---|
| `RemoteEvent` | os dois lados | não | o padrão, 90% dos casos |
| `UnreliableRemoteEvent` | os dois lados | não | posição/efeito por frame, onde perder pacote não importa |
| `RemoteFunction` | cliente → servidor | sim | quando o cliente precisa da resposta para seguir |
| `BindableEvent/Function` | dentro do mesmo lado | — | script↔script, **nunca** cruza a rede |

**`RemoteFunction:InvokeClient` é uma armadilha.** O servidor fica esperando uma
resposta que um cliente hostil (ou só desconectando) nunca manda, e a thread
trava. Servidor pedindo algo ao cliente: mande um `RemoteEvent` e receba a
resposta em outro `RemoteEvent`.

`UnreliableRemoteEvent` não garante entrega nem ordem, e tem limite de tamanho
menor. É exatamente o certo para "onde está a mira dele agora": se um pacote se
perde, o próximo já corrige. Para "ele comprou um item", jamais.

## O que replica sozinho (e o que não)

Isto economiza muito remote desnecessário:

- Propriedade de instância alterada **no servidor** replica para todos os
  clientes automaticamente. Mudou `part.Color` no servidor? Todo mundo vê. Não
  precisa de remote.
- Instância criada no servidor dentro de `Workspace`/`ReplicatedStorage`
  aparece em todos os clientes.
- **Mudança feita no cliente não sobe.** LocalScript movendo uma peça move só na
  tela dele. Isso não é bug, é o modelo de segurança.
- `Attributes` replicam do servidor para os clientes, e dão um jeito limpo de
  publicar estado sem inventar remote.
- Exceção importante: física de objeto com **network ownership** do jogador sobe
  para o servidor (é o que faz o personagem andar).

Antes de criar um remote, pergunte: "isso não é só uma propriedade que o servidor
pode setar?" Muitas vezes é.

## Network ownership

Quem simula a física de uma peça: o servidor ou algum cliente.

```lua
parte:SetNetworkOwner(jogador)  -- o cliente simula: responde na hora, sem lag
parte:SetNetworkOwner(nil)      -- o servidor simula: autoridade, mas com atraso
```

O personagem do jogador é dele por padrão, e é por isso que andar parece
instantâneo. Um carro que o jogador dirige deve ser dele. Uma plataforma que mata
ou um objetivo de partida deve ser do servidor: dar a posse ao cliente é dar a
ele o direito de teleportar aquilo.

`SetNetworkOwner` só vale para peça **não ancorada**; em peça ancorada lança erro.

## Não mande por frame

O erro mais comum de agente iniciante:

```lua
-- ERRADO: 60 remotes por segundo, por jogador.
RunService.Heartbeat:Connect(function()
    atualizarHud:FireAllClients(placar)
end)
```

O jogador não percebe diferença entre 60 e 10 atualizações de HUD por segundo.
Mande quando **muda**, ou em intervalo:

```lua
local sujo = false
local function marcar() sujo = true end

task.spawn(function()
    while true do
        task.wait(0.2)
        if sujo then
            atualizarHud:FireAllClients(placar)
            sujo = false
        end
    end
end)
```

E prefira **mandar a diferença**, não o estado inteiro: quem ganhou ponto, e não
a tabela dos 40 jogadores.

`FireAllClients` com uma tabela grande custa o tamanho **vezes** o número de
jogadores. Com 40 pessoas, uma tabela de 10KB vira 400KB de saída num tick.

## Direcione o que cada um recebe

`FireAllClients` é conveniente e vaza informação. A mão do adversário, a posição
de quem está escondido, o item que ainda não foi revelado: mande com `FireClient`
para quem tem direito de saber. Quem lê o tráfego lê tudo que você mandou, mesmo
que sua UI não mostre.

## Latência: previsão no cliente, verdade no servidor

O jogador não tolera esperar o round-trip para ver o próprio tiro sair. O padrão
honesto:

1. O cliente **mostra o efeito imediatamente** (tiro, som, animação): é enfeite.
2. O cliente avisa o servidor do que tentou fazer.
3. O servidor **decide** se valeu, e replica a consequência (dano, morte, ponto).
4. Se o servidor discordar, o cliente corrige o que mostrou.

Nunca o contrário: efeito no cliente é adiantamento visual, não decisão. O que
conta é o passo 3, e o passo 3 valida tudo (veja `lookup_guide("seguranca")`).

## Organize os remotes

Uma pasta `ReplicatedStorage/Remotes`, criada pelo servidor no boot, com nomes
que dizem a intenção (`PedirCompra`, `AvisarMorte`). O cliente espera com
`:WaitForChild`. Um módulo compartilhado que devolve as referências evita
`WaitForChild` espalhado por trinta arquivos.

Não crie remote por instância de objeto: um remote genérico com um identificador
no argumento é melhor que 200 remotes, e é bem mais fácil de validar num lugar só.

## Antes de entregar

- [ ] Nenhum remote disparando por frame sem necessidade
- [ ] Informação sensível vai por `FireClient`, não `FireAllClients`
- [ ] Nada de `InvokeClient` esperando resposta de cliente
- [ ] Física do que decide partida está com o servidor
- [ ] O que dava para resolver com propriedade replicada não virou remote
- [ ] Todo `OnServerEvent` valida os argumentos
