# Efeitos visuais: onde o jogo ganha acabamento

> Quando for fazer explosão, magia, rastro, brilho, fumaça, dano na tela, transição, ou "deixar mais bonito".

A distância entre um jogo que parece amador e um que parece profissional quase
nunca é a modelagem. É o **feedback**: o que acontece na tela no instante em que
o jogador faz alguma coisa. Tiro sem clarão, acerto sem partícula e morte sem
nada acontecendo parecem quebrados mesmo quando a lógica está perfeita.

**Regra que vale para o guia inteiro: efeito é do cliente.** Ele não decide nada,
só mostra. Rodar no servidor custa o trabalho mais a replicação para todo mundo,
e ainda fica atrasado.

## Partícula

`ParticleEmitter` dentro de uma peça ou `Attachment`. As propriedades que mais
mudam o resultado:

- `Rate` (por segundo) e `Lifetime` (NumberRange): juntos definem quantas
  partículas existem vivas ao mesmo tempo. É aqui que se destrói o FPS.
- `Size` e `Transparency` são `NumberSequence`: a partícula deve **nascer e
  morrer suave**. Partícula que some de repente é o que mais entrega amadorismo.
- `Speed`, `SpreadAngle`, `Acceleration`, `Drag`.
- `LightEmission` (brilho próprio) e `LightInfluence` (0 = ignora a iluminação da
  cena, bom para fogo e magia).
- `Texture`: partícula quadrada com textura padrão parece placeholder.

Para **rajada** (explosão, impacto), não ligue e desligue o `Rate`. Use `:Emit`:

```lua
local emissor = modelo.Impacto.ParticleEmitter
emissor:Emit(30)   -- solta 30 de uma vez e acabou
```

E o erro que aparece sempre: **destruir o efeito no mesmo instante**. As
partículas já emitidas somem no ar. Desligue e destrua depois do tempo de vida:

```lua
local function soltarEfeito(cframe: CFrame)
    local peca = MODELO_EFEITO:Clone()
    peca.CFrame = cframe
    peca.Parent = workspace
    peca.Emissor:Emit(30)
    Debris:AddItem(peca, peca.Emissor.Lifetime.Max + 0.1)
end
```

## Rastro e feixe

- **`Trail`**: precisa de dois `Attachment` na peça (`Attachment0`, `Attachment1`);
  o rastro é a área entre eles. Espada, projétil, pegada. `Lifetime` curto
  (0,1 a 0,3) dá corte rápido; longo vira borrão.
- **`Beam`**: liga dois `Attachment` que podem estar em peças diferentes. Raio,
  corda, laser, teleguiado. `CurveSize0/1` curvam, `TextureSpeed` faz correr.

Beam e Trail seguem os attachments sozinhos, sem código por frame. Sempre que
pensar em "atualizar a posição do raio a cada quadro", provavelmente é Beam.

## Destacar sem contorno improvisado

`Highlight` (`FillColor`, `OutlineColor`, `DepthMode`) resolve "brilhar o objeto
que dá pra pegar" com um objeto só, e enxerga através de parede se você quiser.
Antes disso a gente clonava a peça com `SelectionBox`; não faça mais isso.

Limite quantos existem ao mesmo tempo: `Highlight` tem custo de renderização e
não é para pendurar em cem objetos.

## Iluminação e pós-processamento

Dentro de `Lighting`, e tudo isso é visual puro, então cliente:

- `Atmosphere`: `Density`, `Haze`, `Glare`. Sozinho já muda o clima da cena mais
  que qualquer outra coisa.
- `BloomEffect`: brilho estourado. Sutil funciona; forte parece filtro barato.
- `ColorCorrectionEffect`: `TintColor`, `Saturation`, `Contrast`. É o que dá
  "identidade de cor". Também é como se faz flash de dano (tint vermelho por
  0,1s) e transição de cena.
- `DepthOfField`, `SunRaysEffect`: use com parcimônia.
- `Lighting.ClockTime`, `Ambient`, `OutdoorAmbient` para hora do dia.

Um `ColorCorrection` animado com tween é a ferramenta mais barata que existe
para: tomar dano, entrar em câmera lenta, morrer, mudar de fase.

## Câmera: o efeito mais subestimado

Tremida de câmera vale mais que qualquer partícula num impacto. No cliente:

```lua
local camera = workspace.CurrentCamera
local RunService = game:GetService("RunService")

local function tremer(intensidade: number, duracao: number)
    local fim = os.clock() + duracao
    local conexao
    conexao = RunService.RenderStepped:Connect(function()
        if os.clock() > fim then conexao:Disconnect(); return end
        local queda = (fim - os.clock()) / duracao          -- decai até zero
        camera.CFrame *= CFrame.new(
            (math.random() - 0.5) * intensidade * queda,
            (math.random() - 0.5) * intensidade * queda,
            0
        )
    end)
end
```

Decair a intensidade é o que separa "impacto" de "tela epilética". E ofereça um
jeito de desligar: tremida forte incomoda de verdade parte dos jogadores.

Outros baratos e eficazes: `camera.FieldOfView` subindo um pouco ao correr,
`Instance.new("BlurEffect")` ao abrir menu.

## Custo, que aqui chega rápido

- Partícula é barata por unidade e cara no total. `Rate = 500` com
  `Lifetime = 5` são 2500 partículas vivas.
- Transparência é a conta mais pesada da renderização: muita partícula
  semitransparente sobreposta derruba celular.
- **Pool os efeitos** que repetem. Criar e destruir modelo de explosão a cada
  tiro é trabalho puro.
- `PointLight`/`SpotLight` em cada projétil derruba a cena. Luz é para momento,
  não para enfeite constante.
- Efeito longe do jogador pode simplesmente não acontecer. Ninguém vê.

## Antes de entregar

- [ ] Todo efeito roda no cliente
- [ ] `Size` e `Transparency` como sequência, nascendo e morrendo suave
- [ ] Rajada por `:Emit`, não ligando/desligando `Rate`
- [ ] Nada destruído antes de as partículas acabarem
- [ ] Rastro e feixe por `Trail`/`Beam`, não por código por frame
- [ ] Tremida de câmera com decaimento
- [ ] Toda ação importante do jogador tem alguma resposta visual
