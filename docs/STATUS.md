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

## Incremento 3 — Worker, notificações e integrações

| Item | Situação | Evidência |
|---|---|---|
| Worker com threads limitadas, lease, fencing, heartbeat, backoff, `dead` e reprocessamento | Implementado e testado | `test/integration/worker_test.rb` |
| Agendador com chave única por janela (expiração de bloqueios por organização, limpeza) | Implementado e testado | `test_scheduler_fanout_expires_holds_per_organization_once` |
| Encerramento gracioso (TERM/INT) | Verificado manualmente com `bin/worker` e `docker stop` | logs `worker.stopping`/`worker.stopped` |
| E-mails transacionais (confirmação, recuperação, convite, reservas) via SMTP | Implementado e testado com mailer em memória; entrega real verificada no Mailpit local | `worker_test.rb` |
| Outbox → webhooks assinados com identificador estável e retentativas | Implementado e testado com servidor HTTP local | `test_events_are_dispatched_to_signed_webhooks_with_stable_ids` |
| Proteção SSRF, cifragem de segredos, assinatura | Implementado e testado (sem rede) | `test/unit/infrastructure/security_adapters_test.rb` |
| Anexos com detecção de tipo, download autenticado e isolamento | Implementado e testado | `test_attachments_upload_download_and_tenant_isolation` |
| Tela de integrações (endpoints e entregas, reenvio) | Implementado e testado (renderização) | `pages_test.rb` |

## Limitações conhecidas

- Orçamentos, contratos/PDF, retirada/devolução, manutenção, financeiro, portal do cliente, CLI
  operacional e testes de navegador estão planejados para os próximos incrementos.
- Adaptador de object storage não implementado; somente armazenamento local (fora do diretório
  público). A interface do adaptador está documentada em ADR-022.
- Métricas de contadores por processo (Prometheus) refletem apenas o processo consultado; métricas de
  fila vêm de agregados gravados pelo worker em `queue_stats`.
