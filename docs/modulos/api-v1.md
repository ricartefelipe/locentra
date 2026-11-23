# API v1

API versionada em `/api/v1`, descrita em [`docs/openapi.yaml`](../openapi.yaml) (servida também em
`GET /api/v1/openapi.yaml`). Este documento resume as regras comuns, a cobertura por grupo e as decisões da
ampliação com orçamentos, contratos, retirada, devolução, inspeções, alertas e alteração das configurações
(ADR-030).

## Visão geral

- **Autenticação:** credencial de integração do tipo `api` em `Authorization: Bearer lcn_...`, com escopos
  (subconjunto das permissões de quem a criou), validade e revogação. Credenciais da CLI e de organização
  suspensa ou encerrada recebem 401. A sessão de usuário da interface web (cookie `locentra_session`, ou
  `__Host-locentra` com cookies seguros) é aceita pelas rotas da API, mas o uso documentado e suportado de
  sessão é somente o `PATCH /organization/settings`, com `X-CSRF-Token` (o campo `_csrf` das páginas). Não há
  endpoint dedicado ao token CSRF.
- **Tenant:** sempre o da credencial ou da sessão; parâmetros e cabeçalhos não escolhem organização. Um
  identificador de outra organização responde 404, como um recurso inexistente.
- **Idempotência:** toda mutação exige `Idempotency-Key` (8 a 255 caracteres `A-Za-z0-9_.:-`). A operação roda
  na mesma transação da chave e o resultado (somente 2xx) fica gravado por 24 horas. A mesma chave com o mesmo
  corpo devolve a resposta gravada com `Idempotent-Replayed: true`; com corpo diferente, 409
  `idempotency_key_reused`; sem a chave, 422 em `Idempotency-Key`. O escopo da chave é o ator mais
  `"<VERBO> /api/v1/<caminho com o identificador normalizado>"`, e a impressão digital é a do corpo (`{}` sem
  corpo). Se a operação falha, nada é gravado e a chave pode ser usada de novo.
- **Erros:** `{"error": {"code", "message", "details", "request_id"}}`. Validação responde 422 com
  `details.fields` (campo → mensagens), com os nomes de campo das regras de negócio (`validade`, `itens`,
  `tarifas`, `desconto`, `patrimonio`, `quantidade`, `retirante`, `resultado`, `inspecao`, `faixas_cancelamento`,
  `confirmar_fuso`...); os erros de formato do corpo são reunidos numa única resposta. Indisponibilidade
  responde 409 `unavailable` com `details.shortages`. Conflitos de estado usam códigos estáveis
  (`stale_quote_version`, `quote_expired`, `already_picked_up`, `already_returned`, `contract_not_cancellable`,
  `stale_organization`...) e transições recusadas, `invalid_transition`. Na sessão de usuário com e-mail não
  confirmado, as ações para fora (envio de orçamento, emissão de contrato) e, depois de 7 dias, todas as
  alterações respondem 403 `email_unconfirmed` (ADR-031, [módulo](confirmacao-email.md)); a credencial segue a
  situação de quem a criou e recebe o mesmo código.
- **Paginação:** `limit` de 1 a 100 (padrão 25) e `offset` de 0 a 1.000.000, com
  `pagination: {limit, offset, total, next_offset}`; fora da faixa, 422.
- **Formatos estritos:** inteiros são inteiros do JSON (centavos e pontos-base); números com casas decimais,
  textos numéricos e booleanos são recusados com 422, sem conversão. Booleanos aceitam somente `true` e `false`.
  Instantes usam ISO 8601 com fuso; períodos são semiabertos `[starts_at, ends_at)`. Valores monetários são
  objetos `Money` (`amount_cents`, `currency`, `formatted`).
- **Dados pessoais:** os detalhes trazem o cliente pelo identificador (`customer_id`), sem nome nem documento.
  O retirante aparece pelo nome, sem documento; os contatos autorizados a retirar aparecem somente com
  `customers.read` (sem o escopo, `null`). Documento, IP e navegador do aceite do contrato e o snapshot dos
  dados do documento não são expostos.

## Componentes

| Camada | Arquivos |
|---|---|
| Aplicação | `application/base.rb` (`Composition`), `quotes.rb`, `contracts.rb` (`DocumentFile`), `fulfillment.rb`, `returns.rb`, `inspections.rb` (`SearchInspections`), `overdue.rb` (`ListAlerts`), `organizations.rb`, `organization_settings.rb` |
| Domínio | `domain/organizations.rb` (`Organization#revise` com faixas, `#revision_attrs`), `domain/organization_settings.rb` (`CancellationPolicy.from_tiers`) |
| Persistência | `AlertRepository#search`, `InspectionRepository#list`/`#count`, `ContractRepository#find_document`, `FulfillmentRepository#line_details` |
| Interface | `interfaces/http/api/v1.rb` (utilitários de entrada estrita e idempotência), `v1_quotes.rb`, `v1_contracts.rb`, `v1_operations.rb`, `v1_organization.rb`, `routes.rb`, `docs/openapi.yaml` |

## Endpoints, escopos e casos de uso

| Endpoint | Escopo | Caso de uso | Conflitos (409) |
|---|---|---|---|
| `GET /quotes`, `GET /quotes/{id}` | `quotes.read` | `ListQuotes`, `GetQuote` | — |
| `POST /quotes` | `quotes.write` (tarifa ajustada ou avulsa: `fees.override`) | `CreateQuote` | — |
| `POST /quotes/{id}/versions` | `quotes.write` | `ReviseQuote` | `invalid_transition` |
| `POST /quotes/{id}/send` | `quotes.write` (com bloqueio: `reservations.write`) | `SendQuote` | `unavailable`, `invalid_transition` |
| `POST /quotes/{id}/approve` | `quotes.write` | `ApproveQuote` | `stale_quote_version`, `quote_expired`, `invalid_transition` |
| `POST /quotes/{id}/reject` | `quotes.write` | `RejectQuote` | `stale_quote_version`, `invalid_transition` |
| `POST /quotes/{id}/convert` | `quotes.write` e `reservations.write` | `ConvertQuote` | `unavailable`, `quote_hold_mismatch`, `invalid_transition` |
| `GET /contracts`, `GET /contracts/{id}` | `contracts.read` | `ListContracts`, `GetContract` | — |
| `GET /contracts/{id}/documents/{version}` | `contracts.read` | `DocumentFile` (com `Attachments::Download`) | — |
| `POST /contracts` | `contracts.write` | `IssueContract#issue` | `reservation_not_confirmed` |
| `POST /contracts/{id}/amendments` | `contracts.write` e `reservations.write` | `AmendContract` | `unavailable`, `invalid_transition` |
| `POST /contracts/{id}/cancel` | `contracts.write` e `reservations.cancel` | `CancelContract` | `contract_not_cancellable`, `invalid_transition` |
| `POST /reservations/{id}/pickups` | `fulfillment.write` | `StartPickup#open` | `invalid_transition` |
| `GET /pickups/{id}` | `reservations.read` (retirantes autorizados: `customers.read`) | `GetPickup` | — |
| `POST /pickups/{id}/check` | `fulfillment.write` | `CheckPickup` | `already_picked_up`, `allocation_changed` |
| `POST /pickups/{id}/deliver` | `fulfillment.write` | `DeliverPickup` | `already_picked_up`, `allocation_changed`, `early_pickup_unavailable` |
| `POST /pickups/{id}/cancel` | `fulfillment.write` | `CancelPickup` | `already_picked_up` |
| `GET /reservations/{id}/return-items` | `reservations.read` | `ReturnForm` | — |
| `POST /reservations/{id}/returns` | `fulfillment.write` | `RegisterReturn` | `already_returned`, `invalid_transition` |
| `GET /returns/{id}` | `reservations.read` | `GetReturn` | — |
| `GET /inspections` | `reservations.read` | `SearchInspections` | — |
| `POST /inspections/{id}/approve`, `/reject` | `inspections.write` | `ApproveInspection`, `RejectInspection` | `invalid_transition`, `stale_inspection` |
| `GET /alerts` | `reservations.read` | `ListAlerts` | — |
| `POST /alerts/{id}/resolve` | `fulfillment.write` | `ResolveAlert` | `alert_resolved` |
| `PATCH /organization/settings` | sessão de usuário com `organization.manage` | `UpdateSettings` e `GetOrganization` | `stale_organization` |

Os escopos são as permissões da matriz (`Domain::Identity::PERMISSIONS`), sem permissão nova. As permissões
adicionais continuam conferidas dentro do caso de uso, também no modo composto com a transação da chave.
Credenciais não aplicam desconto manual: o limite de desconto de quem não é usuário é 0 e um
`manual_discount_bps` positivo responde 403.

## Composição com a transação da chave

Toda mutação roda em `Idempotency#call`, que abre a transação, revalida o ator e reserva a chave. Os casos de
uso aceitam `tx:` e, nesse caso, usam `Application::Composition.run`: a permissão é conferida de novo sobre o
ator recebido e nenhuma transação nova é aberta (o coordenador recusa transação aninhada). A resposta é o
detalhe atualizado, lido pelo caso de uso de leitura na mesma transação (`GetQuote`, `GetContract`,
`GetPickup`, `GetReturn`, `GetOrganization` com `tx:`): a gravação ainda não foi confirmada, e o corpo gravado
na chave é exatamente o que o replay devolve. Nessa leitura composta, `GetQuote`, `GetContract`, `GetPickup` e
`GetReturn` recebem `permission:` com a permissão da mutação (`quotes.write`, `contracts.write`,
`fulfillment.write`), já conferida na transação, e não exigem o escopo de leitura: cada mutação exige somente
os escopos da tabela acima (`Composition.detail_permission`). Sem `tx:`, os casos de uso seguem o caminho da
interface web e da CLI, sem mudança, e as leituras conferem sempre a permissão de leitura.

## Criação que pode encontrar o recurso existente

A emissão de contrato (`POST /contracts`), a separação (`POST /reservations/{id}/pickups`) e a conversão de
orçamento (`POST /quotes/{id}/convert`) respondem **201** quando criam o recurso e **200** quando devolvem o
existente (o contrato da reserva, a separação em andamento ou a reserva já convertida), com `Location` nos dois
casos: `/api/v1/contracts/{id}`, `/api/v1/pickups/{id}` e `/api/v1/reservations/{id}`. As demais criações
respondem 201 com `Location` do recurso (`/quotes/{id}`, `/returns/{id}`; a nova versão e o aditivo apontam
para o orçamento e o contrato).

## PDF do contrato

`GET /contracts/{id}/documents/{version}` devolve o PDF da versão com:

- `content-type: application/pdf`;
- `content-disposition: attachment; filename="contrato-<código>-v<n>.pdf"; filename*=UTF-8''...`;
- `content-length`, `cache-control: private, no-store`, `x-content-type-options: nosniff` e
  `content-security-policy: default-src 'none'; sandbox`;
- `repr-digest: sha-256=:<base64 do SHA-256 gravado>:` (RFC 9530), para conferência de integridade do arquivo
  recebido com o SHA-256 registrado na geração (o mesmo de `documents[].sha256`, em hexadecimal).

O download reutiliza `Attachments::Download`: a permissão é a do dono (`contracts.read`), o contrato de outra
organização responde 404 e o conteúdo ausente no armazenamento também responde 404. Versão que não é inteiro
positivo responde 422 em `versao`.

## Decisões

- **Configurações somente por sessão de usuário (D3).** Credenciais continuam sem alterar as configurações,
  mesmo com `organization.manage` (403 `forbidden`; sem o escopo, "permissão necessária: organization.manage";
  com o escopo, "as configurações da organização são alteradas somente por usuários"). A tela de credenciais
  oferece todos os escopos, e as credenciais com `organization.manage` foram emitidas sob a regra de que não
  alteram configurações: liberar agora ampliaria em silêncio o poder de tokens existentes. A troca de fuso exige
  leitura humana das consequências, e a auditoria liga a alteração a uma pessoa. Liberar para integrações
  exigiria permissão nova e dedicada, com credenciais novas (evolução registrada no ADR-030).
- **PATCH parcial com versão obrigatória (D4).** Chave presente altera o campo e chave ausente mantém o valor
  atual. Sem `cancellation_policy`, a política gravada é mantida como está, mesmo que anterior às regras atuais
  (a 0016 só confere o formato); ela passa pelas regras quando é alterada. `lock_version` (inteiro ≥ 1) é obrigatório: a escrita parcial de configurações que afetam todo o tenant
  não pode sobrescrever às cegas uma alteração concorrente (diverge do "opcional na API" das condições
  comerciais, ADR-027). Divergência responde 409 `stale_organization`. A troca de fuso exige
  `confirm_time_zone_change: true` (422 em `confirmar_fuso`). Chaves desconhecidas ou não editáveis (`slug`,
  `status`, `settings`, `branches`...) respondem 422 no nome da própria chave ("campo desconhecido ou não
  editável"). Sem mudança efetiva, 200 com `changed: false` e sem auditoria; com mudança, a auditoria
  `organization.settings_updated` registra `via: api`. A política usa o formato de `GET /organization`
  (`{"tiers": [{"min_hours_before", "fee_bps"}]}`), validado por `CancellationPolicy.build`, com as mensagens da
  interface em `faixas_cancelamento`.
- **Aprovação de orçamento vencido (D7).** Na composição, a expiração gravada pela tentativa seria desfeita com
  a transação da chave. O controlador trata o `quote_expired` chamando `ApproveQuote#record_expiration`, que
  grava a expiração em transação própria e nunca aprova, e responde 409. A operação não é repetida fora da
  chave (como faz a confirmação de reserva com bloqueio vencido): a repetição poderia aprovar sem chave. Repetir
  a mesma chave depois disso responde 409 `quote_expired` de novo, sem aprovar.

## Limitações

- Portal do cliente sem API v1.
- Aceite eletrônico e encerramento de contrato sem API v1 (interface web).
- Avarias (registro, revisão, aprovação de cobrança e descarte), manutenção e transferências sem API v1.
- Prévia e restauração dos valores padrão das configurações somente na interface web.
- Gestão de filiais somente na interface web.
- Alteração das configurações por credencial e pela CLI não existe (ADR-030).
- O cliente por sessão obtém o token CSRF da própria interface (campo `_csrf` das páginas); não há endpoint
  dedicado ao token.
- A resolução de alerta usa o campo de erro `decisao`, o mesmo do domínio e da interface.

## Testes

| Arquivo | Cobertura |
|---|---|
| `test/http/quotes_api_test.rb` | criação com tarifas, escopos e desconto por credencial, erros por campo, lista com filtros e paginação, detalhe, nova versão, envio com e sem bloqueio, aprovação (inclusive vencida e desatualizada), rejeição, conversão 201/200, idempotência, isolamento |
| `test/http/contracts_api_test.rb` | emissão 201/200, lista com filtros, detalhe com prévia, PDF com cabeçalhos e integridade, erros do PDF, aditivo (inclusive conflito), cancelamento com multa e depois da retirada, escopos adicionais, idempotência, isolamento |
| `test/http/operations_api_test.rb` | separação 201/200, conferência com erros reunidos, entrega e entrega duplicada, cancelamento, retirantes autorizados por escopo, devolução parcial e total com inspeção, erros e conflitos da devolução, inspeções, alertas, idempotência, isolamento |
| `test/http/organization_settings_api_test.rb` | PATCH parcial, sem mudança, política em pontos-base, troca de fuso, versão obrigatória e desatualizada, chaves desconhecidas, CSRF, idempotência, gerente e credenciais recusados, isolamento |
| `test/http/api_test.rb` | rotas documentadas no OpenAPI, schemas fechados, validador do contrato e respostas de erro |
| `test/support/openapi_contract.rb` | validador mínimo usado por todos os testes acima (`assert_conforms`) |
| `test/unit/application/composition_test.rb` | composição com e sem transação |
| `test/integration/api_composition_test.rb` | cada caso de uso com `tx:` desfeito junto com a transação (inclusive o arquivo do PDF), permissão no modo composto e `record_expiration` |
| `test/repository/operations_queries_test.rb` | listas paginadas de alertas e inspeções, documento do contrato e isolamento |
| `test/concurrency/api_quote_conversion_race_test.rb` | conversões simultâneas com a mesma chave e com chaves diferentes |
| `test/concurrency/api_pickup_delivery_race_test.rb` | entregas simultâneas da mesma retirada |
