# Áudio: o sentido que ninguém lembra de programar

> Quando for pôr som: tiro, passo, música, clique de UI, ambiente, aviso.

Som é a metade barata do acabamento. Um clique de botão sem som parece
travado; um golpe sem impacto sonoro parece que não acertou. E quase sempre é a
última coisa que alguém lembra de fazer, o que significa que fazer bem custa
pouco e diferencia muito.

## Onde o `Sound` mora decide o que ele é

Isto é a regra central e resolve a maior parte das dúvidas:

- **Dentro de uma `BasePart` ou de um `Attachment`** → som **3D**: tem posição,
  volume cai com a distância, vem da direção certa.
- **Em `SoundService` ou direto em `workspace`** → som **2D**: toca igual em todo
  lugar. Música, UI, narração.

Errar isso é o que faz "a música só toca perto da caixa" ou "o tiro do outro
lado do mapa está no meu ouvido".

Para 3D, o alcance é regulado por:

```lua
som.RollOffMode = Enum.RollOffMode.InverseTapered
som.RollOffMinDistance = 10    -- até aqui, volume cheio
som.RollOffMaxDistance = 120   -- daqui pra frente, silêncio
```

O padrão do Roblox costuma ser alcance demais. Ajustar esses dois números é o
que faz um mapa parecer organizado em vez de uma sopa sonora.

## Cliente ou servidor

Som criado no **servidor replica** para todo mundo, e é isso que você quer para
evento do mundo: tiro, porta, explosão.

Som de **UI e de feedback do próprio jogador** vai no cliente. Botão, aviso,
sensação de dano. Mandar isso pelo servidor é atraso e tráfego à toa.

Para um som local rápido, sem se preocupar com hierarquia:

```lua
SoundService:PlayLocalSound(som)   -- só no cliente que chamou
```

## Repetição é o que cansa

O mesmo arquivo, no mesmo tom, cem vezes por minuto, vira ruído irritante. Duas
linhas resolvem:

```lua
som.PlaybackSpeed = 0.94 + math.random() * 0.12   -- variação sutil de tom
som.Volume = 0.5 * (0.9 + math.random() * 0.2)
```

Melhor ainda: três ou quatro variações do arquivo e sorteio entre elas. Passo,
tiro e impacto são os que mais pedem isso.

## Não crie e destrua um Sound por evento

Em jogo de tiro isso significa dezenas de instâncias por segundo. Ou você
reaproveita (pool), ou clona com prazo:

```lua
local function tocarEm(parte: BasePart, modelo: Sound)
    local s = modelo:Clone()
    s.Parent = parte
    s.PlaybackSpeed = 0.94 + math.random() * 0.12
    s:Play()
    -- Destruir antes do fim corta o som no meio; some espera a cauda.
    s.Ended:Once(function() s:Destroy() end)
    Debris:AddItem(s, s.TimeLength > 0 and s.TimeLength + 1 or 10)
end
```

`Debris` junto do `Ended` é cinto e suspensório: se o som nunca terminar (falha
de carregamento), a instância ainda sai.

## Grupos, para ter controle de volume de verdade

Todo jogo sério tem "volume da música" e "volume dos efeitos" separados.
`SoundGroup` existe exatamente para isso, e o barato é montar desde o começo:

```lua
local efeitos = Instance.new("SoundGroup")
efeitos.Name = "Efeitos"
efeitos.Volume = 1
efeitos.Parent = SoundService

som.SoundGroup = efeitos   -- agora um slider controla tudo de uma vez
```

Sem grupo, ajustar volume vira caça a cada `Sound` do jogo.

## Carregar antes de precisar

Som que toca pela primeira vez pode atrasar enquanto baixa. Para o que precisa
ser imediato, pré-carregue:

```lua
local ContentProvider = game:GetService("ContentProvider")
ContentProvider:PreloadAsync({somTiro, somImpacto})
```

`som.IsLoaded` e `som.Loaded` dizem se já está pronto. Isso vale a pena numa tela
de carregamento, não no meio da partida.

## Música e ambiente

- Música em loop precisa de `Looped = true` e de um arquivo que **casa no
  ponto**, senão o corte aparece toda volta.
- Faça fade em vez de cortar, com tween no `Volume`. Troca seca de faixa é
  desagradável.
- Volume de música quase sempre deve ser mais baixo do que parece certo enquanto
  você testa sozinho: ela concorre com os efeitos, que são os que dão informação.
- `SoundService.AmbientReverb` muda a sensação do espaço (caverna, salão, rua)
  com uma propriedade só.
- Silêncio é ferramenta. Tudo tocando o tempo todo achata os momentos que
  deveriam ser altos.

## Em edit mode

`run_code` consegue criar e configurar o `Sound`, e você pode **ler de volta**
`SoundId`, `Volume`, `RollOffMaxDistance` para conferir que ficou como planejou.
Se tocou de verdade, com que volume e se está no lugar certo do mapa, só em
playtest e com o usuário ouvindo. Não afirme que "ficou bom": diga o que
configurou.

## Antes de entregar

- [ ] Som de mundo dentro da peça; música e UI fora
- [ ] `RollOffMinDistance`/`MaxDistance` ajustados, não no padrão
- [ ] Variação de tom no que repete muito
- [ ] Nenhum `Sound` criado por evento sem prazo de destruição
- [ ] `SoundGroup` separando música de efeito
- [ ] Nada destruído antes de o som terminar
- [ ] Toda ação importante do jogador faz algum barulho
