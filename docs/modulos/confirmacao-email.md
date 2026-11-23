# Módulo de confirmação de e-mail

Cobre RF-05 (confirmação de e-mail) como restrição de uso: a conta criada pelo cadastro opera normalmente
dentro da organização, mas não executa ações que fazem a plataforma agir para fora em nome dela até confirmar
o e-mail e, depois de 7 dias sem confirmação, fica somente leitura. Decisão em `docs/DECISOES.md` (ADR-031).

| Camada | Arquivos |
|---|---|
| Migration | `db/migrations/0018_confirmacao_email_usuarios_existentes.sql` (somente dados) |
| Domínio | `Domain::Identity::EmailConfirmation` e `Domain::Identity.mutation?` em `lib/locentra/domain/identity.rb`; `Domain::EmailUnconfirmed` em `lib/locentra/domain/errors.rb` |
| Aplicação | `Actor#email_status`, `Authorizer.authorize!(read:)`, `Authorizer.writable!`, `Authorizer.confirmed_email!` e `UnitOfWork#run(read:)` em `lib/locentra/application/base.rb`; `Identity::ResendEmailConfirmation`; confirmação no aceite de convites (`Organizations::AcceptInvitation`, `Portal::AcceptInvitation`); verificação nos casos de uso da tabela abaixo |
| Persistência | `AccessRepository#active_membership` (confirmação e criação do usuário) e `SessionRepository#find_by_digest` (`user_created_at`) em `lib/locentra/infrastructure/persistence/identity.rb` |
| Interface | `POST /confirmar-email/reenviar` (`AuthController#resend_confirmation`), aviso em `views/shared/email_confirmation.html.erb` incluído por `views/layouts/application.html.erb`, estilo `.email-banner` em `public/css/app.css`, `RequestContext#email_confirmation` preenchido pelo `Authenticator`, `403` `email_unconfirmed` no tratamento central de erros |

## Regras

### Situação da conta

`Domain::Identity::EmailConfirmation.standing(confirmed_at:, created_at:, now:)` devolve uma de três situações:

| Situação | Condição | Efeito |
|---|---|---|
| `confirmed` | `users.email_confirmed_at` preenchido | nenhuma restrição |
| `pending` | sem confirmação e `now < users.created_at + 7 dias` | ações para fora recusadas; operação interna liberada |
| `read_only` | sem confirmação e `now >= users.created_at + 7 dias` | toda alteração recusada; consultas liberadas |

O prazo é a constante inteira `GRACE_PERIOD_SECONDS` (`7 * 86_400`), somada ao instante de criação; o limite
é exato (no instante `created_at + 7 dias` a conta já é somente leitura) e o tempo restante é inteiro,
arredondado para cima. O instante vem sempre do relógio injetado (`System#clock`), o mesmo nos casos de uso e
no aviso da interface.

A `UnitOfWork` calcula a situação dentro da transação, na revalidação do vínculo (`active_membership` traz
`email_confirmed_at` e `created_at` do usuário), e a grava em `Actor#email_status`. A confirmação vale na
operação seguinte, mesmo com a sessão aberta.

### Ações bloqueadas até a confirmação

Recusadas com `Domain::EmailUnconfirmed` (`code` `email_unconfirmed`, `reason` `:outbound`) por
`Authorizer.confirmed_email!`, chamado no caso de uso, dentro da transação e antes de gravar ou enfileirar
qualquer coisa (a recusa não deixa registro):

| Ação (`OUTBOUND_ACTIONS`) | Caso de uso | Por que age para fora |
|---|---|---|
| `members.invite` | `Organizations::InviteMember` | e-mail de convite para terceiro |
| `credentials.create` | `Integrations::CreateCredential` | credencial que age em nome da organização em sistemas externos |
| `webhooks.create` | `Webhooks::CreateEndpoint` | chamadas assinadas para um destino externo |
| `webhooks.resume` | `Webhooks::ResumeEndpoint` | libera as entregas retidas para o destino |
| `webhooks.redeliver` | `Webhooks::Redeliver` | nova chamada ao destino externo |
| `payments.configure` | `Finance::ConfigureProviderAccount` | conta no provedor de pagamentos |
| `payments.request` | `Finance::RequestPayment` | cobrança criada no provedor, que pode notificar o cliente |
| `quotes.send` | `Quotes::SendQuote` | e-mail do orçamento ao cliente (`quote.sent`) |
| `contracts.issue` | `Contracts::IssueContract` (somente a emissão nova; o contrato já emitido é devolvido) | e-mail do contrato ao cliente (`contract.issued`) |
| `portal.invite` | `Portal::InviteContact` | e-mail de convite do portal ao contato do cliente |

A mensagem segue o formato "Confirme seu e-mail para <ação>: abra o link enviado ao seu e-mail ou peça o reenvio
da confirmação.". Ficam liberados, por serem operação interna ou consequência dela: reservas (inclusive os
e-mails transacionais de reserva confirmada, cancelada ou estendida, que acompanham a própria operação),
orçamentos em rascunho e novas versões, aprovação e conversão, aditivo, cancelamento e encerramento de contrato,
retirada, devolução, inspeções, avarias, manutenção, transferências, pagamentos manuais, reembolsos, cauções,
faturas, conciliação, configurações e filiais, desativação de endpoint e de conta do provedor, revogação de
credenciais e de acessos. Notificações internas e as tarefas do worker (ator `system`) não passam pela regra.

### Conta somente leitura

`Authorizer.authorize!` recusa (`reason` `:read_only`) toda permissão que altera dados
(`Domain::Identity.mutation?`: as permissões da matriz que não terminam em `.read`) quando a conta está
somente leitura. Consultas que usam uma permissão de alteração declaram `read: true` e continuam liberadas: lista
de credenciais, lista de endpoints e entregas de webhook, contas do provedor de pagamentos, configurações da
organização e prévia, tarefas com falha e download de anexos de avarias e devoluções. Continuam liberados também,
por não passarem por permissão de alteração: entrar, sair, trocar de organização, confirmar o e-mail pelo link e
reenviar a confirmação.

### Reenvio

`Identity::ResendEmailConfirmation` enfileira `email.confirmation` para o usuário da sessão; o worker emite o
token no envio e invalida os links anteriores. Conta já confirmada recebe "Seu e-mail já está confirmado." sem
envio. Limites (ADR-026): 20 pedidos por IP por hora na rota e 3 por usuário por hora no caso de uso; acima deles,
`429` com `Retry-After`.

### Convites

O link do convite chega somente ao endereço convidado, que precisa ser o e-mail da conta:

- **Equipe:** a conta criada pelo aceite já nasce confirmada; a conta existente de mesmo e-mail que aceita o
  convite fica confirmada (`users.confirm_email`, sem alterar uma confirmação anterior).
- **Portal do cliente:** igual. O ator `customer` não passa pela regra: as operações do portal (solicitação de
  reserva, aprovação de orçamento, aceite de contrato) são do próprio cliente, não ações em nome da organização,
  e a conta do portal é sempre confirmada pelo link do convite.

### Credenciais de API e CLI

Credenciais não têm situação de e-mail e não recebem `email_unconfirmed`: só são criadas por usuário confirmado
(`credentials.create`), e a confirmação não é desfeita (não há troca de e-mail). As credenciais existentes antes
desta versão foram criadas por usuários que a migration 0018 considera confirmados. A regra já existente continua
valendo: credencial de criador sem vínculo ativo é recusada.

### Usuários existentes (migration 0018)

A migration considera confirmados todos os usuários sem confirmação no momento da atualização, com
`email_confirmed_at` igual ao instante da transação (o mesmo de `schema_migrations.applied_at` da 0018). Sem ela,
um proprietário cadastrado há mais de 7 dias que nunca abriu o link ficaria somente leitura na troca de versão,
sem aviso prévio; numa instalação sem envio de e-mail configurado, não teria como sair dessa situação.
Procedimento e retorno em `docs/RUNBOOKS.md`, seção 17.

## Interface web

- Aviso fixo no topo do layout da equipe (`position: sticky`, `role="status"`) para sessão de equipe não
  confirmada: "Confirme seu e-mail para liberar convites, credenciais, webhooks, pagamentos e envios a clientes."
  com os dias restantes e a data limite no fuso da organização; depois do prazo, "Conta somente leitura até a
  confirmação." com a data em que o prazo terminou. O aviso aparece em todas as páginas do layout da equipe,
  inclusive nas de erro; as páginas públicas (entrada e seleção de organização) não o exibem.
- Botão **Reenviar confirmação**: formulário `POST /confirmar-email/reenviar` com o token CSRF da sessão e o
  caminho atual (`voltar`, somente caminho local); sem script.
- Ação bloqueada: a mensagem do domínio aparece onde a interface já mostra os erros de negócio da ação: no
  formulário reexibido (convite de membro, credencial, cadastro de webhook, provedor e cobranças do financeiro,
  envio de orçamento), no aviso depois do redirecionamento (emissão de contrato, reativação e reenvio de webhook,
  convite do portal) ou na página de erro `403` (demais alterações da conta somente leitura).

## API v1

Por sessão de usuário (cookie e `X-CSRF-Token`), a recusa responde `403` com `error.code` `email_unconfirmed` e a
mensagem do domínio (documentado em `docs/openapi.yaml`). Credenciais nunca recebem esse código.

## CLI

A CLI operacional usa credenciais do tipo `cli`: não há efeito. `locentra-admin db:seed` confirma o e-mail dos
proprietários e cria os membros por convite aceito, como antes.

## Observabilidade

Cada recusa incrementa `locentra_domain_conflicts_total{code="email_unconfirmed"}` na `UnitOfWork`, sem rótulos
de usuário ou organização; a resposta `403` aparece em `http_requests_total`. A recusa desfaz a transação, então
não há linha de auditoria.

## Testes

| Arquivo | Cobertura |
|---|---|
| `test/unit/domain/email_confirmation_test.rb` | constante inteira do prazo, limites exatos no segundo e em frações de segundo, arredondamento, mensagens, permissões de consulta |
| `test/unit/application/email_confirmation_gate_test.rb` | situação calculada com o relógio injetado, recusa e métrica, `read: true`, transação composta, credenciais, worker e cliente fora da regra |
| `test/integration/email_confirmation_test.rb` | cada ação bloqueada recusada sem efeito e aceita depois da confirmação, operação interna liberada, somente leitura no prazo exato com consultas liberadas, reenvio com limite, aceite de convite da equipe e do portal confirmando a conta |
| `test/http/email_confirmation_pages_test.rb` (Rack::Lint) | aviso e prazo, reenvio com CSRF e limites por usuário e por IP, mensagens, navegação de todas as páginas da equipe na conta somente leitura, troca de organização e saída, `403` `email_unconfirmed` conferido contra o OpenAPI |
| `test/browser/email_confirmation_test.rb` | aviso fixo, reenvio pelo botão sem violar a CSP, conta somente leitura |
| `test/repository/migration_0018_test.rb` | atualização de um banco da 1.3.0: usuários confirmados pela migration, confirmações anteriores intactas, proprietária antiga volta a operar, cadastros novos seguem a regra |
