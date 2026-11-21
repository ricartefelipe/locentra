# Módulo de condições comerciais

Requisitos atendidos: RF-17 (cupons, tarifas adicionais e condições negociadas por cliente, com cadastro
e aplicação em reservas e orçamentos) e RF-18 (snapshots de preço e condições), com RF-36 (escopos de
credenciais), RF-37 (interface web), RF-40 (CLI) e RF-41 (auditoria). A semântica dos cálculos está em
[`../PRECIFICACAO.md`](../PRECIFICACAO.md) e as decisões, na ADR-027 de [`../DECISOES.md`](../DECISOES.md).

| Camada | Arquivos |
|---|---|
| Migration | `db/migrations/0015_condicoes_comerciais.sql` |
| Domínio | `lib/locentra/domain/commercial_terms.rb` (`Codes`, `Redemptions`, `Coupons`, `Agreement`, `Fee`, `FeeRequest`, `Fees`), `domain/pricing.rb` (`Coupon`, `Totals`), `domain/shared/money.rb` (`Percent.parse`), `domain/organizations.rb` (`Text.optional!`), `domain/identity.rb` (permissões), `domain/quotes.rb` e `domain/contracts.rb` (tarifas na impressão digital da versão e nos termos) |
| Aplicação | `lib/locentra/application/commercial_terms.rb` (cadastros), `application/reservations.rb` (`Pricer`, `CreateReservation`), `application/quotes.rb` (`VersionBuilder`, `CreateQuote`, `ReviseQuote`) |
| Persistência | `lib/locentra/infrastructure/persistence/coupons.rb`, `fees.rb`, `price_agreements.rb`, `pricing.rb` (leituras da precificação e livro de usos), `catalog.rb` (`find_product_by_sku`) |
| Documento | `lib/locentra/infrastructure/documents/contract_pdf.rb` (cupom, condições e tarifas na seção de valores) |
| Interface web | `interfaces/http/routes_commercial_terms.rb`, `web/commercial_terms_controllers.rb` (`CouponsController`, `FeesController`), `web/main_controllers.rb` (`CustomersController`: condições na página do cliente), `web/operations_controllers.rb` e `web/quotes_controller.rb` (tarifas nos formulários), `controller.rb` (`fee_requests_from`, `optional_local_time`), `views.rb` e `labels.rb`; `views/coupons/`, `views/fees/`, `views/customers/price_agreements.html.erb`, `views/shared/fee_fields.html.erb`, `views/shared/pricing_summary.html.erb`, `views/shared/history.html.erb`; `public/js/modules/line-items.js` |
| API | `interfaces/http/api/v1_commercial_terms.rb` (`CommercialTermsV1Controller`), `api/v1.rb` (`fees` na criação de reserva, inteiros estritos), `interfaces/commercial_terms_serializers.rb`, `docs/openapi.yaml` |
| CLI | `interfaces/cli/commercial_terms_commands.rb`, `command_support.rb`, `invocation.rb` |
| Composição | `lib/locentra/wiring/commercial_terms.rb` (chamado por `System#build_use_cases`) |
| Seed | `lib/locentra/seed.rb` (`COMMERCIAL_TERMS`, `ensure_commercial_terms`) |

## Modelo de dados

Todas as tabelas têm `organization_id NOT NULL`, chaves estrangeiras compostas e RLS forçada. Toda consulta
filtra `organization_id` explicitamente, além da RLS.

| Tabela | Conteúdo | Proteções |
|---|---|---|
| `coupons` (alterada) | Código, tipo (`percent`/`fixed`), valor (pontos-base ou centavos), vigência, máximo de usos, subtotal mínimo, ativação; novas: `description`, `created_by`, `updated_at`, `deactivated_at`, `lock_version`. `redemptions` é o contador da 1.0.0, congelado | `UNIQUE (organization_id, code)`; `UPDATE` de `locentra_app` somente nas colunas editáveis (código, tipo e valor não mudam) e no contador legado `redemptions`, mantido apenas para o retorno à 1.0.0 (a 1.1.0 não grava a coluna); gatilho `coupons_enforce_limits` para a ordem da vigência e o máximo de 1.000.000, verificados na inserção e nas colunas alteradas (cupons da 1.0.0 fora desses limites continuam desativáveis e reativáveis); worker sem `UPDATE` nem `DELETE` |
| `coupon_redemptions` | Livro de usos: cupom, reserva, subtotal e desconto no instante do uso, autor e instante | `UNIQUE (organization_id, reservation_id)`; FKs compostas para `coupons` e `reservations`; somente inserção; gatilho `coupon_redemptions_enforce_limit` |
| `customer_price_agreements` (alterada) | Cliente, produto (nulo = geral), desconto, vigência; novas: `valid_from` (obrigatória), `ended_at`, `ended_by`, `end_reason` | Exclusion constraint `customer_price_agreements_no_overlap` sobre `price_agreement_window`; `UPDATE` somente nas colunas de encerramento; gatilho `customer_price_agreements_end_once`; `DELETE` revogado |
| `additional_fees` | Código, nome, descrição, valor padrão, ativação, `lock_version` | `UNIQUE (organization_id, code)`; `UPDATE` somente nas colunas editáveis (o código não muda); `DELETE` revogado |
| `reservations`, `reservation_items` (alteradas) | — | Gatilhos `*_pricing_immutable`: a coluna `pricing` não é alterada |

A migration preenche `coupons.updated_at` e `customer_price_agreements.valid_from` com `created_at` e recusa
bancos com condições sobrepostas herdadas da 1.0.0 (ver [`../RUNBOOKS.md`](../RUNBOOKS.md), seção 13, e
[`../ISOLAMENTO.md`](../ISOLAMENTO.md) sobre o uso pontual de `NO FORCE`).

## Regras

### Cupons

- Código normalizado (sem espaços nas pontas, em maiúsculas), de 3 a 40 caracteres, único na organização
  mesmo entre cupons desativados (`coupon_code_taken`). Códigos no formato de identificador (UUID) são
  recusados, porque as referências aceitam identificador ou código.
- Código, tipo e valor são imutáveis. São editáveis: descrição, início e fim da vigência, máximo de usos e
  subtotal mínimo. A edição valida o estado resultante completo, inclusive de cupons antigos, e recusa
  máximo abaixo dos usos ativos e fim no passado (quando o fim muda).
- O uso é uma linha de `coupon_redemptions` por reserva. Usos ativos = contador legado + usos do livro cuja
  reserva está solicitada, confirmada, em andamento, concluída ou em bloqueio temporário ainda válido. A
  liberação (cancelamento direto, pelo contrato, expiração pela varredura, pelo alocador ou na tentativa de
  confirmação) não grava nada.
- Situação: desativado > expirado > agendado > esgotado > vigente (ver
  [`../MAQUINAS-DE-ESTADO.md`](../MAQUINAS-DE-ESTADO.md)).
- Exclusão somente de cupom nunca usado (sem linha no livro e com contador legado zero), apenas na interface
  web (`coupon_in_use` nos demais casos). API e CLI oferecem desativação.
- Orçamentos e solicitações do portal não aceitam cupom; um snapshot de preços com cupom é recusado na
  criação de reserva a partir de snapshot.

### Condições negociadas

- Desconto de 0,01% a 90% por cliente, geral ou de um produto ativo (informado por identificador ou SKU na
  web e na CLI; por identificador na API). Na linha vale a maior entre a do produto e a geral; em empate, a
  do produto.
- Início vazio ou até 24 horas no passado vale o instante atual; mais antigo é recusado. O fim, quando
  informado, é posterior ao início e ao instante atual.
- Vigências efetivas do mesmo cliente e escopo não se sobrepõem (`price_agreement_overlap`).
- Não muda depois de criada. O encerramento é único, com motivo (3 a 500 caracteres), imediato ou agendado
  para um instante anterior ao fim efetivo. Condição já encerrada (mesmo com encerramento agendado) ou
  expirada recusa novo encerramento (`invalid_transition`).

### Tarifas adicionais

- Catálogo com código (2 a 30 caracteres, imutável, `fee_code_taken`), nome, descrição e valor padrão positivo.
- Um documento aceita até 10 tarifas, sem repetir a mesma tarifa do catálogo. Sem valor, vale o padrão.
- Valor diferente do padrão e tarifa avulsa exigem `fees.override`; a redução fica limitada ao desconto manual
  do papel sobre o valor padrão, e credenciais não reduzem. Tarifa inativa é recusada.
- Na nova versão de orçamento, a entrada idêntica a uma da versão anterior é mantida sem nova autorização,
  mesmo com a tarifa inativa; cada entrada anterior autoriza uma única entrada (cópias repetidas são ajustes
  novos). A impressão digital da versão inclui as tarifas: uma versão que só muda
  tarifas é uma versão nova.
- Erros de tarifa saem sempre no campo `tarifas`.

### Comuns

- **Controle otimista:** `lock_version` em cupons e tarifas. A web envia sempre a versão exibida (campo oculto);
  na API é opcional. Divergência: `stale_coupon` ou `stale_fee` (409).
- **Operação nula:** alteração sem mudança e ativação ou desativação no mesmo estado devolvem o registro sem
  gravar nem auditar, em todos os canais.
- **Fuso:** tudo é gravado em UTC; telas e CLI usam o fuso da organização.

## Permissões

`coupons.read`, `coupons.write`, `price_agreements.read`, `price_agreements.write`, `fees.read`, `fees.write`
e `fees.override`; a matriz por papel e as regras complementares estão em
[`../PERMISSOES.md`](../PERMISSOES.md). Aplicar cupom e tarifa pelo valor padrão exige somente
`reservations.write` ou `quotes.write`. Credenciais existentes não ganham os escopos novos.

## Auditoria

Todas as ações são registradas na mesma transação, com tipo e identificador do ator e `request_id`.

| Ação | Recurso | Detalhes |
|---|---|---|
| `coupon.created` | `coupon` | `code`, `kind`, `value`, `valid_from`, `valid_until`, `max_redemptions`, `min_subtotal_cents` |
| `coupon.updated` | `coupon` | `changes` (campo → valor anterior e novo) |
| `coupon.deactivated`, `coupon.reactivated`, `coupon.deleted` | `coupon` | `code` |
| `fee.created` | `fee` | `code`, `name`, `default_amount_cents` |
| `fee.updated` | `fee` | `changes` |
| `fee.deactivated`, `fee.reactivated` | `fee` | `code` |
| `price_agreement.created` | `price_agreement` | `customer_id`, `product_id`, `discount_bps`, `valid_from`, `valid_until` |
| `price_agreement.ended` | `price_agreement` | `customer_id`, `reason`, `ended_at`, `scheduled`, `previous_status` |
| `reservation.created` (alterada) | `reservation` | mais `coupon_id` e `coupon_code` (quando houver), `fees_cents` e `fee_overrides` (quando houver ajuste) |
| `quote.created`, `quote.revised` (alteradas) | `quote` | mais `fees_cents` e `fee_overrides` (quando houver ajuste) |

O uso do cupom é auditado na criação da reserva, e a liberação aparece no cancelamento ou na expiração da
reserva; o histórico do cupom mostra somente as alterações do cadastro. Não há evento novo de webhook.

## Snapshot, contrato e portal

O resumo de preços ganha `coupon` e `agreements`, e `fees` passa a identificar a tarifa, o valor padrão e a
origem; a linha ganha `negotiated_agreement_id` (tabela em [`../PRECIFICACAO.md`](../PRECIFICACAO.md)). Os
ajustes de tarifa (`fee_overrides`) ficam somente na auditoria. Os termos do contrato copiam cupom,
condições e tarifas, e o PDF os descreve na seção de valores. A parcial `shared/pricing_summary` mostra
subtotal, condição negociada, cupom, desconto, tarifas e total na reserva, no orçamento e no contrato; para
o cliente (portal) ela omite a origem da tarifa, o valor padrão e as ligações internas. O cliente vê o
detalhamento antes de aprovar o orçamento.

## Interface web

- **Cupons** (`/cupons`, com `coupons.read`): lista com busca, situação e ordenação; cadastro; página do cupom
  com dados, edição, desativação ou reativação, exclusão (somente sem uso), usos e histórico.
- **Tarifas adicionais** (`/tarifas`, com `fees.read`): lista, cadastro, edição, desativação e histórico.
- **Condições negociadas:** seção da página do cliente (com `price_agreements.read`), com cadastro e
  encerramento imediato ou agendado para quem tem `price_agreements.write`.
- **Reserva e orçamento:** grupo "Tarifas adicionais" nos formulários (valor e tarifa avulsa somente com
  `fees.override`) e, na reserva, o campo "Cupom".

## API v1

Rotas em `docs/openapi.yaml`: `/coupons`, `/coupons/{id}` (consulta por identificador ou código; `PATCH`),
`/coupons/{id}/deactivate`, `/coupons/{id}/reactivate`, `/coupons/{id}/redemptions`, `/fees` e
equivalentes, `/customers/{id}/price-agreements`, `/price-agreements/{id}/end` e `fees` em
`POST /reservations`, `POST /quotes` e `POST /quotes/{id}/versions` (as mesmas regras de autorização; a nova
versão mantém sem nova autorização a tarifa idêntica à da versão anterior). Credenciais não aplicam desconto
manual em reservas nem em orçamentos.

- Toda mutação exige `Idempotency-Key` e roda na transação da chave. As mutações usam somente o identificador.
- `PATCH` altera as chaves enviadas; `null` limpa (em `min_subtotal_cents`, vale 0). Sem mudança, responde 200
  sem auditoria.
- Percentuais em pontos-base e valores em centavos são inteiros do JSON: `12.5`, `"12"` e `true` respondem 422
  ("informe um número inteiro"). Os erros vêm em `error.details.fields`, com os campos das regras de negócio.
- Sem os escopos correspondentes, os usos omitem `reservation_id`, `reservation_code` e `customer_name`, e as
  condições omitem `product`.

## CLI

`coupons list|show|create|deactivate|reactivate`, `fees list|show` e `agreements list|create|end`, descritos
em [`cli-operacional.md`](cli-operacional.md). O JSON usa o mesmo serializador da API. Edição de cupom e
gestão de tarifas ficam na web e na API.

## Concorrência

- **Ordem de travas na criação de reserva:** cupom (`FOR UPDATE`) → inserção da reserva → inserção do uso
  (o gatilho trava o mesmo cupom, que já pertence à transação) → estoques. Cancelamento, expiração e
  alocador travam reserva e estoques e não tocam em cupons nem em usos. A edição de cupom trava só o cupom.
  Não há ciclo que envolva cupons.
- **Contagem depois da trava:** os usos ativos são contados numa instrução separada, executada depois do
  `FOR UPDATE`; na mesma instrução, em READ COMMITTED, a contagem usaria o snapshot anterior à espera pela
  trava e dois resgates do último uso passariam.
- **Gatilho:** `coupon_redemptions_enforce_limit` repete a verificação no banco com o instante do uso como
  referência; a violação chega à aplicação como "cupom esgotado".
- **Confirmação em andamento:** a confirmação lê o relógio antes de travar a reserva e grava a nova
  situação só no COMMIT. Para que um resgate concorrente não conte como liberado um bloqueio que está sendo
  confirmado, o limite (resgate, redução do máximo na edição e gatilho) conta o bloqueio vencido durante a
  carência de 5 minutos (`Redemptions::LIMIT_GRACE`); a situação exibida do uso não usa a carência.
- **Condições simultâneas:** a pré-verificação de sobreposição é seguida da inserção num savepoint; a
  exclusion constraint recusa a segunda de duas criações concorrentes, que recebe o mesmo conflito
  (`price_agreement_overlap`).
- **Edições concorrentes:** `UPDATE ... WHERE lock_version = <lida>`; zero linhas resulta em `stale_coupon`
  ou `stale_fee`.

## Testes

| Arquivo | Cobertura |
|---|---|
| `test/unit/domain/commercial_terms_test.rb`, `commercial_terms_agreements_fees_test.rb` | Códigos, cadastro e edição de cupons, precedência das situações, motivos de recusa, estados do uso, condições (início ajustado, encerramento imediato e agendado), resolução de tarifas com autorização e continuidade; propriedades de totais, de usos e da melhor condição |
| `test/unit/domain/permissions_doc_test.rb` | A tabela de `docs/PERMISSOES.md` coincide com `Identity::PERMISSIONS` |
| `test/unit/application/commercial_terms_test.rb` | `Pricer` (ajustes fora do resumo, condição por linha, trava e instante na leitura do cupom), operações nulas sem auditoria, versões desatualizadas |
| `test/repository/commercial_terms_repository_test.rb`, `commercial_terms_guarantees_test.rb` | Busca, ordenação e paginação; situação e uso ativo em SQL iguais ao domínio (propriedade); contagem depois da trava; gatilho de limite com todas as situações ativas e o contador legado, igual ao domínio (propriedade); privilégios de coluna; encerramento único; snapshots imutáveis; exclusion constraint; FKs compostas |
| `test/repository/migration_0015_test.rb` | Atualização a partir do esquema da 0014: colunas preenchidas, `FORCE` restaurado, contador legado como base; cupons legados fora dos limites novos desativáveis e reativáveis, com erro no campo na edição; condições sobrepostas abortam a migration |
| `test/repository/tenant_isolation_test.rb` | Cupons, usos, condições e tarifas de outra organização invisíveis; RLS forçada nas tabelas novas |
| `test/integration/commercial_terms_coupons_test.rb`, `commercial_terms_agreements_test.rb`, `commercial_terms_fees_test.rb`, `commercial_terms_access_test.rb` | Fluxos completos de cupons (uso, liberação por todos os caminhos, bloqueio vencido não varrido), condições (troca agendada sem intervalo), tarifas (autorização, continuidade, contrato e PDF), matriz de papéis, credenciais e isolamento |
| `test/integration/seed_test.rb` | Condições comerciais do seed criadas uma única vez, sem reativar o que foi desativado |
| `test/integration/demo_commercial_terms_test.rb` | Passo 15 da demonstração pela interface web |
| `test/concurrency/coupon_redemption_race_test.rb` | Dois resgates do último uso; criação com cupom contra o alocador no mesmo estoque, sem impasse; cancelamento concorrente com resgate; confirmação de bloqueio em andamento no vencimento contra o último uso e contra a redução do máximo; redução do máximo durante o resgate; condições sobrepostas simultâneas |
| `test/http/commercial_terms_pages_test.rb`, `commercial_terms_fees_pages_test.rb`, `commercial_terms_agreements_pages_test.rb`, `commercial_terms_forms_test.rb`, `portal_pages_test.rb` | Telas com `Rack::Lint`: filtros, erros no campo, controle otimista, papéis, XSS e CSRF, tarifas nos formulários e detalhamento de valores para a equipe e para o cliente |
| `test/http/commercial_terms_legacy_snapshot_test.rb` | Snapshot de preços no formato da 1.0.0 (cupom só em `coupon_code`, sem condições) nas telas da equipe e do portal, na API, nos termos e no PDF |
| `test/http/commercial_terms_api_test.rb`, `commercial_terms_api_agreements_test.rb` | API: cadastro, consulta por código, `PATCH` com `null` e sem mudança, idempotência, inteiros estritos, escopos, isolamento, usos conforme os escopos, condições e tarifas na criação de reserva |
| `test/cli/commercial_terms_test.rb` | Comandos em saída humana e JSON, códigos de saída, escopos, auditoria e isolamento |
| `test/browser/commercial_terms_test.rb` | Cadastro de cupom, tarifa e condição até a reserva, e nova versão de orçamento por atendente, no navegador |

## Limitações

- Cupons não se aplicam a orçamentos nem a solicitações do portal.
- Tarifas pela API na criação de reserva e nas versões de orçamento; a reserva convertida copia as tarifas da
  versão aprovada.
- O livro de usos não é reconstruído para reservas anteriores à migration 0015: os usos da 1.0.0 aparecem
  somente no contador legado do cupom.
- Não há evento de webhook para alterações de cadastro.
- A CLI não edita cupons nem gerencia tarifas.
