# Módulo: testes de navegador, observabilidade e demonstração de ponta a ponta

Cobre RNF-05 (logs estruturados correlacionados, métricas de baixa cardinalidade), a verificação no
navegador de RNF-04 (CSP, escape de conteúdo) e RNF-08 (teclado, foco visível, mensagens de erro) e a
demonstração do fluxo completo (RF-06 a RF-32 e RNF-02). Migration: `db/migrations/0012_observabilidade.sql`.

| Parte | Arquivos |
|---|---|
| Testes de navegador | `test/browser/browser_helper.rb`, `navigation_test.rb`, `customers_test.rb`, `reservations_test.rb`; job "Testes de navegador" em `.github/workflows/ci.yml` |
| Métricas | `infrastructure/observability/logger.rb` (`Metrics`), `interfaces/http/middleware.rb` (`RequestLogger`), `application/base.rb` (`UnitOfWork`), `application/reports.rb` (`CollectMetrics`), `infrastructure/jobs/queue.rb`, `infrastructure/persistence/reports.rb` |
| Chamadas externas e correlação | `application/external_calls.rb`, `application/finance/support.rb` (`Providers`, `TrackedProvider`), `application/webhooks.rb` (`Deliver`, `Redeliver`), `application/finance/{provider_flow,reconciliation,webhooks}.rb`, `infrastructure/notifications.rb`, `application/overdue.rb`, `interfaces/worker/handlers.rb` |
| Demonstração | `test/integration/demo_flow_test.rb`, `docs/DEMONSTRACAO.md`, `lib/locentra/seed.rb`, `test/integration/seed_test.rb` |
| Interface | `public/img/favicon.svg` e `<link rel="icon">` nos layouts |
| Composição | `System#build_services` (`external_calls`, `deliver_webhook`), `System#build_finance_use_cases` (`Providers` com registro), `UnitOfWork` com `metrics` |

## Testes de navegador

- **Servidor:** `InProcessServer` inicia `Puma::Server` no próprio processo de testes, em
  `127.0.0.1` e porta livre (porta 0), com a pilha Rack completa de `App.build` (estáticos, limite de
  corpo, cabeçalhos de segurança e CSP) sobre o `System` de teste (`TestDatabase`, papel
  `locentra_app`, RLS ativa). O logger do `System` grava em memória no nível `info`, o que permite
  contar as requisições recebidas pelo servidor.
- **Navegador:** um Chromium por processo (`BROWSER_PATH`; na imagem de desenvolvimento
  `/usr/bin/chromium`, na CI `/usr/bin/google-chrome`), headless, com `--no-sandbox` e
  `--disable-dev-shm-usage`. Cada teste usa um contexto novo do navegador (cookies isolados) e o
  descarta no fim.
- **Esperas:** `wait_until(descrição) { condição }` consulta a condição com prazo (10 s) e falha com a
  descrição. Navegações usam um marcador gravado no documento atual: a espera termina quando outro
  documento o substitui e termina de carregar. Não há pausa fixa como mecanismo de sincronização.
- **Cliques:** o elemento é rolado para a área visível antes do clique (o Ferrum clica por
  coordenadas).
- **Console e CSP:** um script registrado com `Page.addScriptToEvaluateOnNewDocument` transforma cada
  evento `securitypolicyviolation` em erro de console; o console do Ferrum também recebe as mensagens
  de segurança e de rede do próprio navegador. `assert_clean_console` exige zero violações de CSP e
  zero erros de console, aceitando apenas erros previstos pelo teste (por exemplo, o 422 de um
  formulário inválido, que o navegador registra como falha de carregamento do documento).
  `test_csp_violation_detector_catches_inline_scripts` injeta um script inline e prova que ele é
  bloqueado e detectado: sem esse controle, a ausência de violações não provaria nada.

| Teste | O que prova |
|---|---|
| `test_login_and_organization_selection` | Entrada, lista de organizações com papéis, escolha, troca pela barra superior e dados da organização ativa |
| `test_skip_link_moves_focus_to_content_and_focus_is_visible` | Primeiro Tab foca o atalho (que fica visível), Enter leva o foco a `#conteudo`, o próximo Tab permanece no conteúdo e o foco tem contorno visível |
| `test_pages_render_without_console_errors_or_csp_violations` | Catorze telas sem erro de console, sem violação de CSP e sem erro interno |
| `test_csp_violation_detector_catches_inline_scripts` | Controle do detector de CSP |
| `test_customer_registration_with_validation_feedback` | CPF inválido: resumo de erros recebe o foco, campo com `aria-invalid`, dados mantidos; cadastro válido gravado e mensagem fechada pelo botão |
| `test_malicious_content_is_displayed_as_text` | Nome e observações com `<img onerror>` e `<script>` aparecem como texto (inclusive no título), nenhum elemento é injetado e nada chega a ser bloqueado pela CSP |
| `test_new_reservation_uses_the_line_items_module` | Módulo de itens: nova linha vazia com quantidade 1, foco no produto, ids únicos e rótulos associados, remoção devolvendo o foco ao botão; reserva gravada com os dois itens |
| `test_held_reservation_is_confirmed_from_its_page` | Confirmação pelo botão, mensagem, situação e remoção da ação |
| `test_data_confirm_dialog_cancels_or_submits_the_form` | Diálogo com o texto de `data-confirm`; cancelar mantém a página e não envia nada ao servidor (o log do servidor tem um único POST); aceitar cancela a reserva |

O teste de navegador encontrou uma falha real: sem ícone declarado, o navegador pedia `/favicon.ico`
em toda página e registrava um 404 no console. O ícone SVG foi adicionado aos layouts.

Execução: `bundle exec rake test:browser` (a suíte fica fora de `test:all`; a CI a executa no job
próprio, com PostgreSQL 18.7 como serviço e o mesmo script de papéis).

## Métricas

Expostas em `GET /metrics` do processo web (formato texto 0.0.4, com `# HELP` e `# TYPE` por família;
`METRICS_TOKEN` exige `Authorization: Bearer`; em produção, sem `METRICS_TOKEN`, o endpoint responde 404).
Cada processo mantém o próprio registro; o que vem do banco é coletado a cada leitura, e
`locentra_metrics_collect_success` (0 ou 1) indica se a última coleta funcionou (a falha vai para o log
como `metrics.collect_failed`).

| Métrica | Tipo | Rótulos | Origem |
|---|---|---|---|
| `locentra_http_requests_total` | counter | `method`, `route`, `status` | Processo web (`RequestLogger`) |
| `locentra_http_request_duration_seconds` | histogram | `route` | Processo web |
| `locentra_db_pool_wait_seconds` | histogram | `pool` | Pool do processo |
| `locentra_db_pool_timeouts_total` | counter | `pool` | Pool do processo |
| `locentra_db_transaction_retries_total` | counter | `reason` | Coordenador de transações |
| `locentra_domain_conflicts_total` | counter | `code` | `UnitOfWork` (qualquer interface) |
| `locentra_external_calls_total` | counter | `provider`, `kind`, `outcome` | Processo que fez a chamada |
| `locentra_external_call_duration_seconds` | histogram | `provider`, `kind` | Processo que fez a chamada |
| `locentra_jobs_queue_size` | gauge | `queue`, `status` | `queue_stats` (worker) |
| `locentra_jobs_oldest_age_seconds` | gauge | `queue`, `status` | `queue_stats` (worker) |
| `locentra_jobs_queue_stats_age_seconds` | gauge | — | Idade da última atualização de `queue_stats` |
| `locentra_metrics_collect_success` | gauge | — | 1 se a coleta das métricas derivadas do banco funcionou na última leitura |
| `locentra_jobs_retries_total` | counter | `queue`, `kind` | `job_outcome_totals` (todos os workers) |
| `locentra_jobs_dead_total` | counter | `queue`, `kind` | `job_outcome_totals` (todos os workers) |

### Cardinalidade

- Rótulos fora de `Metrics::ALLOWED_LABELS` são descartados; valores com formato de UUID ou com 16 ou
  mais caracteres hexadecimais seguidos viram `redacted`; valores longos são truncados em 80
  caracteres. Assim, mesmo um erro de programação não transforma organização, cliente ou reserva em
  série temporal.
- `route` é a rota modelo (`/reservas/:id`), `unmatched` para caminhos sem rota e `static` para
  arquivos estáticos; `method` fora de GET, HEAD, POST, PUT, PATCH, DELETE e OPTIONS vira `OTHER`.
- `code` dos conflitos é o código fixo do erro de domínio (por exemplo `unavailable`, `hold_expired`,
  `early_pickup_unavailable`, `concurrent_update`, `idempotency_key_reused`, `duplicate:<constraint>`)
  ou `invalid_transition` para transições recusadas pela máquina de estados.

### Conflitos de disponibilidade

`domain_conflicts_total` era incrementado somente no tratamento central de erros do HTTP. A verificação
mostrou a lacuna: os formulários tratam `Domain::Unavailable` (criar, confirmar, reagendar e estender
reserva, orçamentos, aditivos) e respondem 409 sem passar por esse tratamento, e conflitos no worker
nunca eram contados. A contagem passou para `UnitOfWork#run`/`#anonymous`: todo `Domain::Conflict` que
encerra uma operação é contado uma vez, por código, em qualquer interface. O tratamento central deixou
de contar para não duplicar. Como ele contava toda resposta 409, a `UnitOfWork` também conta
`Domain::InvalidTransition` (código `invalid_transition`, por exemplo confirmar uma reserva cancelada
ou aceitar um contrato encerrado), que não herda de `Domain::Conflict`; assim nenhuma recusa contada
antes deixou de ser contada, e as tratadas pelos formulários passaram a ser. Conflitos resolvidos
dentro da própria transação (por exemplo, a troca de unidade após violação da exclusion constraint)
não são contados, pois não encerram a operação.

### Fila, retentativas e falhas permanentes

- `queue_stats` (migration 0006) continua sendo gravada pelo worker na rotina de manutenção (a cada
  60 s). Agora cada fila com tarefas em aberto, e sempre a fila `default`, recebe as três situações
  (`pending`, `running`, `dead`) com zero quando vazias, de modo que uma fila esvaziada aparece com
  tamanho zero em vez de manter o último valor; a idade considera só tarefas com `run_at` no passado
  (retentativas agendadas não inflam a espera) e nunca é negativa. A coleta substitui a família inteira
  de gauges e publica `jobs_queue_stats_age_seconds`: um worker parado aparece como idade crescente.
- Retentativas e falhas permanentes eram contadores na memória de cada worker, processo que não expõe
  HTTP. A tabela global `job_outcome_totals` (migration 0012) recebe `total + 1` por fila, tipo e
  desfecho (`retry`, `dead`) na **mesma transação** que reagenda ou encerra a tarefa, e somente quando a
  transição vale (lease atual): perda de lease não conta, e uma tarefa que esgota as tentativas conta
  como `dead`. O processo web lê a tabela e publica os totais com valor absoluto
  (`Metrics#set_counter`). Os contadores em memória do worker foram removidos.
- Rótulo da situação nos gauges da fila: `status` (antes era `kind`, que nas demais métricas significa
  o tipo da tarefa).

### Decisões deste módulo

- **`job_outcome_totals` é global, como `queue_stats`:** não tem organização, identificadores de tarefa,
  cliente ou reserva nem mensagens de erro (somente fila, tipo, desfecho, total e instante). A
  aplicação web tem apenas leitura (`INSERT`, `UPDATE` e `DELETE` revogados de `locentra_app`; `DELETE`
  revogado também de `locentra_worker`). `queue_stats` não comportava contadores monotônicos por tipo:
  é reconstruída a cada minuto (`DELETE` + `INSERT`) e não tem a coluna do tipo. Contar
  `job_attempts` a cada coleta exigiria varrer a tabela inteira, que cresce sem limite.
- **Contagem na transação da transição:** os totais ficam exatos e somados entre todos os workers, sem
  depender de cada processo publicar métricas. A disputa pela linha do total dura apenas a transação
  curta da conclusão da tarefa.

## Correlação de logs

O `request_id` (cabeçalho `X-Request-Id` com 8 a 64 caracteres `[A-Za-z0-9._-]`, ou um UUID gerado) é
devolvido em `x-request-id`, gravado no log `http.request` e levado pelo ator até a transação. Em
fluxos sem ator autenticado (cadastro e recuperação de senha), o controlador o informa ao caso de uso,
que o passa a `UnitOfWork#anonymous(request_id:)`; a transação expõe `Transaction#request_id` (o
informado ou o do ator), lido pela fila de e-mails e pela outbox. A partir dele:

```
requisição ── ator.request_id ──► audit_events.request_id
                                ├► outbox_events.correlation_id ─► events.dispatch ─► webhooks.deliver, email.send, finance.sync_reservation
                                └► jobs.correlation_id (payments.submit, payments.refund, payments.process_webhook, webhooks.deliver, e-mails)
worker: ator de sistema com request_id = correlation_id da tarefa
        ├► log job.finished (correlation_id)
        ├► log external.call (correlation_id) para provedor de pagamento e webhook enviado
        └► tarefas derivadas herdam o mesmo correlation_id (nova consulta, reenvio, nova consulta de estorno)
```

Lacunas encontradas e corrigidas:

| Caminho | Antes | Agora |
|---|---|---|
| Webhook do provedor pela rota pública `/webhooks/pagamentos/:conta_id` | `payments.process_webhook` sem correlação | request_id da requisição do provedor |
| Simulação de pagamento pela tela | sem correlação | request_id de quem simulou |
| Reenvio manual de webhook | sem correlação | request_id de quem pediu o reenvio |
| Nova consulta e reenvio de pagamento (`ResolveSubmission`, `SubmitPayment`) | sem correlação | correlação da operação de origem |
| Nova consulta de estorno (`ProcessRefund`) | sem correlação | correlação da operação de origem |
| Convites e e-mails genéricos (`JobNotifier`) | sem correlação | request_id do ator da transação |
| E-mails de confirmação de cadastro e de recuperação de senha (fluxos sem ator) | sem correlação | request_id da requisição, informado à `UnitOfWork#anonymous`; a auditoria `organization.created` também o registra |
| Aviso de atraso (`DetectOverdue`) | sem correlação | correlação da rotina que o gerou |
| Chamadas ao provedor de pagamento e entrega de webhook | sem log | `external.call` com serviço, operação, desfecho, duração, organização e correlação |

`external.call` (nível `info` quando o desfecho é `ok`, `warn` nos demais) traz `service`
(`simulator`, `asaas` ou `webhook`), `operation` (`create_charge`, `find_by_external_reference`,
`list_charges`, `refunds`, `refund`, `deliver`), `outcome` (`ok`, `timeout`, `rejected`,
`unavailable`, `blocked`, `http_3xx`/`http_4xx`/`http_5xx`, `error`), `duration_ms`, `organization_id`,
`correlation_id` e referências do registro (pagamento, entrega ou evento) somente no log. A interpretação
de webhooks recebidos é local e não gera `external.call`.

## Demonstração

`test/integration/demo_flow_test.rb` executa, num único teste, os 14 passos de `docs/DEMONSTRACAO.md`:
entrada e escolha da organização pela interface web; cliente, catálogo, ativos e estoque;
disponibilidade; orçamento enviado, aprovado e convertido (conversão repetida devolve a mesma
reserva); duas threads disputando a última câmera (uma vence, a outra recebe `Unavailable`) e a
confirmação de uma solicitação incompatível recusada; contrato com PDF; caução recebida e retirada;
devolução parcial com avaria; tripé encaminhado para inspeção, avaria cobrada com evidência,
inspeções aprovada e reprovada (ordem de manutenção); devolução final, caução aplicada e devolvida;
pagamento pelo simulador confirmado pelo worker; pagamento repetido pela API com a mesma
`Idempotency-Key` (um único registro, conteúdo diferente recusado com 409); e, na organização B,
404 na tela, a API da credencial da Alfa listando somente clientes da Alfa (e 404 para o cliente da
Beta), `NotFound` nos casos de uso e nenhuma linha da organização A pela RLS. A credencial do teste
tem os mesmos escopos do roteiro manual (`finance.read`, `finance.write` e `customers.read`), de modo
que um passo do documento que dependa de outro escopo falha no teste.

O seed ganhou o preparo da demonstração manual, idempotente também em bancos semeados antes:
`ana@alfa.demo` passa a ser gerente da Beta Eventos e a Alfa recebe a conta ativa do simulador. O
preparo não é destrutivo: cada item só é criado quando nunca existiu. Qualquer vínculo da Ana com a
Beta (ativo ou revogado) e qualquer conta de provedor da Alfa (ativa ou desativada) encerram o
preparo. Isso importa porque configurar uma conta desativa a anterior: repetir o seed, por exemplo
pelo `bin/setup`, não pode trocar o Asaas configurado pelo desenvolvedor pelo simulador. O resumo
devolvido pelo seed continua com as duas organizações (o job "Reconstrução do banco e seed" segue
esperando duas linhas `skipped`).

## Testes

| Arquivo | O que prova |
|---|---|
| `test/unit/infrastructure/metrics_test.rb` | HELP/TYPE únicos por família, formato das amostras, histogramas cumulativos, descarte de rótulos, redação de identificadores, escape e truncamento, totais absolutos, substituição de famílias, método `OTHER` e request_id no middleware |
| `test/unit/application/observability_test.rb` | `ExternalCalls` (sucesso, desfecho classificado, erro mapeado e propagado), provedores com e sem ator, conflitos e transições inválidas contados pela `UnitOfWork` (inclusive `anonymous` e conflito do coordenador), `CollectMetrics` com agregados da fila e totais |
| `test/http/observability_test.rb` | Correlação de ponta a ponta (eventos, auditoria, tarefas, `job.finished`, `external.call` do webhook e do simulador, simulação, webhook público e e-mails do cadastro e da recuperação de senha); `/metrics` válido no formato do Prometheus com todos os sinais (inclusive conflito e transição inválida tratados por formulário, retentativa e falha permanente agregadas) e nenhum rótulo com UUID ou identificador do tenant; token de métricas |
| `test/repository/observability_tables_test.rb` | Colunas e privilégios de `queue_stats` e `job_outcome_totals`; `retry_later` e `kill` com lease perdido não somam; `retry_later` na última tentativa soma uma linha `dead` e nenhuma `retry` |
| `test/integration/demo_flow_test.rb` | Roteiro completo |
| `test/integration/seed_test.rb` | Seed idempotente, preparo completado em banco semeado antes e, ao repetir o seed, conta Asaas, conta desativada e vínculo revogado mantidos |
| `test/browser/*` | Tabela da seção de testes de navegador |

## Limitações

- O worker não expõe HTTP: `job_duration_seconds` e `external_calls_total`/`external_call_duration_seconds`
  das chamadas feitas no worker (envio de cobrança, estornos, conciliação agendada, entrega de webhooks)
  ficam apenas no registro do processo do worker; essas chamadas são rastreáveis pelos logs
  `external.call`. No processo web aparecem as chamadas feitas por ele (conciliação manual).
- Com vários processos Puma (`WEB_CONCURRENCY` > 0), cada processo tem o próprio registro e todos
  compartilham a porta: cada coleta de `/metrics` é atendida por um processo arbitrário, sem rótulo de
  processo, e o coletor não consegue separar nem somar as séries (a alternância entre registros aparece como
  reinício de contador). Nesta versão, as métricas HTTP só são confiáveis com `WEB_CONCURRENCY=0`. Os valores
  vindos do banco (fila, retentativas e falhas) são iguais em todos os processos.
- Tarefas agendadas (`platform.fanout`, `organization.tick`, conciliação horária) não têm requisição
  de origem e ficam sem `correlation_id`; o log `job.finished` traz o `job_id`.
- A entrega de webhook não envia o request_id de origem ao destinatário (somente identificadores do
  evento e da entrega, já existentes).
- A disputa simultânea pela última unidade na demonstração manual é feita em sequência; a disputa
  realmente concorrente é provada pelo teste de demonstração e pela suíte `test/concurrency`.
