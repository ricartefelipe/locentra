# Status de implementação

Atualizado a cada incremento. "Testado" indica a existência de testes automatizados executados com
sucesso no incremento indicado.

## Incremento 1 — Fundação

| Item | Situação | Evidência |
|---|---|---|
| Ruby 4.0.9, Gemfile e lockfile fixados | Implementado | `Gemfile.lock` |
| Imagem Docker (dev, build, runtime) | Implementado | `Dockerfile` |
| Compose com PostgreSQL 18 e Mailpit | Parcial: web/worker/migrate dependem dos executáveis do incremento 2 | `docker-compose.yml` |
| CI: RuboCop, Bundler Audit, Gitleaks, testes unitários, build e Trivy | Implementado | `.github/workflows/ci.yml` |
| Dinheiro (`Money`) | Implementado e testado | `test/unit/domain/money_test.rb` |
| Períodos (`Period`) e fusos (`TimeZone`) | Implementado e testado | `test/unit/domain/period_test.rb`, `time_zone_test.rb` |
| Motor de disponibilidade (pico, estoque, ativos, kits) | Implementado e testado (inclui propriedades) | `test/unit/domain/availability_test.rb` |

## Limitações conhecidas

- Persistência, HTTP, interface web, CLI e worker ainda não implementados neste incremento.
