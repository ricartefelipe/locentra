# Matriz de permissões

Fonte única: `Locentra::Domain::Identity::PERMISSIONS` (`lib/locentra/domain/identity.rb`). A mesma matriz é
aplicada à interface web, à API (para credenciais, as permissões são concedidas como escopos), à CLI e às
telas de navegação. A tabela abaixo foi gerada a partir do código.

| Permissão | Proprietário | Administrador | Gerente | Atendente | Operador de estoque | Financeiro | Auditor |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `organization.manage` | ✓ | ✓ |  |  |  |  |  |
| `subscription.manage` | ✓ |  |  |  |  |  |  |
| `members.read` | ✓ | ✓ | ✓ |  |  |  | ✓ |
| `members.manage` | ✓ | ✓ |  |  |  |  |  |
| `integrations.manage` | ✓ | ✓ |  |  |  |  |  |
| `customers.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `customers.write` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `catalog.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `catalog.write` | ✓ | ✓ | ✓ |  | ✓ |  |  |
| `assets.write` | ✓ | ✓ | ✓ |  | ✓ |  |  |
| `availability.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `reservations.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `reservations.write` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `reservations.cancel` | ✓ | ✓ | ✓ |  |  |  |  |
| `quotes.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `quotes.write` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `contracts.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `contracts.write` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `fulfillment.write` | ✓ | ✓ | ✓ | ✓ | ✓ |  |  |
| `inspections.write` | ✓ | ✓ | ✓ |  | ✓ |  |  |
| `maintenance.write` | ✓ | ✓ | ✓ |  | ✓ |  |  |
| `damage_charges.approve` | ✓ | ✓ | ✓ |  |  |  |  |
| `finance.read` | ✓ | ✓ | ✓ |  |  | ✓ | ✓ |
| `finance.write` | ✓ | ✓ |  |  |  | ✓ |  |
| `finance.refund` | ✓ | ✓ |  |  |  | ✓ |  |
| `deposits.manage` | ✓ | ✓ | ✓ |  |  | ✓ |  |
| `audit.read` | ✓ | ✓ |  |  |  |  | ✓ |
| `jobs.manage` | ✓ | ✓ |  |  |  |  |  |
| `reports.export` | ✓ | ✓ | ✓ |  |  | ✓ | ✓ |

Desconto manual máximo: Proprietário 100%, Administrador 100%, Gerente 20%, Atendente 5%; demais papéis: 0%.

## Regras complementares

- **Revalidação por operação:** `Application::UnitOfWork#run` recarrega, dentro da transação, o vínculo do
  ator (membro ativo, credencial válida e não expirada, ou acesso de portal ativo). Revogação e mudança de
  papel valem na requisição seguinte.
- **Atribuição de papéis:** o proprietário atribui qualquer papel exceto proprietário; o administrador atribui
  papéis abaixo de administrador; o proprietário não pode ser removido nem rebaixado; administradores só
  são removidos pelo proprietário.
- **Credenciais de integração (API e CLI):** cada credencial tem escopos (subconjunto das permissões de quem a
  criou), organização, validade e revogação. O tenant vem do token, nunca de parâmetros.
- **Cliente (portal):** ator `customer` com a permissão `portal.access`, sempre restrito ao próprio
  `customer_id`; recursos de outros clientes respondem como inexistentes.
- **Worker (`system`):** executa somente tarefas enfileiradas pela própria aplicação, sempre no contexto de
  tenant da tarefa.
