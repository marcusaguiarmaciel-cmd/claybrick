# Design de jogo: antes de sair construindo sistema

> Quando o pedido for vago ("faz um jogo", "cria um simulator"), quando for decidir o que construir primeiro, ou quando houver muito sistema e pouca graça.

O pedido "cria um jogo de X" tem uma armadilha embutida: dá para gastar horas
construindo inventário, loja, ranking e sistema de pet sem que exista, em
momento algum, **algo divertido de fazer**. Sistema não é jogo. Jogo é o que o
jogador faz repetidamente e gosta.

Quando o pedido for vago, sua primeira entrega não é uma arquitetura. É o **laço
principal jogável**, pequeno e inteiro.

## O laço principal

Escreva em uma frase antes de escrever código: **o jogador faz A, ganha B, que
melhora C, que deixa ele fazer A melhor.**

- Simulator: bate → ganha moeda → compra melhoria → bate mais rápido.
- Obby: tenta → morre → aprende → passa o trecho.
- Tycoon: espera/coleta → compra estação → produz mais → compra maior.
- Shooter: mira → acerta → sobe de nível → desbloqueia arma.

Se você não consegue escrever essa frase, ainda não sabe o que está construindo,
e é hora de perguntar ao usuário em vez de adivinhar por trinta arquivos.

**Construa o laço na ordem em que ele acontece**, e deixe-o jogável a cada
passo. Um obby com três plataformas que funcionam vale mais que um obby com
sistema de skin e nenhuma plataforma.

## Os primeiros trinta segundos

No Roblox, quem não entendeu o jogo em meio minuto sai. Não existe tutorial que
salve isso, porque ninguém lê tutorial.

- O jogador nasce **de frente para o que importa**. Não de costas, não longe.
- A primeira ação possível deve ser **óbvia e imediata**: bater, pegar, pular.
- A primeira recompensa vem **rápido**, antes de o jogador decidir se fica.
- Ensine fazendo, não explicando. Uma seta apontando para o alvo ensina mais que
  um painel de texto.

Se o usuário pedir um jogo, vale perguntar a si mesmo: "o que a pessoa faz no
primeiro minuto?". Se a resposta é "espera" ou "lê", o design tem um problema.

## Toda ação precisa responder

Um clique que não produz som, número subindo, partícula ou movimento parece
quebrado, mesmo com a lógica certa. Essa é a diferença mais barata entre um
protótipo e um jogo: número que sobe na tela, som, tremida, brilho.

Isso não é enfeite opcional. É o que informa o jogador de que ele acertou. Veja
`lookup_guide("vfx")` e `lookup_guide("audio")`.

## Progressão: rápido no começo, devagar depois

A primeira melhoria deve vir em menos de um minuto. A segunda, em poucos
minutos. A partir daí o intervalo cresce.

Curva multiplicativa é o padrão do gênero, e é fácil de ajustar num lugar só:

```lua
local CUSTO_BASE = 100
local FATOR = 1.15        -- 1.1 é generoso; 1.3 vira parede rápido

local function custo(nivel: number): number
    return math.floor(CUSTO_BASE * FATOR ^ (nivel - 1))
end
```

Deixe esses números **numa tabela de configuração**, não espalhados pelo código.
Balancear é mexer neles dezenas de vezes, e ninguém quer caçar constante em
quatro scripts.

Sempre dê ao jogador **um objetivo visível a caminho**: a próxima melhoria, com
o preço e o quanto falta. Progresso invisível não motiva.

## O que o Roblox muda no cálculo

- **Sessão é curta e interrompida.** O jogo precisa fazer sentido em cinco
  minutos e ao voltar amanhã. Progresso tem que salvar (`datastores`).
- **É social por natureza.** O que outras pessoas veem (efeito, tamanho, título,
  raridade) motiva mais do que número no inventário. Torne o progresso visível
  para os outros.
- **A maioria está no celular.** Controle complexo não sobrevive.
  Veja `lookup_guide("ui")`.
- **Servidor com muita gente é a norma.** O laço precisa aguentar quarenta
  pessoas fazendo aquilo ao mesmo tempo, e não ficar chato porque alguém pegou o
  recurso antes.

## Dificuldade

Frustração vem de sentir que a culpa não foi sua. Morrer por algo que não dava
para prever é injusto; morrer por errar o tempo é justo e ensina.

- Introduza um perigo por vez, num lugar seguro, antes de combinar perigos.
- Depois de um trecho difícil, dê um respiro.
- Ponto de retorno generoso: repetir cinco minutos por causa de um erro é o que
  faz a pessoa fechar o jogo.

## Monetização sem estragar o laço

Vender **atalho e enfeite** (velocidade, aparência, conveniência) é sustentável.
Vender **a única forma de jogar direito** mata a base de jogadores, que no Roblox
é justamente o que sustenta o jogo.

Teste honesto: se o jogador que não paga tem um bom jogo, a venda é legítima.

## Escopo, e o que dizer ao usuário

Um pedido de "jogo completo" não cabe numa sessão. O caminho é entregar o laço
mínimo funcionando e **dizer com clareza o que existe e o que não existe**, em
vez de fingir um jogo inteiro com sistemas vazios.

Uma ordem que costuma funcionar:

1. O laço principal, jogável do começo ao fim.
2. Feedback (som, efeito, números).
3. Progressão e persistência.
4. Conteúdo (mais fases, mais itens).
5. Social e monetização.

Entregar 1 e 2 bem feitos é um protótipo divertido. Entregar 3, 4 e 5 sem 1 é uma
casca.

## Antes de entregar

- [ ] Dá para escrever o laço principal em uma frase
- [ ] O jogador faz algo interessante no primeiro minuto
- [ ] Toda ação tem resposta visual e sonora
- [ ] A primeira recompensa chega rápido
- [ ] Os números de balanceamento estão numa tabela só
- [ ] Existe um objetivo visível a caminho
- [ ] O que ficou de fora foi dito ao usuário, não escondido
