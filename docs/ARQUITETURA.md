# Arquitetura do Locentra

Monólito modular com arquitetura hexagonal pragmática. Este documento evolui junto com o código;
o estado de cada parte está em `docs/STATUS.md`.

## Camadas

| Camada | Diretório | Responsabilidade | Pode depender de |
|---|---|---|---|
| Domínio | `lib/locentra/domain` | Entidades, value objects, máquinas de estado e regras puras | stdlib, tzinfo |
| Aplicação | `lib/locentra/application` | Casos de uso: autorização, coordenação de domínio, transações e portas | Domínio |
| Infraestrutura | `lib/locentra/infrastructure` | PostgreSQL, pool, repositórios SQL, fila, e-mail, PDF, arquivos, provedores | Domínio, Aplicação |
| Interfaces | `lib/locentra/interfaces/{http,cli}` | Rack/Puma, API, interface web, CLI | Aplicação |
| Composição | `lib/locentra/system.rb` | Composition root: monta dependências a partir da configuração | Todas |

Carregar `locentra/domain` não abre conexões, não inicia threads e não lê variáveis de ambiente.

## Motor de disponibilidade (domínio)

- `Period`: intervalo `[início, fim)` em UTC; períodos adjacentes não se sobrepõem.
- `Availability::Peak`: ocupação máxima simultânea por varredura de eventos, recortada à janela
  consultada. Em empates, saídas são processadas antes de entradas.
- `Availability::StockLedger`: capacidade de estoque quantitativo; disponível = capacidade − pico.
- `Availability::AssetSchedule`/`AssetPicker`: ativos individuais livres na janela, considerando
  bloqueios operacionais (inspeção, manutenção, trânsito) e seleção determinística sem repetição.
- `Availability::DemandExpander`: expande kits em componentes e agrega a demanda por produto físico,
  para que o mesmo componente pedido por caminhos diferentes seja verificado contra uma única capacidade.

As garantias sob concorrência ficam no PostgreSQL (seção a ser detalhada com a fatia de reservas).

## Persistência e transações

- `Infrastructure::Database::ConnectionPool`: pool por processo (gem `connection_pool`), conexões
  criadas sob demanda, descarte das herdadas após fork, `ROLLBACK` defensivo e descarte de conexões
  quebradas na devolução, `statement_timeout` e `idle_in_transaction_session_timeout`.
- `Transactor`: abre a transação, define `app.tenant_id`/`app.user_id` com escopo local, repete em
  deadlock ou falha de serialização e proíbe transações aninhadas na mesma thread.
- `Transaction`: SQL parametrizado (`exec_params`), codificação explícita de parâmetros, tradução de
  violações de constraint para erros de domínio, savepoints e ações pós-commit.
- Repositórios em `infrastructure/persistence` mapeiam linhas para entidades explicitamente.
  Ordenação e filtros dinâmicos usam allowlist; buscas escapam curingas de `LIKE`.

## Isolamento entre organizações

1. O tenant vem do ator autenticado (sessão, credencial ou portal), nunca de parâmetros.
2. `UnitOfWork` revalida o vínculo na transação e autoriza pela matriz de permissões.
3. Consultas filtram `organization_id` explicitamente.
4. RLS forçada em todas as tabelas de tenant, com papéis sem `BYPASSRLS`.
5. Chaves estrangeiras compostas impedem referências entre organizações.
6. Recursos de outro tenant retornam "não encontrado" (sem enumeração).

## Garantias de disponibilidade sob concorrência

| Recurso | Mecanismo | Efeito |
|---|---|---|
| Ativo individual | Exclusion constraint em `asset_allocations` | Duas alocações ativas do mesmo ativo não podem se sobrepor; a segunda transação recebe violação e tenta outra unidade livre |
| Estoque quantitativo | `SELECT ... FOR UPDATE` no `stock_pools`, em ordem de id | Cálculo de pico e inserção serializados por estoque |
| Bloqueio temporário | Lock da reserva + comparação com `hold_expires_at` | Confirmação e expiração concorrentes têm resultado determinístico |
| Varredura de expiração | `FOR UPDATE SKIP LOCKED` | Não disputa reservas em confirmação |
| Contador de códigos | Atualização no fechamento da transação | Não serializa alocações |

## Camada HTTP

Aplicação Rack explícita (`interfaces/http/app.rb`): `RequestLogger` (request id, log estruturado e
métricas por rota modelo) → `Rack::Static` → `BodyLimit` → `SecurityHeaders` (CSP sem
`unsafe-inline`) → roteador com tabela explícita → autenticação por modo (`public`, `login`,
`session`, `portal`, `api`) → CSRF → controlador → erros centralizados (HTML ou JSON estruturado).
Templates ERB compilados uma vez, com escape automático. JavaScript em módulos ES sem scripts inline.
