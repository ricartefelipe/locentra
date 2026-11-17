# Módulo de orçamentos e contratos

Requisitos atendidos: RF-18 (snapshots de preço e condições), RF-19 (orçamentos versionados),
RF-20 (conversão idempotente e política de bloqueio explícita) e RF-21 (contratos com documentos
versionados, aditivos, cancelamento com política explícita e aceite eletrônico simples).

| Camada | Arquivos |
|---|---|
| Migration | `db/migrations/0008_orcamentos_contratos.sql` |
| Domínio | `lib/locentra/domain/quotes.rb`, `lib/locentra/domain/contracts.rb` |
| Aplicação | `lib/locentra/application/quotes.rb`, `lib/locentra/application/contracts.rb` (e ajustes em `reservations.rb` e `notifications.rb`) |
| Persistência | `lib/locentra/infrastructure/persistence/quotes.rb`, `contracts.rb` (e `find_by_quote`/`link_quote` em `reservations.rb`) |
| Documento | `lib/locentra/infrastructure/documents/contract_pdf.rb` (Prawn) |
| Interface | `web/quotes_controller.rb`, `web/contracts_controller.rb`, `views/quotes/`, `views/contracts/`, `views/mailer/quote_sent`, `views/mailer/contract_issued` |
| Composição | `System#build_quote_use_cases`, `System#build_contract_use_cases` |

## Modelo de dados

Todas as tabelas têm `organization_id NOT NULL`, `UNIQUE (organization_id, id)`, chaves estrangeiras
compostas para tabelas do mesmo tenant e RLS forçada (`app_enable_tenant_rls`).

| Tabela | Conteúdo | Proteções |
|---|---|---|
| `quotes` | Código `Q-000001`, cliente, filial, situação, `current_version`, `approved_version`, `hold_policy`, `hold_minutes`, `hold_reservation_id` (bloqueio do envio), `reservation_id` (conversão), dados de aprovação (tipo, usuário, nome, IP, instante), rejeição e expiração, `lock_version` | CHECKs de coerência (aprovado ⇔ versão/instante/tipo de aprovação; convertido ⇔ reserva); `DELETE` revogado |
| `quote_versions` | Número da versão, filial, período `[início, fim)`, `valid_until`, itens precificados (`items`), resumo de preços (`pricing`), condições (`terms`), desconto manual, caução e total | Somente inserção (`UPDATE`/`DELETE` revogados) |
| `reservations` (alteração) | FK composta `(organization_id, quote_id)` para `quotes` e índice único parcial `reservations_quote_key (organization_id, quote_id) WHERE quote_id IS NOT NULL` | No máximo uma reserva por orçamento |
| `contracts` | Código `C-000001`, `reservation_id` único, cliente, orçamento de origem, situação, `terms_snapshot`, `current_document_version`, instantes de emissão, vigência, encerramento e cancelamento, motivo e multa | Trigger `contracts_protect_terms`: termos, partes, reserva, emissão e número definitivo imutáveis; contrato encerrado ou cancelado não muda; `DELETE` revogado |
| `contract_documents` | Versão, motivo (`issue`/`amendment`), `attachment_id` (FK composta para `attachments`), `sha256`, `data_snapshot`, `generated_at` e campos de aceite: `accepted_at`, `accepted_by_name`, `accepted_by_document`, `accepted_ip`, `user_agent`, `accepted_via`, `accepted_by_user_id`, `acceptance_statement` | Trigger `contract_documents_immutable`: somente os campos de aceite podem ser preenchidos, uma única vez; `DELETE` revogado |
| `contract_amendments` | Número sequencial por contrato, tipo (`extension`), descrição, `changes` (jsonb), `amount_delta_cents`, versão do documento gerada (FK para `contract_documents`) | Somente inserção |

Os PDFs ficam em `attachments` com `owner_type = 'contract'` e retenção de 1826 dias (cerca de cinco
anos): a remoção é recusada durante a retenção.

## Máquinas de estado

Orçamento (`Domain::Quotes::TRANSITIONS`):

| De | Para |
|---|---|
| `draft` (rascunho) | `sent` |
| `sent` (enviado) | `approved`, `rejected`, `expired`, `draft` (nova versão) |
| `approved` (aprovado) | `converted` |
| `rejected` (rejeitado) | `draft` (nova versão) |
| `expired` (expirado) | `draft` (nova versão) |
| `converted` (convertido) | — |

Contrato (`Domain::Contracts::TRANSITIONS`):

| De | Para |
|---|---|
| `issued` (emitido, aguardando aceite) | `active` (primeiro aceite), `cancelled` |
| `active` (vigente) | `closed` (após a conclusão da reserva), `cancelled` |
| `closed`, `cancelled` | — |

## Regras

### Versões e validade

- Toda alteração cria uma versão nova e imutável (`ReviseQuote`); a revisão sem nenhuma diferença
  (filial, período, validade, itens, totais, condições, desconto e política de bloqueio) é recusada.
- Revisar um orçamento enviado o devolve a rascunho e exige novo envio; o bloqueio temporário do envio
  anterior é cancelado. Orçamentos aprovados ou convertidos não aceitam nova versão.
- A validade (`valid_until`) é obrigatória, futura, de no máximo 90 dias e termina até o início da
  locação. O instante final pertence ao período vencido (`now >= valid_until` é expirado).
- Preços de cada versão são calculados pelo `Application::Reservations::Pricer` com `redeem: false`
  (tabela vigente, faixas por quantidade, condição negociada do cliente e desconto manual limitado
  pelo papel). Cupons não se aplicam a orçamentos.

### Política de bloqueio

- `none` (padrão): o orçamento enviado **não garante disponibilidade**. A tela, a lista e o e-mail dizem
  isso; a disponibilidade é verificada somente na conversão, e a falta gera erro explícito ("o
  orçamento enviado não garantia disponibilidade").
- `hold_on_send`: o envio cria, na mesma transação, uma reserva em bloqueio temporário (5 a 1440
  minutos) com o snapshot de preços da versão enviada, vinculada por `quotes.hold_reservation_id`. Sem
  disponibilidade, o envio é recusado e o orçamento continua em rascunho. Nova versão, rejeição e
  expiração cancelam o bloqueio ainda ativo.

### Aprovação

- Vale somente para a versão atual de um orçamento enviado e dentro da validade. Versão diferente da
  atual gera `Conflict` `stale_quote_version`; orçamento não enviado, `InvalidTransition`; validade
  vencida marca o orçamento como expirado (gravado mesmo com a recusa) e gera `Conflict`
  `quote_expired`.
- Registra tipo (`staff`, equipe em nome do cliente, com o nome de quem aprovou; ou `customer`, o
  próprio cliente), usuário, nome, IP da requisição e instante. O caso de uso aceita ator `customer`
  com a permissão `portal.access`, restrito ao próprio `customer_id` (outro cliente recebe "não
  encontrado"). A rejeição segue a mesma regra de ator.

### Conversão idempotente

1. O orçamento é bloqueado (`SELECT ... FOR UPDATE`): conversões concorrentes são serializadas e a
   segunda encontra `quotes.reservation_id` preenchido e devolve a mesma reserva (`created: false`).
2. Se duas conversões passarem pela leitura ao mesmo tempo, o índice único parcial de `reservations`
   rejeita a segunda inserção; a criação roda sob savepoint, a tentativa é desfeita e a reserva já
   gravada é devolvida.
3. Com bloqueio temporário vigente, a própria reserva bloqueada é confirmada (com revalidação) e
   vinculada ao orçamento. Sem bloqueio vigente, uma reserva confirmada é criada com
   `source = 'quote'`.
4. `CreateReservation` aceita `pricing_snapshot: { items:, summary: }`: a reserva usa os itens e o resumo
   de preços da versão aprovada (inclusive após mudança de preço no catálogo), desde que itens e
   período coincidam exatamente com o snapshot.

### Contratos

- `IssueContract` exige reserva confirmada (ou em andamento) e é idempotente: a reserva é bloqueada e,
  se já houver contrato, ele é devolvido; `UNIQUE (reservation_id)` garante no banco.
- `terms_snapshot` congela organização, cliente (documento, contato, endereço), filial, reserva,
  orçamento de origem, período em UTC e no fuso da organização, itens e preços, ajustes anteriores,
  total contratado, caução, política de cancelamento vigente (com descrição das faixas) e condições
  (informadas na emissão ou as da versão aprovada do orçamento).
- O número definitivo é atribuído pelo contador da organização no fim da transação, antes da geração
  do documento que o exibe.
- Cada documento é um PDF gerado com Prawn a partir de `data_snapshot` (termos, aditivos, período e
  total vigentes) e gravado por `Application::Attachments::Upload` (`tx:`), que registra o SHA-256.
  O PDF e as telas informam que o aceite é **aceite eletrônico simples** e que não equivale a
  assinatura digital certificada.
- Aceite (`AcceptContract`): declaração obrigatória, nome, CPF ou CNPJ válido, IP, navegador e instante;
  vale para a versão atual do documento e é gravado uma única vez. O primeiro aceite torna o contrato
  vigente. O caso de uso aceita ator `customer` restrito ao próprio cadastro.

### Aditivos e alterações da reserva

- `AmendContract` (extensão de prazo) compõe `ExtendReservation` na mesma transação (`tx:`): as
  alocações são estendidas, a diferença é gravada em `reservation_adjustments` (kind `extension`) com a
  tabela contratada, o aditivo registra `amount_delta_cents` e uma nova versão do PDF é gerada.
- Extensão que invade outra reserva gera `Unavailable` com a reserva conflitante e desfaz tudo: nenhum
  aditivo, ajuste, documento ou anexo é gravado.
- Com contrato em aberto, `RescheduleReservation`, `ExtendReservation` e `CancelReservation` chamados
  diretamente são recusados (`Conflict` `contract_amendment_required`) com mensagem para usar o
  aditivo ou o cancelamento do contrato (`Contracts::ReservationGuard`). A composição com `tx:` pelos
  casos de uso de contrato não passa por essa verificação.

### Cancelamento

- Multa = total contratado vigente (total da emissão + diferenças dos aditivos) × percentual da faixa da
  política congelada no contrato, escolhida pela antecedência em relação ao início
  (`Domain::Organizations::CancellationPolicy.fee_bps`). Padrão: 72 h ou mais → 0%; de 24 h a menos de
  72 h → 30%; menos de 24 h ou após o início → 100%.
- `CancelContract` grava `reservation_adjustments` kind `cancellation_fee` quando a multa é positiva,
  cancela a reserva (`CancelReservation` com `tx:`, liberando alocações), marca o contrato como
  cancelado com motivo e multa, audita e publica `contract.cancelled`. A tela mostra a prévia
  (`PreviewCancellation`) e a multa é recalculada no instante da confirmação.
- `CloseContract` encerra o contrato vigente somente quando a reserva está concluída.

## Permissões

| Operação | Permissão |
|---|---|
| Ler orçamentos / contratos | `quotes.read` / `contracts.read` |
| Criar, revisar, enviar, aprovar e rejeitar orçamento | `quotes.write` (cliente: `portal.access` para aprovar/rejeitar os próprios) |
| Enviar com bloqueio e converter | `quotes.write` + `reservations.write` |
| Emitir contrato, registrar aceite, encerrar | `contracts.write` (cliente: `portal.access` para o aceite do próprio contrato) |
| Aditivo de extensão | `contracts.write` + `reservations.write` |
| Cancelar contrato | `contracts.write` + `reservations.cancel` |

Nenhuma chave nova foi adicionada à matriz de permissões.

## Eventos, e-mails e worker

- Eventos na outbox (também disponíveis para webhooks): `quote.sent`, `quote.approved`, `quote.rejected`,
  `quote.expired`, `quote.converted`, `contract.issued`, `contract.accepted`, `contract.amended`,
  `contract.cancelled`.
- E-mails ao cliente no despacho da outbox: orçamento enviado (com a política de bloqueio e a
  validade) e contrato emitido (com o aviso de aceite eletrônico simples). O bloqueio temporário de um
  orçamento ainda não convertido não gera e-mails de reserva (por exemplo, ao ser liberado por nova
  versão); depois da conversão, a reserva segue as notificações normais.
- A rotina por organização do worker (`organization.tick`) executa `ExpireQuotes`: orçamentos enviados
  com validade vencida são marcados como expirados (`FOR UPDATE SKIP LOCKED`) e o bloqueio ativo é
  cancelado.

## Interface

| Rota | Função |
|---|---|
| `GET /orcamentos`, `GET /orcamentos/novo`, `POST /orcamentos` | Lista com filtros, formulário e criação do rascunho |
| `GET /orcamentos/:id` (`?versao=N`) | Detalhe com versões, situação, aprovação, bloqueio, anexos e histórico |
| `GET /orcamentos/:id/nova-versao`, `POST /orcamentos/:id/versoes` | Nova versão |
| `POST /orcamentos/:id/enviar`, `/aprovar`, `/rejeitar`, `/converter` | Ações da máquina de estados |
| `GET /contratos`, `GET /contratos/:id` | Lista e detalhe (termos, documentos com SHA-256, aceites, aditivos, prévia da multa) |
| `POST /contratos` | Emissão a partir da reserva (botão "Gerar contrato" na tela da reserva) |
| `POST /contratos/:id/aceite`, `/aditivos`, `/cancelar`, `/encerrar` | Aceite, aditivo de extensão, cancelamento e encerramento |

A tela da reserva mostra o contrato e o orçamento de origem, ou o botão "Gerar contrato"; com contrato
em aberto, reagendamento, extensão e cancelamento diretos ficam ocultos e um aviso aponta o contrato.
A tela do cliente tem o atalho "Novo orçamento". Os formulários têm labels, mensagens por campo
(`aria-invalid`), estados vazios e nenhum script inline.

## Decisões

- **Bloqueio vinculado por `hold_reservation_id`.** A reserva de bloqueio não recebe `quote_id`; só a
  reserva convertida o recebe. Assim o índice único parcial significa "uma reserva convertida por
  orçamento" e reenvios após nova versão podem criar novos bloqueios sem violar o índice.
- **Lock do orçamento como primeira barreira, índice único como garantia.** A conversão concorrente é
  serializada pelo `FOR UPDATE`; o índice com savepoint cobre caminhos que não passem pelo lock.
- **Termos congelados na emissão e documento por versão.** O contrato guarda o snapshot dos termos e cada
  documento guarda o snapshot completo usado na geração; o SHA-256 registrado permite verificar o
  arquivo baixado.
- **Número do contrato antes do PDF.** Diferente da reserva e do orçamento, o número do contrato é
  necessário no documento; o lock do contador dura da atribuição até o commit, que inclui a geração do
  PDF (operação local e curta).
- **Fontes padrão do PDF.** Sem dependência de fontes TrueType na imagem; textos são convertidos para
  Windows-1252 (cobre o português) e caracteres fora dela viram "?".

## Limitações

- Não há endpoints de API v1 para orçamentos e contratos; as operações estão disponíveis na interface
  web e nos casos de uso.
- O portal do cliente não existe ainda: os casos de uso de aprovação, rejeição, leitura e aceite já
  aceitam ator `customer`, mas não há telas de portal, e o download de PDFs por clientes continua
  bloqueado pelo escopo de portal padrão (`NoPortalScope`).
- O único tipo de aditivo é a extensão de prazo. Antecipação, troca de itens ou de condições exigem
  cancelamento e novo contrato.
- O encerramento depende da conclusão da reserva, que será registrada pelo módulo de retirada e
  devolução.
- Se a transação falhar depois de o PDF ser gravado no armazenamento (por exemplo, em uma nova tentativa
  após deadlock), o arquivo pode ficar sem registro em `attachments`; ele não é acessível pela aplicação.

## Como testar

```bash
# Unitários do domínio (sem banco)
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/unit/domain/quotes_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/unit/domain/contracts_test.rb
# Integração com PostgreSQL
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/quotes_flow_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/contracts_flow_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/quotes_contracts_worker_test.rb
# Concorrência (duas threads sincronizadas por Barrier)
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/concurrency/quote_conversion_race_test.rb
# Telas (Rack::Lint)
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/http/quotes_contracts_pages_test.rb
# Suíte completa com metas de cobertura
docker compose run --rm -e COVERAGE_CHECK=1 dev bundle exec rake test:all
```

Casos cobertos: versões imutáveis e aprovação da versão correta; orçamento expirado (aprovação e
varredura); bloqueio no envio, liberação na nova versão e envio sem disponibilidade; conversão
idempotente sequencial e concorrente (lock do orçamento e índice único); snapshot preservado após
alteração de preço do catálogo; PDF iniciando com `%PDF` e SHA-256 registrado igual ao do arquivo;
aditivo de extensão com ajuste e nova versão do documento; extensão que invade outra reserva recusada
sem aditivo; reagendamento, extensão e cancelamento diretos recusados; faixas da política de
cancelamento; aceite único; imutabilidade no banco; isolamento entre organizações; ator `customer`
restrito ao próprio cadastro; e-mails e expiração pelo worker; renderização das telas sob Rack::Lint.
