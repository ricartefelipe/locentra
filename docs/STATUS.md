# Status de implementação

Atualizado a cada incremento. "Testado" indica testes automatizados executados com sucesso no
incremento indicado. Comandos de verificação estão em `CONTRIBUTING.md`.

## Incremento 1 — Fundação (PR #1)

| Item | Situação | Evidência |
|---|---|---|
| Ruby 4.0.9, Gemfile e lockfile fixados | Implementado | `Gemfile.lock` |
| Imagem Docker (dev, build, runtime) com correções de segurança | Implementado | `Dockerfile`, job "Build e análise da imagem" |
| CI: RuboCop, Bundler Audit, Gitleaks, testes unitários, build e Trivy | Implementado | `.github/workflows/ci.yml` |
| Dinheiro, períodos, fusos e motor de disponibilidade | Implementado e testado (inclui propriedades) | `test/unit/domain/*` |

## Incremento 2 — Fatia vertical de reservas

| Item | Situação | Evidência |
|---|---|---|
| Migrations SQL com checksum, advisory lock e credenciais separadas | Implementado e testado | `test/repository/transactor_test.rb` (MigratorTest) |
| RLS forçada, papéis sem superuser/BYPASSRLS, chaves compostas | Implementado e testado | `test/repository/tenant_isolation_test.rb` |
| Pool, coordenador de transações, savepoints, conexões quebradas | Implementado e testado | `test/repository/transactor_test.rb` |
| Organizações, filiais, usuários, convites, papéis, revogação | Implementado e testado | `test/integration/identity_flow_test.rb` |
| Autenticação, sessões, bloqueio por tentativas, rate limit, confirmação de e-mail, recuperação de senha | Implementado e testado (envio do e-mail depende do worker do incremento 3) | idem |
| Planos e limites (ativos, filiais, usuários, funcionalidades) | Implementado e testado | `test_plan_limits_are_enforced` |
| Clientes PF/PJ, contatos, autorizados a retirar, endereços | Implementado e testado | `test/integration/catalog_customers_test.rb` |
| Produtos, kits, ativos individuais, estoque quantitativo, histórico | Implementado e testado | idem |
| Disponibilidade (consulta, calendário, kits, buffers, bloqueios) | Implementado e testado | `reservation_flow_test.rb`, `pages_test.rb` |
| Reservas: solicitação, bloqueio temporário, confirmação, cancelamento, reagendamento, extensão, expiração | Implementado e testado | `reservation_flow_test.rb` |
| Disputas concorrentes (último ativo, estoque, confirmação × expiração) | Testado com conexões separadas e barreiras | `test/concurrency/reservation_race_test.rb` |
| Precificação (hora, diária 24 h, dia de calendário, semana, mínimo, tolerância, faixas, cupons, condições negociadas, multa por atraso, ajuste de extensão) | Implementado e testado (inclui propriedades) | `test/unit/domain/pricing_test.rb` |
| Interface web (login, organizações, painel, clientes, catálogo, ativos, disponibilidade, reservas, usuários, organização, auditoria) | Implementado e testado | `test/http/*` |
| API v1 com OpenAPI, Bearer com escopos, idempotência | Implementado e testado | `test/http/api_test.rb` |
| Rack::Lint, CSRF, XSS, CSP, redirecionamento aberto, limites de payload | Testado | `test/http/web_flow_test.rb` |
| Seed idempotente com duas organizações | Implementado e verificado na CI | job "Reconstrução do banco e seed" |
| Cobertura domínio + aplicação | 98,4% linhas / 87,9% branches na última execução local | `rake test:all` com `COVERAGE_CHECK=1` |

## Limitações conhecidas

- Worker, envio de e-mails, outbox/webhooks, orçamentos, contratos/PDF, retirada/devolução,
  manutenção, financeiro, portal do cliente, CLI operacional e testes de navegador estão planejados
  para os próximos incrementos. As tarefas enfileiradas neste incremento (e-mails e eventos) só serão
  processadas quando o worker existir.
- O serviço `worker` do Compose depende de `bin/worker` (incremento 3).
