# Direção e orientação

> Quando algo precisar apontar, encaixar, girar ou ser segurado: arma na mão, porta girando, item na mesa, câmera.

Você não enxerga o place. Não existe screenshot, não existe "ficou bonitinho".
Se você chutar uma rotação e seguir em frente, o usuário é que vai descobrir que
a espada nasce atravessada na mão. Orientação é a área onde "eu acho que sim" te
trai mais — trate como número, não como intuição, e **leia de volta pra
conferir**.

## A regra que explica quase todo item virado errado

**No Roblox, a frente de qualquer coisa é o -Z dela.**

`CFrame.LookVector` é o -Z. `CFrame.lookAt(origem, alvo)` aponta o **-Z** para o
alvo. A face "Front" no Studio é a -Z. Isso vale para peça, modelo, câmera e
personagem.

Então: se você modelar uma espada com a lâmina indo para **+Z**, ela está virada
ao contrário — e ninguém vai te avisar. Todo item direcional que você construir
segue esta convenção:

```
-Z  = para onde aponta (lâmina, cano, frente do carro, olhar do NPC)
+Y  = para cima (topo da cabeça, dorso da lâmina)
+X  = para a direita de quem segura
```

Construa assim desde o começo. Consertar depois com rotação é remendo, e o
remendo aparece toda vez que alguém escala ou anima a peça.

## Graus e radianos: o segundo bug mais comum

- **`CFrame.Angles` recebe RADIANOS.** `CFrame.Angles(0, math.rad(90), 0)`.
  Passar `90` direto gira 90 *radianos* — algo em torno de 5157°, um valor
  aparentemente aleatório. É o clássico "girou pra um lugar sem sentido".
- **A propriedade `Orientation` é em GRAUS** (Vector3, ordem Y→X→Z).
- A ferramenta `set_property` recebe `orientation` do CFrame **em graus** e
  converte pra radianos por você (veja o formato dos valores). Dentro de código
  Luau que você escreve com `set_source`, `math.rad` é por sua conta.

## Ordem de multiplicação importa

```lua
CFrame.new(p) * CFrame.Angles(0, math.rad(90), 0)  -- posiciona, depois gira NO LOCAL dele
CFrame.Angles(0, math.rad(90), 0) * CFrame.new(p)  -- gira o mundo, depois desloca: p vai parar longe
```

Quase sempre você quer a primeira. E para "olhe para aquilo", não monte a
rotação na mão:

```lua
parte.CFrame = CFrame.lookAt(parte.Position, alvo.Position)          -- -Z encara o alvo
parte.CFrame = CFrame.lookAt(pos, alvo, Vector3.new(0, 1, 0))        -- travando o "cima"
```

## Tool: por que a arma sai torta na mão

Um `Tool` com `RequiresHandle = true` (o padrão) precisa de uma parte chamada
exatamente **`Handle`**. É o Handle que gruda na mão — o resto do modelo vai
junto, soldado nele.

Quem decide como o Handle assenta na mão é **`Tool.Grip`** (um CFrame).
`GripPos`, `GripForward`, `GripRight` e `GripUp` são as componentes dele
separadas — mexer numa mexe no Grip.

O ponto que resolve o problema: **quando o Handle já está na convenção acima
(-Z para a frente, +Y para cima), o Grip padrão sai perto do certo.** Item torto
quase sempre é Handle modelado fora da convenção, e aí a pessoa tenta compensar
girando o Grip até "parecer" certo — e quebra de novo na próxima animação.

Ordem certa: **conserte o Handle, depois ajuste o Grip.**

## Accessory: chapéu no lugar errado

Acessório moderno não usa rotação solta: usa um **`Attachment` dentro do
`Handle`** cujo **nome bate** com um Attachment do personagem —
`HatAttachment`, `HairAttachment`, `FaceFrontAttachment`, `RightGripAttachment`
e afins. O Roblox alinha os dois. Quem orienta é o **`CFrame` do Attachment**,
não o CFrame do Handle.

(As propriedades legadas `AttachmentPoint` / `AttachmentForward` / `AttachmentPos`
/ `AttachmentRight` / `AttachmentUp`, herdadas de `Accoutrement`, ainda existem,
mas o caminho por Attachment é o que se usa hoje.)

## Model: gire pelo pivô, não pela PrimaryPart

```lua
modelo:PivotTo(CFrame.new(pos) * CFrame.Angles(0, math.rad(90), 0))
```

`PivotTo` move o modelo inteiro; `GetPivot` te diz onde ele está. Só mexer na
`PrimaryPart.CFrame` deixa o resto para trás.

O **pivô é o centro da rotação**. Se ele estiver na quina do modelo em vez do
centro, girar 90° manda o objeto para outro lugar — e parece bug de posição
quando é de pivô. `WorldPivot` e `PivotOffset` são onde isso mora.

## Como conferir sem enxergar

Para o conjunto — tamanho, peça solta, peça atravessada, peça no ar — use
`inspect_space`. É a checagem que pega o erro grosseiro sem você ter que pensar
em qual pergunta fazer.

Para o eixo de um item específico, `run_code` **lê os vetores de volta**, em vez
de você torcer:

```lua
local h = workspace.Espada.Handle
return string.format(
    "look=%s up=%s right=%s",
    tostring(h.CFrame.LookVector),  -- pra onde a lâmina aponta
    tostring(h.CFrame.UpVector),
    tostring(h.CFrame.RightVector)
)
```

Um `LookVector` de `0, 0, -1` com a lâmina desenhada em -Z quer dizer que está
certo. `0, 0, 1` quer dizer que está 180° errado — e você acabou de descobrir
isso sozinho, em vez de o usuário descobrir.

Quando entregar um item direcional, diga qual eixo você conferiu. "Girei pra
ficar certo" não é verificação.
