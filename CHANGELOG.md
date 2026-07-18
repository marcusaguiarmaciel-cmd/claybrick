# Changelog

O texto da versão publicada aparece **dentro do plugin**, no chat, quando o
usuário clica na faixa de "nova versão disponível". Escreva para ele, não para
você: o que mudou para quem usa, não o que mudou no código.

O `make-release.ps1` lê a seção da versão atual daqui e a coloca no
`site/version.json`. **Sem seção para a versão, a build falha** — versão nova sem
nota vira um aviso que não diz nada, e aviso que não diz nada ensina o usuário a
ignorar avisos.

Formato: `## <versão>` e bullets. A versão precisa bater com o `VERSION` do
`server/agent/config.py` e do `plugin/ClaudeStudio.luau`.

## 0.2.2

- [correção] O modo assinatura voltou a subir. Na 0.2.1 ele morria com "Claude Code not found at..." apontando para um arquivo que estava lá, inteiro — a mensagem mentia. O system prompt tinha crescido além do limite de linha de comando do Windows, e agora vai por arquivo, sem limite.

## 0.2.1

- [novo] O Claude virou modelador: `solid_op` corta e funde forma de verdade (o Union/Negate do Studio) e `terrain_fill` esculpe terreno com material de verdade. Janela num muro, cano oco e caverna agora são uma operação, não trinta peças calculadas na mão.
- [novo] Ele sabe procurar um asset pronto antes de construir, e sabe dizer quando o certo é um mesh em vez de prometer uma espada bonita e entregar um retângulo pontudo.
- [novo] O raciocínio agora aparece também no modo assinatura. Mostrar não custa nada: o modelo pensa e é cobrado igual, exibido ou não — antes isso ficava escondido de graça.
- [novo] O chat ganhou a identidade do Claybrick, animação de entrada nas mensagens e um indicador de "pensando" que pulsa.
- [correção] O chat parou de te arrastar para o fim quando você sobe para reler algo.
- [novo] Sabe mais de acabamento: material antes de cor, colisão que acompanha a forma, e o que separa asset de protótipo.

## 0.2.0

- [correção] O plugin agora aparece no Studio. Antes ele era instalado num formato que o Studio ignora em silêncio.
- [segurança] Nenhum site consegue mais falar com a ponte. Antes, uma página aberta noutra aba podia mandar o Claude mexer no seu place.
- [correção] O Claude parou de entregar item equipável virado para o lado errado, e agora confere o eixo antes de dizer que terminou.
- [novo] A porta se resolve sozinha: se a preferida estiver ocupada, a ponte anda para a próxima livre e o plugin a encontra. Ninguém configura porta.
- [novo] Conversa longa não estoura mais: o histórico é resumido sozinho quando fica grande demais.
- [novo] Avisa quando sai versão nova, e avisa também quando só falta reiniciar o Studio.
- [performance] Gasta menos token: edita trecho em vez de reescrever o arquivo inteiro, não repete no chat o código que acabou de gravar, e o que já foi lido é cobrado a 10% do preço.
- [novo] Sabe mais de Luau moderno e do Studio: Anchored, CanTouch, atributos, tags e o que muda em edit mode.

## 0.1.0

- Primeira versão.
- [novo] O Claude constrói e testa dentro do Studio: 27 ferramentas, permissão
  por ferramenta e Ctrl+Z desfazendo cada escrita.
- [novo] Dois backends: chave da API ou a cota da sua assinatura Pro/Max.
