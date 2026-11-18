# Módulo do portal do cliente

Cobre RF-38 (portal do cliente: disponibilidade, solicitação de reserva, aprovação de orçamento,
acompanhamento de contrato e cobranças) e, no portal, RF-04 (revogação com efeito imediato), RF-21
(aceite eletrônico simples pelo cliente), RF-34 (download autenticado de documentos) e RF-42
(funcionalidade `portal` do plano).

| Camada | Arquivos |
|---|---|
| Migration | `db/migrations/0011_portal_cliente.sql` |
| Domínio | `lib/locentra/domain/portal.rb` |
| Aplicação | `lib/locentra/application/portal.rb` (e `tx:` em `Availability::CheckAvailability`, `PlanLimits#includes?`, `Finance::Queries#customer_statement`, escopo de `Attachments::Download`) |
| Persistência | `lib/locentra/infrastructure/persistence/portal.rb` (e `for_customer`/`customer_totals` em recebíveis e cauções, `customer_document?` em contratos, `revoke_portal_for_organization` em sessões) |
| Worker | `email.portal_invitation` em `interfaces/worker/handlers.rb`, `views/mailer/portal_invitation.text.erb` |
| Interface | `web/portal_controllers.rb`, `views/layouts/portal.html.erb`, `views/portal/`, `views/customers/portal_access.html.erb` |
| Composição | `System#build_portal_use_cases`, `services[:portal_scope]`, `Routes.draw_portal` |

## Modelo de dados

| Tabela | Conteúdo | Proteções |
|---|---|---|
| `portal_invitations` (nova) | Cliente, contato convidado, e-mail (do contato), SHA-256 do token, quem convidou, validade, aceite (instante e usuário) e cancelamento (instante e autor) | `organization_id NOT NULL`, `UNIQUE (organization_id, id)`, FK composta `(organization_id, customer_id, contact_id)` para `customer_contacts` (o contato pertence ao cliente), índice único do token, índice único parcial de convite pendente por e-mail na organização, CHECKs de coerência, trigger `portal_invitations_protect` (convite aceito ou cancelado não muda; dados de origem imutáveis), `DELETE` revogado, RLS forçada |
| `portal_accesses` (migration 0005, alterada) | Novas colunas `contact_id`, `invitation_id`, `revoked_by`, `updated_at` | FKs compostas para o contato do cliente e para o convite, CHECK `revogado ⇔ revoked_at`, `DELETE` revogado; `UNIQUE (organization_id, user_id)` já existente: um usuário acessa o portal de uma organização como um único cliente |
| `customer_contacts` (alterada) | Restrição `UNIQUE (organization_id, customer_id, id)` | Alvo das FKs que amarram contato e cliente |

A política `own_portal_read` (migration 0005) continua permitindo que o usuário leia os próprios
acessos sem tenant, para a lista de `/organizacoes`.

## Regras

### Concessão (equipe)

- `Portal::InviteContact`: permissão `customers.write`, ator usuário da equipe e funcionalidade
  `portal` do plano (`PlanLimits#feature!`, com lock da assinatura). O convite vai para o e-mail de
  um contato do próprio cliente (contato de outro cliente: "não encontrado"; contato sem e-mail ou
  cliente bloqueado/inativo: erro de validação).
- E-mail com acesso ativo na organização não recebe convite (`portal_already_granted` para o mesmo
  cliente, `portal_other_customer` para outro). Um novo convite para o mesmo e-mail cancela o pendente.
- Como em `email.invitation` (ADR-019), a fila guarda só `invitation_id`; o worker emite o token
  `<organização>.<segredo>` no envio, grava somente o SHA-256 e envia o link `/portal/convite?token=`.
  Convite aceito, cancelado ou vencido não gera e-mail. Validade: 7 dias (o instante final pertence ao
  período vencido).
- `Portal::CancelInvitation` cancela convite ainda não aceito.

### Aceite

- `Portal::AcceptInvitation` (transação anônima com o tenant extraído do token e confirmado pelo hash):
  convite pendente, plano com `portal` e cliente ativo. Sem sessão, cria o usuário (nome e senha pela
  política de senhas; e-mail considerado confirmado pelo próprio link); se já houver conta com o
  e-mail, exige entrar antes (`login_required`). Com sessão, vincula a conta conectada somente se o
  e-mail for o do convite.
- O acesso é criado ativo; um acesso revogado do mesmo usuário é reativado para o cliente do convite;
  um acesso ativo para outro cliente é recusado.
- A entrada (`/entrar`) preserva o retorno para `/portal/convite`, de modo que quem já tem conta entra
  e volta ao convite. Com sessão, o formulário de aceite exige o token CSRF da sessão.

### Revogação

- `Portal::RevokeAccess` (`customers.write`): marca o acesso como revogado, registra autor e instante e
  encerra as sessões **de portal** do usuário na organização (sessões de equipe do mesmo usuário são
  mantidas).
- Efeito imediato em duas camadas: a autenticação do modo `:portal` consulta o acesso ativo a cada
  requisição e a `UnitOfWork` revalida o acesso dentro de cada transação (inclusive o `customer_id`).
  O acesso também deixa de valer se a organização não estiver ativa.

### Sessões e áreas

- A entrada cria sessão `portal` quando o usuário tem um único vínculo e ele é de portal; o destino
  é `/portal` (ou o retorno solicitado, se for do portal). Com vínculos de equipe e de portal, a
  escolha é feita em `/organizacoes`, que envia também o tipo do vínculo (o mesmo usuário pode ter os
  dois na mesma organização).
- Sessão de portal em rota de equipe (incluindo a API sem credencial Bearer) e sessão de equipe em
  rota do portal geram `WrongArea`: páginas (GET) redirecionam para o início da própria área; demais
  requisições recebem 403 (`wrong_area`). `/anexos/:id` continua aceitando as duas sessões.

### Funcionalidades do cliente

Todas usam o ator `customer` com a permissão `portal.access` e o `customer_id` do acesso; recursos de
outro cliente ou de outra organização resultam em "não encontrado".

| Funcionalidade | Implementação |
|---|---|
| Página inicial | `Portal::Home`: próximas reservas vigentes, orçamentos enviados aguardando decisão, contratos aguardando aceite e total em aberto |
| Disponibilidade | `Portal::CheckAvailability`: compõe `CheckAvailability` na mesma transação (`tx:`) e devolve para cada produto ativo somente nome, descrição, categoria e se atende a quantidade pedida (padrão 1). Totais de frota, ativos e alocações não saem do caso de uso. Período a partir de agora (tolerância das reservas) e de no máximo 90 dias; filial ativa da organização |
| Solicitação de reserva | `Portal::RequestReservation`: `CreateReservation` em modo `request`, origem `portal`, sempre para o cliente do acesso, sem cupom nem desconto manual; não aloca disponibilidade. Tela, mensagem de retorno e detalhe exibem o aviso `Domain::Portal::REQUEST_NOTICE` (a solicitação não garante disponibilidade até a confirmação da locadora) |
| Reservas | `ListReservations`/`GetReservation` (já aceitavam o ator `customer`); a tela recebe somente reserva e itens, nunca as alocações |
| Orçamentos | `ListQuotes` com `sent_only`, `GetQuote` (somente versões enviadas), `ApproveQuote` e `RejectQuote` da versão atual; a aprovação registra tipo `customer`, nome informado, IP e instante |
| Contratos | `ListContracts`, `GetContract` e `AcceptContract` (canal `portal`, com IP, navegador e instante); download do PDF por `/anexos/:id` |
| Cobranças e saldos | `Finance::Queries#customer_statement`: cobranças do cliente com saldo derivado e situação, totais em aberto e de crédito e cauções com saldo retido. Diário contábil, alertas, conciliação e dados do provedor não fazem parte do extrato. A equipe usa a mesma consulta com `finance.read` |

### Downloads

`Portal::ContractDocumentScope` substitui o escopo vazio anterior: o cliente baixa somente anexos
registrados como documento gerado (`contract_documents.attachment_id`) de contratos do próprio
cliente. Anexos do cadastro do cliente, de orçamentos ou anexados manualmente ao contrato pela equipe
continuam restritos à equipe ("não encontrado" para o cliente).

## Interface

| Rota | Autenticação | Função |
|---|---|---|
| `GET/POST /portal/convite` | pública (com sessão, CSRF obrigatório) | Ativação do acesso |
| `GET /portal` | portal | Página inicial |
| `GET /portal/disponibilidade` | portal | Consulta por filial e período, com o formulário de solicitação |
| `POST /portal/reservas` | portal | Solicitação de reserva |
| `GET /portal/reservas`, `GET /portal/reservas/:id` | portal | Reservas próprias |
| `GET /portal/orcamentos`, `GET /portal/orcamentos/:id`, `POST .../aprovar`, `POST .../rejeitar` | portal | Orçamentos enviados e decisão |
| `GET /portal/contratos`, `GET /portal/contratos/:id`, `POST .../aceite` | portal | Contratos, documentos e aceite |
| `GET /portal/financeiro` | portal | Cobranças, saldos e cauções |
| `POST /clientes/:id/portal/convites`, `.../convites/:convite_id/cancelar`, `.../acessos/:acesso_id/revogar` | equipe (`customers.write`) | Gestão de acessos na tela do cliente |

O layout `views/layouts/portal.html.erb` tem navegação própria, nome da locadora e de quem está
conectado, troca de acesso e saída; páginas de erro de atores `customer` também o usam. A tela do
cliente (equipe) ganhou a seção "Acesso ao portal do cliente": acessos com situação e revogação,
convites com situação e cancelamento e o formulário de convite (contatos com e-mail), além do aviso
quando o plano não inclui o portal (`PlanLimits#includes?`, consulta sem lock). Todos os formulários
têm token CSRF, labels e mensagens de erro; nenhum script inline.

## Auditoria e eventos

Auditoria: `portal.invited`, `portal.invitation_cancelled`, `portal.access_granted` (ator `customer`),
`portal.access_revoked`; as operações do cliente usam as ações já existentes (`reservation.created`,
`quote.approved`, `quote.rejected`, `contract.accepted`) com `actor_type = 'customer'`. Os eventos de
outbox são os dos módulos compostos (por exemplo, `reservation.requested`); nenhum evento novo foi
criado.

## Decisões

- **Convites em tabela própria.** `invitations` é dos vínculos de equipe (papel obrigatório e
  contabilizado no limite de usuários); o convite do portal referencia cliente e contato e não ocupa
  vaga de usuário do plano.
- **Um cliente por usuário e organização.** Mantém a restrição da migration 0005 e evita escolher o
  cliente a cada operação; um contato que represente dois clientes usa e-mails distintos.
- **Funcionalidade do plano verificada na concessão e no aceite.** As operações do cliente não
  bloqueiam a assinatura a cada requisição; o rebaixamento do plano impede novos acessos e a equipe
  revoga os existentes.
- **Disponibilidade reduzida a "atende ou não".** A quantidade disponível e o total de unidades são
  dados operacionais da locadora; o cliente recebe a resposta para a quantidade que pretende pedir.
- **Download restrito a documentos gerados.** Mais estrito que "anexos do contrato": arquivos internos
  anexados ao contrato não ficam visíveis ao cliente por engano.
- **Separação de áreas por tipo de sessão.** Mesmo com permissões corretas nos casos de uso, a
  autenticação recusa a sessão da outra área, de modo que nenhuma tela de equipe é renderizada para o
  cliente e vice-versa.

## Limitações

- Não há API v1 para o portal; o acesso do cliente é somente pela interface web.
- O cliente não cancela, reagenda nem estende reservas pelo portal; essas operações continuam com a
  equipe (o portal mostra a situação e o aviso de que a solicitação depende de confirmação).
- Cupons e desconto manual não são aplicados em solicitações do portal; condições negociadas do cliente
  continuam valendo (aplicadas pelo `Pricer`) e outras condições são oferecidas por orçamento.
- O cliente não paga cobranças pelo portal: não há página de pagamento do provedor ligada ao portal; o
  extrato mostra os saldos derivados dos pagamentos registrados pela locadora ou pelo provedor.
- A equipe não recebe notificação específica de nova solicitação do portal; a solicitação aparece na
  lista de reservas como "Solicitada" com origem `portal`.
- Convites são individuais (um contato por vez) e não há reenvio automático do e-mail; um novo convite
  substitui o pendente.

## Como testar

```bash
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/unit/domain/portal_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/portal_flow_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/http/portal_access_pages_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/http/portal_pages_test.rb
docker compose run --rm -e COVERAGE_CHECK=1 dev bundle exec rake test:all
```

| Caso obrigatório | Teste |
|---|---|
| Concessão e aceite pelo e-mail (FakeMailer, token emitido no envio) | `PortalFlowTest#test_invitation_email_carries_token_issued_at_delivery_and_acceptance_creates_user_and_access`, `PortalAccessPagesTest#test_staff_grants_access_by_email_and_contact_activates_it_through_the_pages` |
| Regras de concessão (permissão, plano, contato) e convites substituídos, cancelados e vencidos | `PortalFlowTest#test_grant_requires_permission_plan_feature_and_a_contact_with_email`, `#test_new_invitation_replaces_pending_one_and_closed_invitations_are_not_delivered`, `#test_active_access_blocks_invitations_and_links_to_a_single_customer`, `PortalAccessPagesTest#test_staff_cancels_invitations_and_sees_refusals_on_the_customer_page` |
| Conta existente vinculada após login | `PortalFlowTest#test_existing_account_is_linked_only_after_login_with_the_same_email`, `PortalAccessPagesTest#test_logged_in_account_links_the_invitation_with_csrf` |
| Login no portal e escolha em `/organizacoes` | `PortalAccessPagesTest#test_logged_in_account_links_the_invitation_with_csrf`, `#test_portal_login_honours_portal_return_paths_only` |
| Disponibilidade e solicitação de reserva | `PortalFlowTest#test_availability_hides_internal_data_and_request_creates_portal_request`, `PortalPagesTest#test_availability_check_and_reservation_request_through_the_screens` |
| Reservas e orçamentos (aprovar e rejeitar) | `PortalPagesTest#test_reservations_and_quotes_through_the_screens`, `PortalFlowTest#test_reservations_and_quotes_are_scoped_to_the_customer` |
| Contratos, aceite, PDF próprio permitido e alheio negado | `PortalPagesTest#test_contract_acceptance_pdf_download_and_statement_through_the_screens`, `PortalFlowTest#test_contracts_and_documents_are_scoped_to_the_customer_and_the_organization`, `#test_non_contract_attachments_are_not_downloadable_by_customers` |
| Cobranças e saldos | `PortalFlowTest#test_statement_shows_only_the_customer_charges_and_deposits`, `PortalPagesTest#test_contract_acceptance_pdf_download_and_statement_through_the_screens` |
| Isolamento entre clientes e organizações (404) | `PortalPagesTest#test_resources_of_other_customers_and_organizations_are_not_found`, `PortalFlowTest#test_contracts_and_documents_are_scoped_to_the_customer_and_the_organization` |
| Sessão de portal × rotas de equipe (e vice-versa), CSRF | `PortalAccessPagesTest#test_portal_and_staff_sessions_do_not_cross_and_csrf_is_required` |
| Revogação imediata | `PortalFlowTest#test_revocation_takes_effect_on_the_next_operation_and_reinvitation_reactivates`, `PortalAccessPagesTest#test_revocation_is_immediate_for_open_portal_sessions` |
| Regras de domínio (validade, estados, reativação) | `PortalDomainTest` |
