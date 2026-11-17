# Registro de decisões arquiteturais

Formato curto: contexto, decisão e consequências. Decisões substituídas permanecem com o status
atualizado.

## ADR-001 — Ruby 4.0.9

- **Contexto:** a página oficial de branches do Ruby lista 4.0 e 3.4 em manutenção normal; 4.0.9 é a
  versão estável mais recente.
- **Decisão:** Ruby 4.0.9, fixado em `.ruby-version`, no `Gemfile` (`ruby file:`) e na imagem
  `ruby:4.0.9-slim-trixie`.
- **Consequências:** no Ruby 4.0, `bigdecimal`, `csv`, `logger`, `net-smtp`, `minitest` e `rake` são
  bundled gems e precisam ser declaradas no `Gemfile`. `json`, `erb`, `date`, `time`, `securerandom`,
  `openssl`, `optparse`, `net-http`, `uri` e `ipaddr` continuam default gems e não são declaradas.

## ADR-002 — Sem framework de aplicação e sem ORM

- **Decisão:** dependências pontuais: Rack (interface HTTP), Puma (servidor), `pg` (driver),
  `connection_pool` (pool), `bcrypt` (senhas), `tzinfo`/`tzinfo-data` (fusos), `prawn` (PDF),
  `mail` (composição e envio de e-mail). Testes: Minitest, rack-test, SimpleCov, Ferrum.
  Análise: RuboCop, Bundler Audit.
- **Consequências:** roteamento, mapeamento de resultados, transações e migrations são código explícito
  e pequeno do projeto, limitado ao necessário para o produto.

## ADR-003 — `bigdecimal` 3.3 em vez de 4.x

- **Contexto:** Prawn 2.5.0 depende de `ttfunk` 1.8, que exige `bigdecimal ~> 3.1`.
- **Decisão:** fixar `bigdecimal ~> 3.3.1`, compatível com Ruby 4.0. `BigDecimal` é usado apenas para
  interpretar textos decimais; cálculos monetários usam inteiros e `Rational`.

## ADR-004 — PostgreSQL 18

- **Decisão:** PostgreSQL 18 (`postgres:18.7-alpine`), com `btree_gist` para exclusion constraints em
  intervalos `tstzrange`.

## ADR-005 — Intervalos semiabertos, UTC e fuso IANA

- **Decisão:** todos os períodos são `[início, fim)` em UTC com precisão de segundos. Regras locais
  (dia de calendário, horário comercial) usam o fuso IANA da organização. Horários locais inexistentes
  são rejeitados; ambíguos resolvem para a primeira ocorrência (instante UTC mais cedo).

## ADR-006 — Dinheiro em centavos inteiros

- **Decisão:** `Money` encapsula centavos `Integer` e moeda (BRL). `Float` é rejeitado. Percentuais em
  pontos-base; arredondamento meio para cima apenas quando há fração de centavo; rateios pelo método
  do maior resto preservam a soma. A API expõe `amount_cents` (inteiro), `currency` e `formatted`.

## ADR-007 — Identificadores UUIDv7 gerados pela aplicação

- **Decisão:** `SecureRandom.uuid_v7` por meio de um gerador injetável. Mantém localidade temporal nos
  índices e permite identificadores determinísticos em testes.

## ADR-008 — Testes baseados em propriedades sem dependência adicional

- **Decisão:** gerador pseudoaleatório (`Random`) semeado a partir da semente do Minitest, com a semente
  e a iteração reportadas na falha. Evita dependência extra e mantém reprodutibilidade.

## ADR-009 — Ambiente de desenvolvimento em contêineres

- **Decisão:** o fluxo suportado executa Ruby, testes e ferramentas em contêineres (`docker compose`),
  inclusive Chromium para testes de navegador. Ruby local é opcional.

## ADR-010 — Actions do GitHub fixadas por SHA

- **Decisão:** cada action é referenciada por SHA de commit com a tag como comentário; imagens de
  ferramentas usam tags de versão explícitas (sem `latest`).

## ADR-011 — Correções de segurança na imagem

- **Contexto:** a análise da imagem apontou `zlib1g` com correção publicada na Debian e a default gem
  `json` 2.18.0 do Ruby 4.0.9 afetada pela CVE-2026-33210 (corrigida em ≥ 2.19.2).
- **Decisão:** a etapa base executa `apt-get upgrade`; a default gem `json` é removida da imagem e a
  versão corrigida (`json ~> 2.21.2`) é declarada no `Gemfile`. Os executáveis carregam
  `bundler/setup`, portanto usam sempre a versão do lockfile.
- **Consequências:** `ruby -rjson` sem Bundler não funciona na imagem de execução; o healthcheck usa
  somente `net/http`. A análise continua falhando para vulnerabilidades HIGH/CRITICAL corrigíveis.

## ADR-012 — Contexto de tenant local à transação e papéis de banco separados

- **Decisão:** toda operação de negócio abre transação com `set_config('app.tenant_id', ..., true)`
  (escopo local) a partir do ator autenticado. Políticas RLS (`ENABLE` e `FORCE`) comparam
  `organization_id` com `app_tenant_id()`; ausência de contexto resulta em nenhuma linha. Três papéis:
  `locentra_owner` (migrations, proprietário), `locentra_app` (web/CLI) e `locentra_worker` (fila),
  todos sem superuser e sem `BYPASSRLS`. Chaves estrangeiras compostas `(organization_id, id)`
  impedem relações entre tenants mesmo com SQL incorreto.
- **Exceções globais documentadas:** `users`, `sessions`, `user_tokens`, `rate_limits`, `plans` e
  `queue_stats`. `organizations` tem RLS com leitura pelo próprio tenant, por membros ativos e pelo
  worker. Tarefas de e-mail de identidade sem organização podem ser inseridas, mas não lidas, pela
  aplicação.

## ADR-013 — Unidade de trabalho revalida o vínculo em cada operação

- **Decisão:** `Application::UnitOfWork#run` abre a transação e recarrega o vínculo do ator
  (membro ativo, credencial válida ou acesso de portal) antes de autorizar. Revogação e mudança de
  papel valem na operação seguinte, mesmo com sessão aberta.

## ADR-014 — Repositórios recebem a transação explicitamente

- **Decisão:** repositórios não acessam o pool; recebem `tx` como primeiro argumento. Abrir
  transação aninhada na mesma thread gera erro; composição de casos de uso passa `tx:`;
  rollback parcial usa `savepoint`. Conexões voltam ao pool sem transação aberta.

## ADR-015 — Garantias de disponibilidade no PostgreSQL

- **Decisão:** ativos individuais usam exclusion constraint `EXCLUDE USING gist (asset_id WITH =,
  period WITH &&) WHERE (active)`; estoque quantitativo bloqueia a linha do estoque
  (`FOR UPDATE`, em ordem de id) antes de calcular o pico com o domínio. Bloqueios temporários
  vencidos não ocupam disponibilidade e são expirados na transação que precisa do recurso.
- **Consequência:** a confirmação de bloqueio e a expiração concorrentes têm resultado definido pelo
  instante comparado a `hold_expires_at` sob o lock da reserva; a varredura usa `SKIP LOCKED`.

## ADR-016 — Código sequencial da reserva atribuído no fechamento

- **Contexto:** o contador por organização serializava todas as criações de reserva enquanto a
  transação estivesse aberta (detectado pelos testes de concorrência).
- **Decisão:** a reserva é inserida com identificador provisório e recebe o código definitivo no fim
  da transação; o lock do contador dura apenas até o commit. Códigos permanecem sem lacunas.

## ADR-017 — Idempotência na mesma transação da operação

- **Decisão:** a chave é reservada com `INSERT ... ON CONFLICT DO NOTHING` no início da transação da
  operação e o resultado 2xx é gravado antes do commit. Requisições concorrentes equivalentes aguardam
  no índice único e recebem o resultado gravado; conteúdo diferente gera `409`. Falhas não gravam a
  chave.

## ADR-018 — Sessões opacas e templates com escape automático

- **Decisão:** cookie com token aleatório de 256 bits; o banco guarda SHA-256. HttpOnly, SameSite=Lax,
  Secure e prefixo `__Host-` com HTTPS. Rotação em login e troca de organização. CSRF por token
  sincronizado por sessão. ERB com `<%= %>` escapando sempre (subclasse de `ERB` que altera o comando de
  inserção); HTML confiável só por `raw`/helpers. CSP sem `unsafe-inline`.

## ADR-019 — Tokens de uso único emitidos no envio

- **Decisão:** convites, confirmação de e-mail e recuperação de senha enfileiram apenas identificadores;
  o worker emite o token no momento do envio. Tokens nunca ficam gravados em texto claro na fila.
