# UI: metade dos seus jogadores está no celular

> Quando criar ou ajustar qualquer interface: menu, HUD, loja, inventário, botão, diálogo.

A maior parte da UI que um agente entrega tem o mesmo defeito: foi pensada numa
janela de Studio widescreen e desmonta num celular em pé. E é lá que está a maior
fatia dos jogadores do Roblox.

Duas decisões resolvem quase tudo: **usar Scale em vez de Offset** e **testar em
proporção de celular**.

## UDim2: Scale e Offset

`UDim2.new(escalaX, offsetX, escalaY, offsetY)`. Escala é fração da tela (0 a 1);
offset é pixel cru.

```lua
-- ERRADO: 400 px de largura. Num celular de 320 px, vaza a tela.
frame.Size = UDim2.new(0, 400, 0, 250)

-- CERTO: metade da largura, um terço da altura, em qualquer tela.
frame.Size = UDim2.new(0.5, 0, 0.33, 0)
```

Use **offset** só para coisa que deve manter tamanho físico: espessura de borda,
padding pequeno, ícone que não pode borrar. Todo o resto em **scale**.

Escala sozinha distorce: 50% de largura numa tela larga vira um retângulo
esticado. Amarre com `UIAspectRatioConstraint`:

```lua
local proporcao = Instance.new("UIAspectRatioConstraint")
proporcao.AspectRatio = 1.6   -- o painel guarda o formato em qualquer tela
proporcao.Parent = frame
```

## AnchorPoint, ou por que centralizar dá errado

`Position` posiciona o **canto superior esquerdo** do elemento. Para centralizar
de verdade, mova a âncora para o meio do próprio elemento:

```lua
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)   -- agora sim, centro da tela
```

Mesma lógica para grudar embaixo à direita: `AnchorPoint = Vector2.new(1, 1)` com
`Position = UDim2.new(1, 0, 1, 0)`.

## Deixe o layout calcular por você

Posição absoluta de dez botões é dez lugares para quebrar. Use os objetos de
layout:

- `UIListLayout` — lista vertical ou horizontal, com `Padding` e `SortOrder`
- `UIGridLayout` — grade de inventário
- `UIPadding` — respiro interno, sem inventar margem na mão
- `UICorner`, `UIStroke` — canto e contorno, em vez de imagem fatiada
- `UITextSizeConstraint` — junto com `TextScaled`, impede texto virar formiga ou
  gigante

`TextScaled = true` sem `UITextSizeConstraint` é a receita de texto ilegível em
tela pequena. Os dois juntos, sempre.

## Celular: o dedo cobre a tela

- **Alvo de toque mínimo confortável: ~44 px.** Botão de 20 px o polegar erra.
- **Zona do polegar.** Ação frequente vai nas bordas inferiores, ao alcance do
  polegar. O topo da tela é para informação, não para botão que se aperta toda
  hora.
- **Os controles nativos já ocupam espaço**: joystick à esquerda, botão de pulo à
  direita embaixo. Não ponha nada seu por cima deles.
- **O entalhe (notch) e a barra superior** comem área. `GuiService:GetGuiInset()`
  diz quanto, e `ScreenGui.IgnoreGuiInset` controla se você desenha por baixo.
- **`ScreenGui.SafeAreaCompatibility`** ajuda a manter o conteúdo dentro da área
  visível em aparelhos com entalhe.

Detecte plataforma pelo que existe, não por adivinhação:

```lua
local UIS = game:GetService("UserInputService")
local toque = UIS.TouchEnabled and not UIS.KeyboardEnabled
```

## Onde a UI mora

`StarterGui` é o **molde**: no spawn, é copiado para `Players.LocalPlayer.PlayerGui`.
Você manipula o que está em `PlayerGui`, não o molde.

`ResetOnSpawn = false` em qualquer GUI que deva sobreviver à morte do personagem
(HUD, inventário). Sem isso, ela é recriada a cada respawn e você perde estado e
conexões.

UI é **cliente**. Servidor não cria interface: ele avisa o cliente, e o
LocalScript desenha. Servidor mexendo em PlayerGui é lento e replica errado.

## Faça a interface responder

Botão que não dá retorno visual parece quebrado. O mínimo:

```lua
local TweenService = game:GetService("TweenService")
local info = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

botao.MouseEnter:Connect(function()
    TweenService:Create(botao, info, {Size = tamanhoBase * 1.05}):Play()
end)
botao.MouseLeave:Connect(function()
    TweenService:Create(botao, info, {Size = tamanhoBase}):Play()
end)
```

`Activated` é o evento certo para clique de botão: funciona com mouse, toque e
controle de uma vez. `MouseButton1Click` ignora as outras entradas.

## Controle e teclado

Para funcionar no console e no controle, os elementos navegáveis precisam de
`Selectable = true`, e você define o foco inicial com
`GuiService.SelectedObject`. `NextSelectionUp/Down/Left/Right` controlam para
onde o direcional anda.

## Custo

- `ClipsDescendants = true` em painel que rola evita desenhar o que está fora.
- Transparência empilhada custa: dez frames semitransparentes sobrepostos são
  dez passadas de desenho no mesmo pixel.
- UI escondida ainda existe. Para menu pesado, `Enabled = false` no `ScreenGui`
  sai do caminho de renderização de vez.

## Antes de entregar

- [ ] Tamanhos em Scale; Offset só onde tem que ser fixo
- [ ] `UIAspectRatioConstraint` no que não pode distorcer
- [ ] `AnchorPoint` coerente com a posição
- [ ] `TextScaled` acompanhado de `UITextSizeConstraint`
- [ ] Botão com pelo menos ~44 px de lado
- [ ] Nada colado sobre joystick e botão de pulo
- [ ] `ResetOnSpawn = false` no que precisa sobreviver ao respawn
- [ ] Feedback visual em toda coisa clicável
