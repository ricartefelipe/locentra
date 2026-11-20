# Estratégia de isolamento entre organizações

Cada organização contratante é um tenant. A proteção é em camadas: uma falha em uma camada não expõe
dados de outra organização.

| Camada | Mecanismo |
|---|---|
| Identidade | O tenant vem da sessão (organização ativa validada), da credencial (organização embutida no token e verificada pelo hash) ou do acesso de portal. Parâmetros e cabeçalhos nunca definem organização. |
| Aplicação | `UnitOfWork` revalida o vínculo do ator na transação e autoriza pela matriz de permissões. Clientes do portal são restritos ao próprio `customer_id`. |
| Consultas | Toda consulta de tenant filtra `organization_id = $1` explicitamente. |
| Banco: contexto | `set_config('app.tenant_id', ..., true)` local à transação; sem contexto, `app_tenant_id()` é nulo e nenhuma linha é visível. O contexto desaparece no fim da transação e a conexão volta ao pool sem transação aberta. |
| Banco: RLS | `ENABLE` e `FORCE ROW LEVEL SECURITY` em todas as tabelas de tenant, com `USING` e `WITH CHECK`. |
| Banco: papéis | `locentra_app` e `locentra_worker` sem superuser, sem `BYPASSRLS` e sem propriedade de tabelas; `locentra_owner` só para migrations. |
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

## Evidências

`test/repository/tenant_isolation_test.rb` (papel sem bypass, contexto ausente, escrita em outro tenant
recusada pela RLS, FK composta, ids estrangeiros, tenant forjado no ator, revogação imediata) e os testes de
isolamento de cada módulo.
