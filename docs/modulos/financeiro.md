# Módulo financeiro: cobranças, pagamentos, reembolsos, cauções e provedores de pagamento

Cobre RF-28 a RF-32 e a parte financeira de RF-15 (pagamento após expiração não reativa a reserva) e
RF-39 (API com idempotência). Depende apenas de `reservations`, `reservation_adjustments` e
`customers`; não usa tabelas de contratos nem de operação.

## Camadas

| Camada | Arquivos |
|---|---|
| Domínio | `lib/locentra/domain/finance/{receivables,payments,deposits,journal,reconciliation}.rb` |
| Aplicação | `lib/locentra/application/finance/*.rb` (casos de uso, porta de provedores, serviços de liquidação) |
| Persistência | `lib/locentra/infrastructure/persistence/{receivables,payments,deposits,finance_records,payment_accounts}.rb` |
| Provedores | `lib/locentra/infrastructure/payments/{simulator,asaas,asaas_format}.rb` |
| Interfaces | `interfaces/http/web/finance_controllers.rb`, `interfaces/http/api/v1_finance.rb`, `interfaces/worker/finance_handlers.rb`, `views/finance/` |
| Migration | `db/migrations/0010_financeiro.sql` |

Composição em `System#build_finance_use_cases`; rotas em `Routes.draw_finance`; tarefas do worker em
`Worker::FinanceHandlers` (registradas em `Handlers`).

## Modelo de dados

Todas as tabelas têm `organization_id NOT NULL`, `UNIQUE (organization_id, id)`, chaves estrangeiras
compostas para tabelas do mesmo tenant e RLS habilitada e forçada (`app_enable_tenant_rls`).

| Tabela | Conteúdo | Imutabilidade |
|---|---|---|
| `payment_provider_accounts` | Conta do provedor por organização (uma ativa): provedor, ambiente, chave de API cifrada (SecretBox, AES-256-GCM), SHA-256 do token dos webhooks | DELETE revogado |
| `receivables` | Contas a receber: tipo, reserva, cliente, origem única `(source_type, source_id)`, valor, vencimento | trigger recusa UPDATE; DELETE revogado |
| `receivable_cancellations` | Cancelamento compensatório (um por cobrança, com motivo) | somente inserção |
| `payments` | Pagamentos parciais: finalidade (cobrança ou caução), método, provedor, situação, referência externa (= id), identificador no provedor, revisão | trigger recusa UPDATE de pagamento confirmado, falho ou cancelado e de dados de origem; DELETE revogado |
| `refunds` | Reembolsos de pagamentos de cobrança | trigger recusa UPDATE após conclusão; trigger de INSERT bloqueia o pagamento e limita a soma |
| `deposits` | Caução da reserva (uma por reserva), tipo e valor previsto | trigger recusa UPDATE; DELETE revogado |
| `deposit_entries` | Movimentos de caução: recebimento (por pagamento), aplicação a cobrança, devolução | somente inserção; trigger limita saídas ao saldo |
| `financial_entries` | Diário de partidas dobradas | somente inserção; constraint trigger diferida exige débito = crédito por transação no COMMIT |
| `finance_alerts` | Alertas para decisão humana, deduplicados por chave | DELETE revogado |
| `payment_simulator_charges` | Lado do provedor do simulador local | — |
| `reconciliation_reports`, `reconciliation_items` | Relatório e divergências de cada conciliação | itens somente inserção |
| `invoices` | Faturas comerciais numeradas (`FAT-000001`), retrato das cobranças | somente inserção |

`inbound_webhooks` (migration 0007) guarda os eventos recebidos, únicos por
`(organization_id, provider, event_id)`.

O webhook público chega sem tenant. A política `webhook_account_lookup` permite ler somente a conta
cujo id foi definido em `app.payment_account_id` na transação; após verificar o token, a transação
passa a usar o tenant da conta (`switch_tenant!`).

## Saldos derivados

Nenhum saldo é armazenado. Para uma cobrança:

```
saldo = valor − cancelado − pagamentos confirmados + reembolsos (pendentes e confirmados) − caução aplicada
```

Situação derivada (domínio `Finance::Balance#status`, reproduzida no SQL de listagem): `cancelled`
(há cancelamento), `credit` (saldo negativo: o cliente tem crédito a reembolsar), `paid` (zero),
`partial` (algo recebido) e `open`.

Caução: `saldo = recebido − aplicado − devolvido`; situação `awaiting`, `held` ou `settled`.

## Máquinas de estado

Pagamento (`Domain::Finance::PAYMENT_TRANSITIONS`):

```
pending_submission → pending | submission_unknown | confirmed | failed | cancelled
submission_unknown → pending_submission | pending | confirmed | cancelled
pending            → confirmed | failed | cancelled
confirmed, failed, cancelled: finais (imutáveis)
```

- Pagamentos manuais nascem `confirmed` (provedor `manual`).
- `pending_submission → confirmed` cobre o webhook que chega antes da resposta do envio.
- `submission_unknown` só muda após consulta ao provedor pela referência externa.

Reembolso: `pending → confirmed | failed`. Reembolso de pagamento manual é confirmado na hora;
de pagamento de provedor fica pendente até a tarefa `payments.refund`.

## Regras

- **Sincronização de cobranças** (`SyncReservationCharges`): cria a cobrança de locação (total da
  reserva confirmada, em andamento ou concluída) e uma cobrança por `reservation_adjustment` com valor
  positivo (`extension`, `late_fee`, `damage`, `missing`, `cancellation_fee`; `amendment` vira `other`).
  `INSERT ... ON CONFLICT DO NOTHING` na origem única torna a operação idempotente. Bloqueio temporário
  só é cobrado com pedido explícito de cobrança antecipada (botão "Emitir cobrança antecipada").
  Reserva cancelada ou expirada com saldo em aberto gera o alerta `reservation_closed_with_charges`.
- **Acionamento automático**: `Webhooks::DispatchEvent` aceita assinantes (`subscribers:`); o assinante
  financeiro enfileira `finance.sync_reservation` para eventos `reservation.*`, na mesma transação que
  marca o evento como despachado. A sincronização também está disponível por botão.
- **Cancelamento** só por operação compensatória: registro em `receivable_cancellations` e estorno da
  receita no diário. Valores já pagos passam a ser crédito do cliente.
- **Pagamento manual**: valor até o saldo em aberto (cobrança) ou até o restante previsto (caução);
  data de recebimento não pode estar no futuro.
- **Pagamento após expiração ou cancelamento**: o dinheiro é confirmado, o pagamento recebe
  `requires_review` com motivo e é criado o alerta `payment_after_expiration` ou
  `payment_after_cancellation`. A reserva nunca é alterada; a decisão (reembolso, nova reserva, sem
  ação) é registrada no alerta. Valor divergente informado pelo provedor também gera revisão.
- **Reembolsos**: o pagamento é bloqueado (`FOR UPDATE`) antes de somar reembolsos pendentes e
  confirmados; a soma nunca excede o valor confirmado (`409 refund_exceeds_eligible`). O trigger
  `refunds_within_payment` repete a verificação com lock no banco. Cauções não são reembolsadas por
  esse caminho: são devolvidas pela própria caução.
- **Cauções**: `paid_deposit` implementado. `card_preauthorization` está modelado (tipo no banco e no
  domínio), mas é recusado com mensagem clara: o provedor exige tokenização do cartão e o produto não
  armazena número do cartão (PAN) nem CVV. Recebimento por pagamento com finalidade caução (manual ou
  provedor), aplicação a cobrança da mesma reserva (até o saldo da caução e o saldo da cobrança) e
  devolução do saldo (Pix, transferência ou dinheiro).
- **Cartão** em provedor usa a página de pagamento do provedor; o Locentra nunca recebe dados do cartão.

## Diário contábil

Contas: `receivable`, `rental_revenue`, `additional_revenue`, `cash`, `deposit_liability`,
`refunds_payable`. Cada operação gera uma transação contábil balanceada:

| Operação | Débito | Crédito |
|---|---|---|
| Cobrança de locação ou extensão | receivable | rental_revenue |
| Cobrança adicional (multa, avaria, falta, outros) | receivable | additional_revenue |
| Cancelamento compensatório | receita de origem | receivable |
| Pagamento de cobrança confirmado | cash | receivable |
| Caução recebida | cash | deposit_liability |
| Reembolso solicitado / confirmado / recusado | receivable / refunds_payable / refunds_payable | refunds_payable / cash / receivable |
| Caução aplicada a cobrança | deposit_liability | receivable |
| Caução devolvida | deposit_liability | cash |

A caução nunca toca contas de receita: a receita de uma avaria é reconhecida na emissão da cobrança, e
a aplicação da caução apenas quita o recebível.

## Provedores de pagamento

Porta (`Application::Finance`, comentário em `support.rb`): `create_charge`,
`find_by_external_reference`, `list_charges`, `refunds`, `refund`, `parse_webhook`. Erros:
`ProviderTimeout` (resultado desconhecido), `ProviderRejected` (recusa definitiva),
`ProviderUnavailable` (não enviado; pode repetir).

**Simulador** (`Infrastructure::Payments::Simulator`): persistido em `payment_simulator_charges`,
determinístico pelo cenário da cobrança:

- `success`: registra a cobrança pendente;
- `fail`: recusa sem registrar;
- `timeout_after_success`: registra a cobrança e lança tempo esgotado.

Não há unicidade por referência externa (como num provedor real), de modo que um reenvio às cegas
criaria uma segunda cobrança. "Simular confirmação" marca a cobrança como recebida e emite um evento no
formato do Asaas, com identificador estável, ingerido pelo mesmo caminho de um webhook real.

**Asaas** (`Infrastructure::Payments::Asaas`), conforme a documentação oficial (docs.asaas.com,
consultada durante o desenvolvimento):

- URL base: sandbox `https://api-sandbox.asaas.com/v3` (configurável por `ASAAS_BASE_URL`), produção
  `https://api.asaas.com/v3`, escolhida pelo ambiente da conta;
- autenticação pelo cabeçalho `access_token`; `User-Agent` obrigatório; `Content-Type: application/json`
  nas requisições com corpo; chaves de sandbox com prefixo `$aact_hmlg_` e de produção `$aact_prod_`
  (validadas na configuração);
- cliente localizado por `GET /customers?externalReference=` e criado por `POST /customers`
  (`name`, `cpfCnpj`, `externalReference`);
- `POST /payments` com `customer`, `billingType` (`PIX`, `BOLETO`, `CREDIT_CARD`), `value`, `dueDate`,
  `description` e `externalReference` (id do pagamento);
- `GET /payments?externalReference=` para localizar a cobrança depois de tempo esgotado;
  `GET /payments?dateCreated[ge]=` paginado (`limit`/`offset`/`hasMore`) para a conciliação;
- `POST /payments/{id}/refund` com `value` e `description`; `GET /payments/{id}` para ler `refunds`;
- webhooks com o token no cabeçalho `asaas-access-token` e `id` do evento para deduplicação; eventos
  `PAYMENT_CONFIRMED`/`PAYMENT_RECEIVED` confirmam, `PAYMENT_DELETED` cancela, demais são informativos.

Valores decimais são escritos como número exato (`150.50`) e lidos como `BigDecimal`; nenhum Float.
Erros 5xx em POST são tratados como resultado desconhecido.

**A integração real com o Asaas não foi exercitada**: os testes usam cliente HTTP falso, sem
credenciais reais (`test/unit/infrastructure/asaas_adapter_test.rb`).

## Submissão e resolução sem cobrança duplicada

1. `RequestPayment` grava o pagamento `pending_submission` e enfileira `payments.submit`.
2. O worker (`SubmitPayment`) prepara em transação curta, chama o provedor sem transação aberta e
   registra o resultado em nova transação curta.
3. Tempo esgotado → `submission_unknown` e nova tarefa `payments.submit` em 60 s. Nessa tarefa (ou na
   conciliação), `ResolveSubmission` consulta o provedor pela referência externa **antes de qualquer
   nova tentativa**: encontrada, a situação remota é adotada; ausente, o pagamento volta a
   `pending_submission` e é reenviado com a mesma referência. Várias cobranças com a mesma referência
   geram o alerta `duplicate_provider_charge`.
4. Conexão não estabelecida (`ProviderUnavailable`) mantém o pagamento aguardando envio e a fila
   reagenda a tarefa.

Reembolsos de provedor seguem o mesmo princípio: antes de pedir o estorno, os reembolsos já
registrados no provedor são procurados pela descrição estável `Locentra reembolso <id>`.

## Webhooks recebidos

`POST /webhooks/pagamentos/:conta_id` (público, sem CSRF): o token do cabeçalho `asaas-access-token` é
comparado em tempo constante com o SHA-256 armazenado; conta inexistente ou inativa resulta em `401`
sem distinção. O evento é persistido em `inbound_webhooks` antes do processamento e a resposta é
`200 {"status":"accepted"}` ou `{"status":"duplicate"}`. A tarefa `payments.process_webhook` bloqueia o
registro e só o trata enquanto `received`; confirmar pagamento já confirmado não tem efeito.

## Conciliação

`Reconcile` compara os pagamentos locais da conta ativa (últimos 30 dias) com as cobranças do provedor
e grava o relatório: `missing_remote`, `missing_local`, `status_mismatch`, `amount_mismatch`,
`duplicate_remote`. Correções seguras são aplicadas no ato (envio sem confirmação encontrado ou
ausente, pagamento confirmado no provedor e pendente no Locentra); as demais ficam para revisão.
Executada pelo botão "Conciliar agora" e a cada hora por organização (tarefa `finance.reconcile`
agendada pelo `organization.tick` com chave única por hora).

## Faturas comerciais

`IssueInvoice` emite um demonstrativo numerado e imutável das cobranças ativas da reserva, com valores
recebidos e saldo no momento da emissão. **Não é documento fiscal: a emissão de NFS-e está fora do
escopo.**

## Interface e API

- `/financeiro` (permissão `finance.read`; item "Financeiro" na navegação): resumo, alertas, cobranças
  com saldos e filtro, pagamentos, cauções retidas, conciliação e saldos do diário.
- Telas de cobrança, pagamento (reembolso, simulação), caução, fatura, relatório de conciliação e
  provedor (`integrations.manage`); painel financeiro na tela da reserva.
- API v1 com `Idempotency-Key` (`docs/openapi.yaml`): `POST /api/v1/payments` (registro manual),
  `GET /api/v1/payments/{id}`, `POST /api/v1/payments/{id}/refunds`.

Permissões existentes: `finance.read`, `finance.write`, `finance.refund`, `deposits.manage`,
`integrations.manage` (conta do provedor). A conta de provedor exige a funcionalidade
`pagamentos_online` do plano.

## Decisões

- Saldos derivados, nunca armazenados: correções são novos registros, e o saldo reflete todos eles.
- Imutabilidade por trigger nas tabelas que precisam de `SELECT ... FOR UPDATE` (o PostgreSQL exige
  privilégio de UPDATE para bloquear linhas) e por revogação de UPDATE/DELETE nas demais.
- Verificações críticas em duas camadas: domínio/aplicação (mensagens claras) e banco (triggers com lock
  e balanceamento no COMMIT).
- Referência externa igual ao id do pagamento: estável entre tentativas, reenvios e conciliação.
- Alertas financeiros em tabela própria (`finance_alerts`), independente de outros módulos.

## Limitações

- Integração real com o Asaas não exercitada (somente cliente HTTP falso); split, assinaturas,
  parcelamento, antecipação e chargeback não são tratados além do mapeamento de situação.
- Pré-autorização em cartão recusada por exigir tokenização (sem armazenamento de PAN/CVV).
- Devolução de caução é registrada como saída manual (Pix, transferência ou dinheiro), sem estorno no
  provedor.
- Cancelamento de cobrança é sempre integral; descontos parciais usam reembolso ou nova cobrança.
- Cobranças pendentes no provedor não reservam saldo: se duas cobranças da mesma conta forem pagas, o
  excedente aparece como "Crédito do cliente" (ou caução acima do previsto) e deve ser reembolsado.
- A conciliação considera os últimos 30 dias e apenas a conta ativa; cobranças remotas criadas fora do
  Locentra aparecem como `missing_local`.
- Webhooks recebidos não têm limitação de taxa própria além do limite de corpo da aplicação.
- NFS-e fora do escopo.

## Como testar

```bash
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/unit/domain/finance_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/unit/infrastructure/asaas_adapter_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/finance_flow_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/payment_provider_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/concurrency/refund_race_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/http/finance_pages_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/http/finance_api_test.rb
```

Fluxo manual com o simulador: em "Financeiro → Provedor de pagamentos", configure o simulador local;
numa reserva confirmada, sincronize as cobranças, abra a cobrança e escolha "Cobrar pelo provedor" com
o cenário desejado; com o worker em execução (`bin/worker`), use "Simular confirmação pelo provedor" na
tela do pagamento ou "Conciliar agora" na tela do financeiro.

| Caso obrigatório | Teste |
|---|---|
| Caução e reembolso | `test_deposit_is_received_applied_to_damage_and_returned_without_touching_revenue`, `test_refunds_respect_the_confirmed_amount_and_reopen_the_balance` |
| Reembolsos concorrentes acima do saldo | `RefundRaceTest` (Barrier e PausingProxy; inclui a verificação do trigger) |
| Tempo esgotado após sucesso sem segunda cobrança | `test_timeout_after_success_is_resolved_without_a_second_charge`, `test_reconciliation_resolves_unknown_submission_before_any_retry` |
| Webhook repetido | `test_repeated_webhooks_do_not_duplicate_effects`, `test_public_webhook_endpoint_authenticates_and_deduplicates` |
| Pagamento após expiração não reativa | `test_payment_after_hold_expiration_does_not_reactivate_reservation` |
| Imutabilidade | `test_confirmed_and_financial_records_are_immutable_in_the_database` |
| Diário balanceado | `test_property_journal_stays_balanced_and_consistent` (propriedade), `test_unbalanced_journal_transaction_is_rejected_at_commit` |
| Isolamento entre organizações | `test_organizations_are_isolated`, `FinanceApiTest#test_scopes_and_tenant_isolation` |
| Idempotência da API | `FinanceApiTest` |
| Telas renderizam | `FinancePagesTest#test_every_finance_page_renders_with_real_data` (Rack::Lint) |
