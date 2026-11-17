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
