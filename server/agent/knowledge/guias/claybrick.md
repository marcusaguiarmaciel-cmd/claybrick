# Usar bem as suas próprias ferramentas

> Quando for construir algo grande, quando uma ferramenta falhar e você não souber por quê, quando estiver na dúvida entre duas ferramentas, ou no começo de um trabalho não-trivial.

Você tem 32 ferramentas. A diferença entre um agente medíocre e um bom aqui não é
saber Luau: é saber **qual ferramenta, em que ordem, e com qual prova no fim**.
Este guia é sobre isso.

## `batch` é a ferramenta que separa amador de profissional

Quarenta chamadas de `create_instance` são quarenta cards de permissão para o
usuário aprovar e quarenta Ctrl+Z para desfazer. A mesma construção em um `batch`
é **uma permissão e um undo**, com rótulo.

O recurso que quase ninguém usa, e que muda o que dá para fazer, é o `$id`:

```json
{
  "label": "Muro com janela",
  "ops": [
    {"op": "create_instance", "id": "$muro",  "class_name": "Part",
     "properties": {"Size": {"type":"Vector3","value":{"x":20,"y":10,"z":1}}}},
    {"op": "create_instance", "id": "$vao",   "class_name": "Part",
     "properties": {"Size": {"type":"Vector3","value":{"x":4,"y":5,"z":3}}}},
    {"op": "solid_op", "action": "negate", "parts": ["$muro", "$vao"]}
  ]
}
```

Você criou duas peças e subtraiu uma da outra **sem nunca ter lido o path de
volta**. Sempre que se pegar fazendo criar → ler o path → criar → ler o path,
era um `batch` com `$id`.

Use `label` sempre. É o que o usuário vê no histórico de undo, e "Criar sistema
de portas" é muito melhor que "Batch".

## A escada de teste, do barato pro caro

Suba um degrau por vez, e só suba se precisar:

1. **`check_syntax`** — compila e confere tipos contra a API real. Sem efeito
   colateral, rápido. **Todo script que você escrever passa por aqui**, sem
   exceção. Se voltar `type_check='indisponível'`, só a sintaxe foi vista: aí
   confira as propriedades com `lookup_api` antes de entregar.
2. **`run_code`** — a ferramenta mais poderosa que você tem. `require` num
   ModuleScript com asserts de verdade, em edit mode, sem sujar o place. É onde a
   maior parte do teste deve morar.
3. **`get_output`** — leia o que o Studio imprimiu, para ver o que realmente
   aconteceu, não o que você supôs.
4. **`run_playtest`** — **destrutivo**. Parar não restaura o place: o que a
   física derrubou e os scripts criaram permanece, e o Ctrl+Z não salva de forma
   confiável. Só quando o comportamento em runtime for o objeto do teste, e
   avisando o usuário antes.

Testar de verdade com `run_code` é assim:

```lua
local M = require(game.ServerScriptService.Economia)

assert(M.calcularPreco(1) == 100, "preço base errado")
assert(M.calcularPreco(2) > M.calcularPreco(1), "preço deveria subir")

local ok = pcall(function() M.comprar(nil, "item") end)
assert(not ok, "comprar com jogador nil deveria falhar")

return "3 asserts passaram"
```

Isso é prova. "Escrevi o módulo e parece certo" não é.

**Perigo real:** o Studio é de thread única. Um laço que nunca dá yield
(`while true do end` sem `task.wait`) **trava o Studio do usuário de vez**, e nem
o timeout salva, porque não sobra thread para contá-lo. Todo laço longo leva
`task.wait()`.

## Não chute a API

`lookup_api` responde a partir do dump oficial da versão do Studio que o usuário
tem instalada. Sempre que não tiver **certeza absoluta** de que uma propriedade
existe, consulte. É barato, e é o que impede o `part.Colour` inventado.

Quando uma escrita falha por propriedade inexistente, você recebe de volta o nome
certo ("em Part existe: Color, BrickColor"). Use isso e corrija na hora, em vez de
tentar de novo às cegas.

## Procure antes de construir

Árvore, móvel, veículo, arma genérica: já foi modelado por alguém melhor nisso
que trinta peças suas empilhadas. `search_assets` mostra nome, criador, votos e
**se o modelo contém scripts**; `insert_asset` insere pelo ID.

Nunca invente ID: ou falha, ou traz outra coisa qualquer.

E confira o que entrou. Modelo da toolbox com script dentro é o vetor clássico de
backdoor: `find_instances` com `class_name = "Script"` no que acabou de inserir,
e leia antes de aceitar. Veja `lookup_guide("seguranca")`.

## Memória de projeto

`get_project_memory` no **começo de todo trabalho não-trivial**. São as suas
próprias decisões de sessões passadas, guardadas dentro do place.

`set_project_memory` quando decidir algo que a próxima sessão precisa saber:
arquitetura escolhida, convenção de nomes, por que algo foi feito de um jeito
estranho. **Não guarde o que dá para ler do código** — guarde o porquê. Ela
sobrescreve tudo, então reescreva o conteúdo inteiro.

## Ler de volta é a diferença entre saber e supor

Você não enxerga o place. O retorno de uma escrita diz que a chamada foi aceita,
não que o resultado ficou certo. Antes de dizer que acabou:

- `get_properties` no que criou, conferindo o que importa;
- a ferramenta de medição para achar peça sem âncora, peça atravessando peça e
  peça boiando, que é o tipo de erro que só aparece no primeiro playtest;
- `get_tree` para confirmar que a hierarquia ficou como você planejou.

## `set_source` ou `patch_source`

`set_source` reescreve o script inteiro. `patch_source` altera faixas de linha, e
espera os números que o `get_source` devolveu.

Para mudança pontual em arquivo grande, `patch_source` é melhor: menos texto,
menos chance de reintroduzir um erro em código que você não ia tocar. Para
reescrita real, `set_source` e pronto.

## Permissões: você não decide, mas influencia

Cada ferramenta tem uma classe: `READ` nunca pergunta, `WRITE` pergunta no modo
"ask", `EXECUTE` pergunta também em "acceptEdits". Quem decide é o plugin.

O que está na sua mão é **não desperdiçar a paciência do usuário**: agrupar
escritas em `batch`, não repetir leitura que você já fez, e não chamar
`run_playtest` por hábito.

## O ciclo, resumido

1. `get_project_memory` e `get_tree` para se orientar.
2. `lookup_guide` do domínio, se a tarefa entra numa área com guia.
3. `search_assets` se o que falta já existe pronto.
4. `batch` rotulado para construir.
5. `check_syntax` em todo script.
6. `run_code` com asserts.
7. Ler de volta e medir.
8. Dizer o que ficou testado e o que não ficou.

## Antes de entregar

- [ ] As escritas foram agrupadas em `batch` com `label`
- [ ] Todo script passou por `check_syntax`
- [ ] Existe pelo menos um `run_code` com assert, quando dava para testar
- [ ] O resultado foi lido de volta, não suposto
- [ ] `run_playtest` só foi usado se era mesmo necessário, e com aviso
- [ ] Decisão de arquitetura nova foi para a memória de projeto
