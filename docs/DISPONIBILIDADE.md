# Motor de disponibilidade

## Conceitos

- **Período:** intervalo semiaberto `[início, fim)` em UTC, com precisão de segundos. Períodos adjacentes não
  conflitam (uma locação até 10h e outra a partir de 10h coexistem).
- **Período bloqueado:** o período da locação expandido pelos tempos de preparação do produto
  (`buffer_before_minutes`, `buffer_after_minutes`). É o período gravado nas alocações.
- **Ativo individual:** unidade identificada (patrimônio, número de série). Disponível no período se for
  alocável (não extraviado/baixado), se não estiver operacionalmente bloqueado (inspeção, manutenção, trânsito)
  até depois do início, e se nenhuma alocação ativa se sobrepuser.
- **Estoque quantitativo:** unidades intercambiáveis por produto e filial (`stock_pools`). Disponível =
  capacidade − **ocupação máxima simultânea** no período, e não a soma das reservas que o intersectam.
- **Kit:** composição de produtos físicos. A demanda é expandida em componentes e **agregada por produto**, de
  modo que um componente pedido diretamente e via kit é verificado uma única vez contra a mesma capacidade.
  Kits não são aninhados; a disponibilidade de kits é o mínimo de `disponível(componente) / quantidade`.

## Algoritmo de pico (`Domain::Availability::Peak`)

Varredura de eventos recortados à janela: cada ocupação gera `(início, +q)` e `(fim, −q)`; em empates as
saídas são processadas antes das entradas (fim exclusivo). O pico é o maior acumulado.

Exemplo obrigatório (coberto em teste unitário, de integração e de propriedade): dez cadeiras, cinco reservadas
das 8h às 10h e cinco das 10h às 12h. O pico entre 8h e 12h é 5; uma nova reserva das 8h às 12h ainda pode
levar 5 cadeiras.

Propriedades verificadas com geração pseudoaleatória semeada: pico por varredura igual à força bruta; pico
limitado pela soma e monotônico na janela; reservas aceitas nunca excedem a capacidade; máximo da linha do
tempo igual ao pico; expansão de kits conserva quantidades.

## Garantias sob concorrência

| Situação | Mecanismo |
|---|---|
| Dois clientes disputando o último ativo | `EXCLUDE USING gist (asset_id WITH =, period WITH &&) WHERE (active)`; a segunda inserção falha e o alocador tenta outra unidade livre, ou recusa |
| Estoque quantitativo | `SELECT ... FOR UPDATE` na linha de `stock_pools`, em ordem de id, antes de calcular o pico e inserir |
| Bloqueio temporário vencido ainda marcado como ativo | ignorado nas consultas e expirado na transação que precisa do recurso, antes da inserção |
| Confirmação de bloqueio | revalida alocações (ativo ainda alocável; pico do estoque ≤ capacidade) sob lock; ativo que deixou de ser alocável é substituído por outra unidade livre quando possível |
| Reserva com vários itens | todas as alocações na mesma transação: tudo ou nada |
| Reagendamento | libera e realoca na mesma transação; em conflito, a transação é desfeita e o período original permanece |
| Extensão | estende as alocações no lugar (mesmos ativos); se invadir outra reserva, é recusada informando o conflito |

Testes concorrentes usam conexões separadas e barreiras (`test/concurrency`), sem `sleep` como mecanismo.

## Bloqueios

- **Preparação:** pelos buffers do produto, aplicados automaticamente.
- **Manutenção/preparação programada:** alocações `kind = 'block'` para ativo ou quantidade de estoque.
- **Inspeção pós-devolução:** ativo em `in_inspection` ou bloqueio de estoque `[agora, ∞)` até a liberação.
- **Indisponibilidade operacional:** mudança de situação de ativo realoca reservas futuras para outra unidade
  livre; sem substituto, a operação é recusada informando as reservas afetadas.
