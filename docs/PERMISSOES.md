# Matriz de permissões

Fonte única: `Locentra::Domain::Identity::PERMISSIONS` (`lib/locentra/domain/identity.rb`). A mesma matriz é
aplicada à interface web, à API (para credenciais, as permissões são concedidas como escopos), à CLI e às
telas de navegação. A tabela abaixo foi gerada a partir do código e é conferida por
`test/unit/domain/permissions_doc_test.rb`.

| Permissão | Proprietário | Administrador | Gerente | Atendente | Operador de estoque | Financeiro | Auditor |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `organization.manage` | ✓ | ✓ |  |  |  |  |  |
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
| `coupons.read` | ✓ | ✓ | ✓ | ✓ |  | ✓ | ✓ |
| `coupons.write` | ✓ | ✓ | ✓ |  |  |  |  |
| `price_agreements.read` | ✓ | ✓ | ✓ | ✓ |  | ✓ | ✓ |
| `price_agreements.write` | ✓ | ✓ | ✓ |  |  |  |  |
| `fees.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `fees.write` | ✓ | ✓ | ✓ |  |  |  |  |
| `fees.override` | ✓ | ✓ | ✓ |  |  |  |  |
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

Desconto manual máximo: Proprietário 100%, Administrador 100%, Gerente 20%, Atendente 5%; demais papéis: 0%.

## Regras complementares

- **Revalidação por operação:** `Application::UnitOfWork#run` recarrega, dentro da transação, o vínculo do
  ator (membro ativo, credencial válida e não expirada, ou acesso de portal ativo). Revogação e mudança de
  papel valem na requisição seguinte.
- **Atribuição de papéis:** o proprietário atribui qualquer papel exceto proprietário; o administrador atribui
  papéis abaixo de administrador e só altera membros com esses papéis; o proprietário não pode ser
  removido nem rebaixado; administradores só são alterados e removidos pelo proprietário.
- **Credenciais de integração (API e CLI):** cada credencial tem escopos (subconjunto das permissões de quem a
  criou), organização, validade e revogação. O tenant vem do token, nunca de parâmetros. Os escopos
  efetivos ficam limitados às permissões do papel atual de quem a criou (rebaixamento vale na requisição
  seguinte), e a revogação do vínculo desse membro revoga as credenciais criadas por ele.
- **Condições comerciais** (cupons, condições negociadas e tarifas adicionais; ver
  [módulo](modulos/condicoes-comerciais.md)):
  - aplicar um cupom e aplicar uma tarifa do catálogo pelo valor padrão exigem somente
    `reservations.write` (reserva) ou `quotes.write` (orçamento, que não aceita cupom);
  - tarifa com valor acima do padrão e tarifa avulsa (fora do catálogo) exigem `fees.override`;
  - tarifa com valor abaixo do padrão exige `fees.override` e a redução fica limitada ao desconto manual
    máximo do papel, calculado sobre o valor padrão (gerente: até 20%). Credenciais de integração têm limite 0:
    mesmo com o escopo `fees.override`, não reduzem tarifas;
  - na nova versão de um orçamento, as tarifas mantidas da versão anterior (mesma tarifa e mesmo valor, ou
    tarifa avulsa com a mesma descrição e o mesmo valor) não exigem `fees.override`: um atendente revisa o
    orçamento sem perder nem alterar ajustes autorizados por um gerente. Cada entrada anterior vale para uma
    única entrada da nova versão; repetir uma tarifa avulsa mantida é um ajuste novo e exige `fees.override`;
  - nas consultas, os dados de outros cadastros seguem as permissões deles: os usos de um cupom mostram a
    reserva somente com `reservations.read` e o cliente somente com `customers.read`; as condições
    negociadas mostram SKU e nome do produto somente com `catalog.read`;
  - a exclusão de cupom (somente de cupom nunca usado) existe apenas na interface web, com `coupons.write`;
  - credenciais criadas antes destas permissões não ganham os escopos novos: é preciso criar outra
    credencial com os escopos desejados. Para os papéis, as permissões valem imediatamente.
- **Cliente (portal):** ator `customer` com a permissão `portal.access`, sempre restrito ao próprio
  `customer_id`; recursos de outros clientes respondem como inexistentes.
- **Worker (`system`):** executa somente tarefas enfileiradas pela própria aplicação, sempre no contexto de
  tenant da tarefa.
