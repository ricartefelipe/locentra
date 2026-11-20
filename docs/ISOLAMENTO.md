# Estratégia de isolamento entre organizações

Cada organização contratante é um tenant. A proteção é em camadas: uma falha em uma camada não expõe
dados de outra organização.

| Camada | Mecanismo |
|---|---|
| Identidade | O tenant vem da sessão (organização ativa validada), da credencial (organização embutida no token e verificada pelo hash) ou do acesso de portal. Parâmetros e cabeçalhos nunca definem organização. |
| Aplicação | `UnitOfWork` revalida o vínculo do ator na transação e autoriza pela matriz de permissões. Clientes do portal são restritos ao próprio `customer_id`. |
| Consultas | Toda consulta de tenant filtra `organization_id` explicitamente (inclusive atualizações por `id`), além da RLS. |
| Banco: contexto | `set_config('app.tenant_id', ..., true)` local à transação; sem contexto, `app_tenant_id()` é nulo e nenhuma linha é visível. O contexto desaparece no fim da transação e a conexão volta ao pool sem transação aberta. |
| Banco: RLS | `ENABLE` e `FORCE ROW LEVEL SECURITY` em todas as tabelas de tenant, com `USING` e `WITH CHECK`. `TenantIsolationTest#test_every_table_with_organization_id_has_forced_row_level_security` percorre o catálogo e falha se alguma tabela com `organization_id`, fora das exceções abaixo, ficar sem RLS forçada. |
| Banco: papéis | `locentra_app` e `locentra_worker` sem superuser, sem `BYPASSRLS` e sem propriedade de tabelas; `locentra_owner` só para migrations; `locentra_backup` somente leitura, com `BYPASSRLS` e `pg_read_all_data`, usado apenas pelo `pg_dump` (ADR-024). |
| Banco: integridade | Chaves estrangeiras compostas `(organization_id, id)` impedem relacionamentos entre tenants. |
| Respostas | Recurso de outra organização (ou de outro cliente, no portal) retorna "não encontrado" (sem enumeração). |
| Áreas | Sessões de portal não acessam rotas da equipe nem a API sem credencial, e vice-versa. |
| Worker | Cada tarefa executa no contexto de tenant da própria tarefa; o papel do worker só enxerga todas as linhas da fila e da outbox. |
| Arquivos | Chave de armazenamento `<organização>/<anexo>` gerada pelo servidor; download só por rota autenticada que localiza o anexo dentro do tenant. |
| Idempotência, auditoria, webhooks, relatórios | Tabelas de tenant com RLS; chaves de idempotência têm escopo por organização e ator. |
| Métricas | Rótulos de baixa cardinalidade, sem identificadores de cliente, reserva ou organização. |

## Exceções globais documentadas

| Tabela | Motivo |
|---|---|
| `users`, `sessions`, `user_tokens`, `rate_limits` | A autenticação ocorre antes de existir contexto de organização. |
| `plans` | Catálogo de planos da plataforma (somente leitura para a aplicação). |
| `queue_stats`, `job_outcome_totals` | Agregados da fila e desfechos de tarefas por fila e tipo, sem dados de tenant nem identificadores. |
| `organizations` | RLS própria: o tenant ativo, organizações das quais o usuário é membro ou cliente de portal, e leitura pelo worker. |
| `jobs` sem organização | A aplicação pode **inserir** tarefas de e-mail de identidade sem organização, mas não lê-las. |

## Políticas além do isolamento por tenant

| Política | Tabela | Leitura permitida | Motivo |
|---|---|---|---|
| `own_memberships_read` | `memberships` | vínculos do próprio usuário (`app.user_id`), em qualquer organização | Escolha da organização ativa depois da entrada, antes de existir tenant. |
| `own_portal_read` | `portal_accesses` | acessos de portal do próprio usuário | Idem, para o portal do cliente. |
| `member_read`, `portal_org_read` | `organizations` | organizações das quais o usuário é membro ou cliente de portal | Nome das organizações na tela de escolha. |
| `worker_read` | `organizations` | todas, somente para `locentra_worker` | Agendamento por organização (`platform.fanout`) e rotação de segredos. |
| `worker_all` | `jobs`, `job_attempts`, `outbox_events` | todas as linhas, somente para `locentra_worker` | Reivindicação e despacho da fila; cada tarefa executa depois no contexto do próprio tenant. |
| `webhook_account_lookup` | `payment_provider_accounts` | somente a conta indicada em `app.payment_account_id` | Webhook público do provedor: localizar a conta pelo identificador da rota antes de existir tenant; o token é conferido em seguida. |

Não há cache compartilhado entre requisições nem exportação de dados nesta versão; se forem criados, devem
ter chave ou escopo por organização como as demais tabelas.

## Evidências

`test/repository/tenant_isolation_test.rb` (papel sem bypass, contexto ausente, escrita em outro tenant
recusada pela RLS, FK composta, ids estrangeiros, tenant forjado no ator, revogação imediata) e os testes de
isolamento de cada módulo.
