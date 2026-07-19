# Performance: 16 milissegundos, e o celular do jogador

> Quando escrever loop por frame, criar muitos objetos, mexer em iluminação/terreno, ou quando algo estiver travando.

A 60 FPS você tem **16,6 ms por quadro** para tudo: seus scripts, física,
renderização, rede. Metade dos jogadores do Roblox está num celular que é várias
vezes mais lento que a sua máquina. "Rodou liso aqui" não é dado.

O erro caro raramente é um algoritmo ruim. É trabalho feito toda hora que podia
ser feito uma vez, ou nunca.

## O loop que você escreve por reflexo

```lua
-- ERRADO, em três níveis
while true do
    wait(0.1)                                   -- wait() é legado e impreciso
    for _, p in game.Workspace:GetDescendants() do  -- varre o mundo, 10x/s
        if p.Name == "Moeda" then ... end       -- compara nome em string
    end
end
```

Três correções, em ordem de importância:

**1. Não varra o mundo. Seja avisado.** `CollectionService` marca os objetos e
te entrega só eles, com evento quando entra ou sai:

```lua
local CollectionService = game:GetService("CollectionService")

for _, moeda in CollectionService:GetTagged("Moeda") do
    prepararMoeda(moeda)
end
CollectionService:GetInstanceAddedSignal("Moeda"):Connect(prepararMoeda)
```

Melhor ainda: se a moeda tem um `Touched`, não existe loop nenhum. O evento é o
loop.

**2. `task.wait()`, não `wait()`.** `wait()` é legado, impreciso e tem teto de
throughput. `task.wait()`, `task.spawn()`, `task.defer()` e `task.delay()` são os
atuais.

**3. Escolha o sinal certo.**

| Sinal | Onde | Quando usar |
|---|---|---|
| `Heartbeat` | os dois | depois da física; o padrão para lógica por frame |
| `PreSimulation`/`Stepped` | os dois | antes da física, quando você vai empurrar física |
| `RenderStepped`/`PreRender` | **só cliente** | câmera e UI que precisam colar no quadro |

`RenderStepped` roda **dentro** do caminho de renderização: código pesado ali
derruba o FPS diretamente. Só entra o que precisa estar sincronizado com a
câmera.

## Custo de instância

- Criar e destruir peça toda hora é caro. Efeito que repete (tiro, faísca, moeda)
  pede **pool**: crie N, reaproveite, esconda em vez de destruir.
- Não use o segundo argumento de `Instance.new("Part", workspace)`. Configure a
  peça inteira e **defina o `Parent` por último**: cada mudança em objeto já
  parenteado dispara replicação e recálculo.
- `part:Destroy()` também desconecta o que estava ligado nele. Já
  `conexao:Disconnect()` é por sua conta: conexão viva segurando uma tabela é o
  vazamento de memória mais comum em Roblox. Guarde as conexões e limpe.
- `Debris:AddItem(parte, 5)` é mais barato de escrever que um `task.delay` com
  `Destroy`, e não segura referência.

## Peças, malhas e união

- `MeshPart` renderiza melhor que união (`UnionOperation`) equivalente. Union tem
  custo de colisão e de renderização maior; para forma decorativa, considere
  `CanCollide = false` e `CollisionFidelity = "Box"`.
- Peça pequena demais, aos milhares, mata o FPS mesmo sem script nenhum. Terreno
  e mesh existem para isso.
- Para mapa grande, **`StreamingEnabled`**: o cliente só carrega o pedaço perto
  dele. Isso muda como você escreve o cliente — o que está longe **pode não
  existir**, então `WaitForChild` e checagem de `nil` deixam de ser paranoia.

## Iluminação e efeito

`Future` é a iluminação bonita e a cara. Sombra em objeto que se move custa mais
que em objeto parado; `CastShadow = false` em peça pequena e decorativa é ganho
grátis. Muitas `PointLight`/`SpotLight` na mesma cena é um dos jeitos mais fáceis
de derrubar celular.

Partícula é barata por unidade e cara no total: `Rate` alto e vida longa fazem
milhares de partículas vivas ao mesmo tempo.

## Onde o trabalho deve rodar

Efeito visual, som e feedback de UI são do **cliente**. Rodar isso no servidor
custa o trabalho **mais** a replicação para todo mundo. O servidor manda "o tiro
saiu daqui para ali"; cada cliente desenha.

Regra: se o resultado é visual e não muda a verdade da partida, é cliente.

## Luau que ajuda

- `--!strict` não é só segurança: com tipos, o Luau otimiza melhor.
- Guarde referência em vez de reencontrar: `local rs = game:GetService(...)` uma
  vez no topo, não dentro do loop.
- `table.insert(t, v)` num laço apertado perde para `t[#t + 1] = v`.
- `for _, v in tabela do` (sem `ipairs`/`pairs`) é o idioma atual e é rápido.
- String em loop com `..` cria lixo a cada volta; junte numa tabela e
  `table.concat` no fim.
- `Vector3.new` dentro de loop por frame gera muito objeto. Reaproveite quando
  der; `vector` e operação em componente ajudam.
- Raycast é barato por chamada e caro em quantidade. Não faça 40 por frame:
  espace no tempo, ou filtre por distância antes.

## Meça, não adivinhe

O Studio tem **MicroProfiler** (Ctrl+F6) e a aba **Script Performance**. Você não
tem acesso direto a eles, mas pode:

- cronometrar com `os.clock()` em volta do trecho e reportar o número;
- usar `run_code` com um laço de N iterações para comparar duas versões;
- pedir ao usuário que abra o MicroProfiler se a suspeita for de renderização.

Diga o número que mediu. "Ficou mais rápido" sem medida é chute.

## Antes de entregar

- [ ] Nenhum `while true do` varrendo `GetDescendants`
- [ ] `task.wait`, não `wait`
- [ ] Nada pesado em `RenderStepped`
- [ ] Conexões guardadas e desconectadas
- [ ] `Parent` definido por último na criação
- [ ] Efeito visual roda no cliente
- [ ] Se é mapa grande, `StreamingEnabled` foi considerado
