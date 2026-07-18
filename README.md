# Claude Studio — o Claude como dev dentro do Roblox Studio

Um **plugin** dá ao Claude ferramentas reais no Roblox Studio: ler a hierarquia,
escrever scripts, **executá-los para testar**, e construir sistemas inteiros. Um
**servidor-ponte local** em Python fala com o Claude por dois backends:

| Backend | Como autentica | Custo |
|---|---|---|
| **API** | Chave da API da Anthropic | Pago por token |
| **Assinatura** | Claude Code logado na sua conta Pro/Max (Claude Agent SDK) | Cota da assinatura |

```
┌──────────────────┐  fila de trabalhos  ┌───────────────────┐
│  Plugin (Luau)   │ ─── /session/* ───▶ │  Servidor (Python)│
│  Roblox Studio   │ ◀── long-poll ───── │                   │
│  • chat          │                     │  backend=api ───────▶ API Anthropic
│  • permissões    │                     │  backend=sub ───────▶ Claude Code
│  • executa tools │                     │                   │      (sua assinatura)
└──────────────────┘                     └───────────────────┘
```

O Claude **pede** uma ferramenta; o servidor **enfileira**; o plugin **pergunta se
pode** (dependendo do modo), **executa** no Studio e devolve o resultado.

---

## 1. Servidor-ponte

Pré-requisito: Python 3.10+.

```powershell
cd C:\Projetos\ClaudeStudio\server
copy .env.example .env
notepad .env
.\run.ps1
```

Sobe em `http://127.0.0.1:8787`. Teste: `http://127.0.0.1:8787/health` — ele
mostra os backends disponíveis e se o API dump do Roblox foi indexado.

A porta não é 8000 de propósito: aquela é das mais disputadas que existem, e no
Windows serviços do sistema chegam a segurá-la de um jeito que faz o bind falhar
com "acesso negado". Se precisar trocar, mexa no `PORT` do `.env` **e** na caixa
de URL do plugin — os dois lados precisam bater. Se a porta estiver ocupada, o
servidor não sobe calado: ele diz qual porta está livre e o que mudar.

**Backend "API":** preencha `ANTHROPIC_API_KEY` e `DEFAULT_BACKEND=api`.

**Backend "Assinatura":**
1. Deixe `ANTHROPIC_API_KEY` **só no `.env`**, nunca como variável de ambiente do
   sistema — senão o Claude Code a herda e cobra pela API em vez da assinatura.
2. Logue o Claude Code uma vez:
   ```powershell
   npm install -g @anthropic-ai/claude-code
   claude   # escolha "Log in with Claude", não a opção de API
   ```
3. `DEFAULT_BACKEND=subscription` (dá para alternar no plugin).

> No modo assinatura o agente fica travado nas ferramentas do Roblox
> (`mcp__roblox__*`). Bash/Read/Write/Edit ficam bloqueados — ele **não** mexe no
> seu sistema de arquivos nem no terminal.
>
> A assinatura tem cota por janela de tempo, e uso automatizado gasta rápido.

## 2. Plugin

```powershell
cd C:\Projetos\ClaudeStudio\plugin
.\install.ps1
```

Copia para a pasta de Plugins do Studio. Depois, no Studio: aba **Plugins** →
**Claude Agent**. Na primeira ação, **permita** o acesso a scripts/HTTP.

## 3. Permissões

Esta é a parte importante. O botão no topo alterna três modos:

| Modo | Leitura | Escrita | Execução (`run_code`, playtest) |
|---|---|---|---|
| **Perguntar** (padrão) | direto | pergunta | pergunta |
| **Aceitar edições** | direto | direto | pergunta |
| **Sem permissões** | direto | direto | direto |

Cada pedido abre um card com o nome da ferramenta e os argumentos:
**Permitir** · **Permitir sempre** (lembra a ferramenta) · **Negar**.

Ao negar você pode dar um motivo — ele volta pro Claude como resultado de erro, e
ele se adapta em vez de travar ou insistir. Para esquecer os "permitir sempre",
use ⚙ → *Esquecer "permitir sempre"*.

**Ctrl+Z desfaz** as escritas — cada ferramenta (e cada `batch`) é um waypoint de
undo. `run_code` e `run_playtest` são a exceção: nem tudo que fazem é reversível.

## 4. Usar

- "Liste o que tem no Workspace."
- "Crie uma plataforma de neon vermelho 20x1x20 em (0, 10, 0)."
- "Crie um sistema de moedas colecionáveis: as moedas giram, somem ao encostar e
  contam pontos por jogador. Teste antes de me entregar."
- "Abra o script Main em ServerScriptService e adicione tratamento de erro."

---

## Como ele sabe o que está fazendo

- **API real do Roblox.** O servidor baixa e indexa o `Full-API-Dump.json`
  oficial da versão instalada do Studio (682 classes, 351 enums, cacheado em
  `server/.cache/`). A ferramenta `lookup_api` responde com as propriedades,
  métodos e eventos que existem de verdade — marcando os deprecados e os que só
  funcionam via plugin. É o que impede o `part.Colour` inventado.
- **Guias curados** de Luau moderno e arquitetura cliente-servidor entram no
  system prompt (`server/agent/knowledge/`).
- **Contexto do place** é injetado no início da sessão: nome, contagem de
  instâncias e scripts por serviço, e quais capacidades este Studio tem.
- **Memória de projeto** (`set_project_memory` / `get_project_memory`) vive num
  StringValue em `ServerStorage`, dentro do próprio place — sobrevive a reinícios
  e viaja junto com o arquivo.

## Como ele testa

Uma escada, do barato pro caro:

1. `check_syntax` — compila sem executar. Instantâneo, sem efeito colateral.
2. `run_code` com `require` + asserts — testa um ModuleScript **de verdade**, em
   edit mode, sem sujar o place. É onde a maior parte do teste deve morar.
3. `get_output` — lê o Output do Studio para ver o que aconteceu.
4. `run_playtest` — só quando o comportamento em runtime é o objeto do teste.
   **É destrutivo**: `RunService:Stop()` não restaura o place, então o que a
   física derrubar e os scripts criarem permanece.

## Ferramentas

**Leitura** (nunca pergunta) — `get_tree`, `get_place_info`, `get_selection`,
`set_selection`, `get_properties`, `find_instances`, `get_source`,
`search_source`, `lookup_api`, `check_syntax`, `get_output`,
`get_project_memory`

**Escrita** (pergunta; desfazível) — `create_instance`, `delete_instance`,
`set_property`, `set_source`, `patch_source`, `move_instance`, `rename_instance`,
`clone_instance`, `set_attribute`, `set_tags`, `batch`, `set_project_memory`,
`insert_asset`

**Execução** (pergunta em quase todo modo) — `run_code`, `run_playtest`

`batch` é o que faz projetos: várias escritas numa transação só — um undo, uma
permissão. Suporta referências `$id` para usar o path de algo criado no mesmo lote.

## Endpoints

| Endpoint | Uso |
|---|---|
| `POST /session/message` | `{session_id, message, backend, place_context}` |
| `GET /session/poll?session_id=` | long-poll: `tool`/`text`/`thinking`/`usage`/`compaction`/`done`/`error`/`wait` |
| `POST /session/tool_result` | `{session_id, id, content, is_error}` |
| `POST /session/cancel` | para o turno sem perder a conversa |
| `POST /session/reset` | encerra a sessão |
| `GET /tools` | ferramentas e classes de permissão |
| `GET /health` | status, backends, API dump |

## Estrutura

```
server/
  app.py                    casca HTTP + ciclo de vida das sessões
  agent/
    config.py               lê o .env sem poluir os.environ
    tools.py                as 27 ferramentas + classes de permissão
    prompt.py               system prompt (identidade, método, valores)
    knowledge/*.md          guias de Luau e arquitetura
    apidump.py              download/índice do Full-API-Dump
    session.py              sessões + ponte de ferramentas
    backends.py             backend api (streaming) e assinatura
plugin/
  ClaudeStudio.luau         o plugin
  install.ps1               instala na pasta de Plugins
```

## Conversas longas

Um projeto inteiro não cabe numa janela de contexto: cada `run_code`, cada
`get_tree` volta como texto no histórico, e o turno agêntico empilha isso rápido.

- **Compactação.** Passando de `COMPACT_AT` tokens (padrão 150k, mínimo 50k), a
  própria API resume a conversa antiga e segue do resumo — o chat avisa quando
  acontece. Sem isso a sessão morreria de erro ao encher o contexto. Só nos
  modelos que suportam: Opus 4.6+, Sonnet 4.6+, Sonnet 5, Fable 5.
- **Cache do histórico.** Um breakpoint rolante no fim da conversa faz o prefixo
  já visto ser lido a 0,1x do preço em vez de reprocessado inteiro a cada volta
  do loop. O contador no topo mostra o que veio do cache.
- **Custo real.** Compactar é uma chamada extra ao modelo, e o `usage` de topo
  da API não a inclui — o número que o plugin mostra soma todas as iterações.

## Atualizar

O mesmo comando da instalação atualiza: `irm https://claybrick.online/install.ps1 | iex`.
Ele troca servidor e plugin por cima e **preserva o `.env`**. Depois, reinicie o
Studio — ele lê a pasta de plugins só no boot (o hot reload dele existe, mas vem
desligado), então até reiniciar o plugin antigo continua na memória.

Ninguém precisa ficar conferindo se saiu versão: o plugin mostra uma faixa no
topo quando há novidade. Ela distingue dois casos, que exigem coisas diferentes:

| A faixa diz | O que aconteceu | O que falta |
|---|---|---|
| *Nova versão X disponível* | saiu release nova (checado em `claybrick.online/version.json`) | rodar o comando |
| *Plugin desatualizado · reinicie o Studio* | o instalador já rodou; o disco está novo, a memória não | só reiniciar o Studio |

A versão vive em dois lugares — `server/agent/config.py` e `plugin/ClaudeStudio.luau` —
e o `make-release.ps1` **quebra a build se elas divergirem**. Se saírem de sincronia,
o plugin avisaria de atualização que não existe, e o aviso perderia a credibilidade.

## Segurança

A ponte **não tem senha** — e não precisa, desde que só ela e o plugin se
alcancem. Três coisas sustentam isso:

- **Só escuta em `127.0.0.1`.** Nada de fora da máquina chega nela. Se você
  trocar o `HOST` por `0.0.0.0`, o servidor grita no boot: sem senha, isso
  significa qualquer um na sua rede mandando o Claude rodar código no seu place.
- **Nenhuma página web fala com ela.** O plugin não é um navegador — o
  `HttpService` não manda `Origin` nem `Sec-Fetch-*`. Requisição que traga esses
  cabeçalhos veio de um site, e leva 403. (Só CORS não bastaria: CORS decide quem
  *lê a resposta*, não quem *envia* — o efeito colateral aconteceria mesmo com o
  navegador jogando a resposta fora.)
- **A chave nunca sai do `.env`.** O `make-release.ps1` aborta a build se um
  `.env` entrar no pacote público, e o instalador preserva o seu ao atualizar.

No modo assinatura o agente ainda fica travado nas `mcp__roblox__*`: Bash, Read,
Write e Edit ficam bloqueados, então ele não toca no seu sistema de arquivos.

O que continua valendo: qualquer programa **já rodando na sua máquina** consegue
falar com a ponte. Nesse ponto o problema já não é o Claybrick.

## Notas e limites

- Estado da conversa fica na memória do servidor; reiniciar limpa as sessões.
  A **memória de projeto** não — ela vive no place.
- Paths usam `.` como separador — evite nomes de objeto com `.` no meio.
- Só funciona no Studio (plugins não rodam em jogo publicado).
- O `run_code` roda com permissão de plugin. No modo **Sem permissões** ele
  executa sem perguntar; use com noção.
