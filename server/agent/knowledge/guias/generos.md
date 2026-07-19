# Gêneros: o que cada um exige de verdade

> Quando o usuário nomear um gênero (obby, simulator, tycoon, tower defense, horror, RPG, corrida, round-based) e você precisar saber o esqueleto e a armadilha clássica dele.

Cada gênero do Roblox tem um esqueleto conhecido e uma armadilha que derruba quem
o constrói pela primeira vez. Saber os dois evita reinventar mal o que já tem
forma consagrada, e evita descobrir o problema estrutural depois de tudo pronto.

## Obby

**Laço:** tenta → morre → aprende → passa.

- Checkpoint com `SpawnLocation` por estágio, e o estágio salvo no jogador
  (atributo no servidor, persistido). Sem isso, cair no fim significa recomeçar,
  e a pessoa sai.
- Kill brick é `Touched` com verificação de `Humanoid` **no servidor**.
- Plataforma móvel: peça ancorada movida por `TweenService`, ou `Motor6D`. Peça
  não ancorada faz o jogador escorregar.

**Armadilha:** teleporte de checkpoint no cliente. O jogador pula direto para o
último estágio. O estágio é do servidor, e o `SpawnLocation` respeita isso.

## Simulator

**Laço:** bate → ganha → melhora → bate mais rápido.

- Progressão exponencial, tudo numa tabela de configuração
  (veja `lookup_guide("design")`).
- Tudo depende de DataStore funcionando bem: é o gênero que mais castiga save
  ruim, porque o jogador acumula por horas.
- Multiplicadores empilham: pet × ferramenta × rebirth. Calcule num lugar só,
  senão vira caça a bug de balanceamento.

**Armadilha:** contar moeda no cliente. Todo simulator popular é alvo de
exploit; o valor mora no servidor e o cliente só exibe.
Veja `lookup_guide("seguranca")`.

## Tycoon

**Laço:** coleta → compra estação → produz mais → compra maior.

- Um **plot por jogador**, atribuído na entrada e liberado na saída.
- Botão de compra é peça com `Touched` + preço; a estação nasce a partir de um
  modelo guardado em `ServerStorage`.
- O estado do plot (o que já foi comprado) precisa ser salvo e reconstruído no
  retorno. Salve a **lista do que foi comprado**, não as peças.

**Armadilha:** dropper que cria peça sem limite. Mil peças no chão derrubam o
servidor. Ponha teto e destrua com `Debris`.

## Tower defense

**Laço:** onda → posiciona → melhora → onda maior.

- Caminho fixo por waypoints (não `PathfindingService`: o caminho é de projeto).
- Inimigos como assembly simples, movidos por tween ou `AlignPosition`; Humanoid
  em cada um é caro demais em quantidade.
- Alvo escolhido por critério explícito (primeiro, mais forte, mais perto), e a
  torre atira em intervalo, não por quadro.

**Armadilha:** cada torre percorrendo todos os inimigos por quadro. É O(n²)
clássico; use grade espacial ou intervalo maior.
Veja `lookup_guide("algoritmos")`.

## Shooter / PvP

**Laço:** mira → acerta → sobe → desbloqueia.

- Raycast, nunca `Touched`, para projétil.
- Efeito e som imediatos no cliente; dano decidido no servidor.
- Respawn, times, placar, e uma sala de espera entre partidas.

**Armadilha:** aceitar "acertei fulano por X" do cliente. O servidor precisa
validar arma equipada, cooldown, distância e linha de visão.

## Horror / escape

**Laço:** explora → é ameaçado → foge/esconde → progride.

- A tensão é feita de **áudio e iluminação**, não de dano. Som distante,
  reverb, luz que pisca.
- Perseguidor com estados (procurando, caçando, desistindo) e leash.
- Visibilidade limitada: lanterna, névoa, `Atmosphere`.

**Armadilha:** o monstro estar sempre visível ou sempre perfeito na perseguição.
Medo depende de incerteza; NPC que erra e procura assusta mais que NPC infalível.

## RPG

**Laço:** luta → sobe de nível → equipa melhor → enfrenta mais forte.

- Stats numa tabela por jogador, no servidor.
- Inventário é o sistema que mais dá trabalho: defina cedo o formato salvo
  (lista de ids com quantidade), porque mudá-lo depois exige migração.
- Missões como dados, não como código: uma tabela de definição e um motor que a
  interpreta.

**Armadilha:** modelar item como instância no Workspace. Item é **dado**;
a instância é só a representação visual quando equipado.

## Corrida

**Laço:** acelera → erra a curva → melhora o tempo.

- Veículo com constraints modernos e dono de rede no piloto, senão o carro fica
  travado e atrasado.
- Checkpoints em ordem, com verificação de sequência para não valer atalho.
- Contagem de voltas no servidor.

**Armadilha:** dar dono de rede ao piloto e confiar no tempo que ele reporta.
A posição é dele; o cronômetro é do servidor.

## Round-based / minigame

**Laço:** espera → partida → resultado → espera.

- Uma máquina de estados no servidor: `intervalo → preparando → jogando → fim`.
- Um único script conduz o ciclo; os minigames são módulos com a mesma
  interface (`iniciar`, `parar`).
- Teleporte para a arena, e limpeza confiável no fim de cada rodada.

**Armadilha:** o ciclo depender do número de jogadores sem tratar o caso de
todos saírem no meio. Toda transição precisa aguentar "sobrou uma pessoa" e
"sobrou ninguém".

## O que vale para todos

- O **laço primeiro**, jogável, antes de qualquer sistema acessório.
- Estado que vale dinheiro ou progresso mora no servidor.
- O que o jogador conquistou tem que sobreviver ao fechar o jogo.
- Se o usuário nomeou o gênero mas não o conteúdo, use o esqueleto daqui e
  **pergunte o que muda**, em vez de inventar dez sistemas.

## Antes de entregar

- [ ] O esqueleto do gênero está de pé e jogável
- [ ] A armadilha clássica do gênero foi evitada de propósito
- [ ] Progresso persiste
- [ ] Nada que decide recompensa mora no cliente
- [ ] O que ficou de fora do gênero foi dito ao usuário
