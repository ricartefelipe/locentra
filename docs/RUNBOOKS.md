# Runbooks operacionais

Cada procedimento indica se foi **exercitado** (executado de ponta a ponta com resultado registrado) ou se é
**procedimento escrito** (ainda não executado em ambiente real).

## 1. Subir o ambiente local — exercitado em 20/11/2026 (esquema da 1.0.0)

```bash
bin/setup        # build, PostgreSQL + Mailpit, migrations, seed, web e worker
```

Verificar: `curl -fsS localhost:9292/health/live` e `localhost:9292/health/ready` (200 com banco e migrations
em dia; 503 caso contrário); `docker compose ps` com web e worker `healthy`. Mailpit em `localhost:8025`.

O healthcheck da imagem consulta `/health/live` e vale para o processo web. O worker não serve HTTP: o
serviço `worker` do Compose usa `ruby bin/worker --check`, que confere o arquivo de vida
(`WORKER_HEALTH_FILE`, padrão `/app/tmp/worker.alive`) atualizado a cada 20 s pela thread de heartbeat
(vencido após 90 s). Em outro orquestrador, configure o mesmo comando como liveness do worker. Web e worker
têm `stop_grace_period` de 30 s, acima dos 25 s de encerramento gracioso de cada um. Os dois terminam com
código 0 depois da parada graciosa por TERM (o Puma não relança o sinal: `raise_exception_on_sigterm false`).

Registro do exercício (20/11/2026): `bin/setup` executado a partir de uma cópia limpa da árvore commitada, sem
`.env` nem volumes. Imagens construídas, 14 migrations aplicadas, seed carregado e `web`, `worker`,
`postgres` e `mailpit` `healthy`. `/health/live` e `/health/ready` responderam 200, `ruby bin/worker --check`
saiu com 0 e a entrada com `ana@alfa.demo` redirecionou para a escolha de organização. O envio do
formulário de entrada com `Sec-Fetch-Site: cross-site` foi recusado com 403. `docker compose stop web worker`
concluiu em menos de 2 s, com código de saída 0 nos dois serviços.

## 2. Aplicar migrations — exercitado (CI "Reconstrução do banco e seed" a cada PR)

```bash
docker compose --profile ops run --rm migrate          # usa MIGRATION_DATABASE_URL (locentra_owner)
docker compose --profile ops run --rm migrate ruby bin/locentra-admin db:status
```

- Exclusão mútua por `pg_advisory_lock`: execuções simultâneas aguardam.
- `checksum divergente` indica migration aplicada que foi editada: **não** edite o arquivo; restaure o
  conteúdo original e crie uma migration nova.
- A aplicação e o worker nunca usam a credencial de migration.

## 3. Backup do banco e dos anexos — exercitado em 21/11/2026 (esquema da 1.1.0)

Papel dedicado `locentra_backup` (somente leitura, `BYPASSRLS`, membro de `pg_read_all_data`). Como a RLS é
forçada inclusive para o proprietário, um backup feito com o proprietário ou com o papel da aplicação sairia
vazio. O cliente `pg_dump` deve ter a mesma versão principal do servidor (18) ou mais nova.

No ambiente Compose, os anexos de web e worker ficam no volume nomeado `locentra_storage` (montado em
`/app/storage` nos serviços), e não no diretório `./storage` do checkout. O comando monta esse volume somente
para leitura, o diretório do projeto (scripts e destino) e usa a rede do Compose (`locentra_default`):

```bash
docker run --rm --network locentra_default \
  -v "$PWD":/app -w /app -v locentra_storage:/anexos:ro \
  -e BACKUP_DATABASE_URL=postgres://locentra_backup:<senha>@postgres:5432/locentra \
  -e STORAGE_ROOT=/anexos \
  postgres:18.7-trixie bash bin/backup /app/tmp/backups
```

Gera `banco.dump` (formato custom), `banco.indice`, `anexos.tar.gz` e `MANIFESTO.sha256`, e informa quantos
arquivos de anexo foram incluídos. `STORAGE_ROOT` é obrigatório e precisa existir: sem ele (ou com um
caminho inexistente) o script termina com erro antes do dump; omitir os anexos exige
`BACKUP_SKIP_ATTACHMENTS=1`, registrado no arquivo `SEM-ANEXOS` do backup. Fora do Compose, aponte
`STORAGE_ROOT` para o diretório real dos anexos. Guarde o diretório do backup fora do servidor, cifrado,
com retenção definida pela política da operação.

## 4. Restauração — exercitada em 21/11/2026 (esquema da 1.1.0)

Executada por administrador do PostgreSQL (superusuário), sempre em **banco novo**; os proprietários
originais (`locentra_owner`) e as políticas de RLS são preservados.

```bash
docker run --rm --network locentra_default -v "$PWD":/app -w /app \
  -e RESTORE_ADMIN_URL=postgres://postgres:<senha>@postgres:5432/postgres \
  postgres:18.7-trixie bash bin/restore /app/tmp/backups/<carimbo> locentra_restaurado /app/tmp/anexos-restaurados
docker compose --profile ops run --rm \
  -e MIGRATION_DATABASE_URL=postgres://locentra_owner:<senha>@postgres:5432/locentra_restaurado \
  migrate ruby bin/locentra-admin db:status
```

O script reaplica as permissões do banco (o dump não as leva): `PUBLIC` sem acesso, `CONNECT`/`TEMPORARY`
para os papéis da aplicação e `CONNECT` para o backup. A validação roda pelo serviço `migrate`, que está na
rede do Compose e tem Ruby.

Depois de validar, aponte `DATABASE_URL`/`WORKER_DATABASE_URL` para o banco restaurado, grave os anexos no
volume dos anexos e reinicie web e worker:

```bash
docker compose stop web worker
docker run --rm -v "$PWD/tmp/anexos-restaurados":/origem:ro -v locentra_storage:/destino \
  postgres:18.7-trixie bash -c 'cp -a /origem/. /destino/ && chown -R 10001:10001 /destino'
docker compose up -d --wait web worker
```

### Registro do exercício (21/11/2026, PostgreSQL 18.7, branch release/1.1.0, banco da 1.0.0 atualizado)

Banco criado pela 1.0.0 (seed e dados legados), atualizado para a 0015 pelo procedimento da seção 13 e com
um anexo PDF enviado pela tela do cliente. Backup com `bin/backup` (imagem `postgres:18.7-trixie`, papel
`locentra_backup`, volume `locentra_storage` montado somente para leitura) e restauração com `bin/restore` em
banco novo, removido depois da validação.

| Verificação | Resultado |
|---|---|
| Manifesto SHA-256 do backup | conferido antes da restauração; backup informou 1 arquivo de anexo |
| `db:status` no banco restaurado (serviço `migrate`) | 15 migrations aplicadas, sem checksum divergente |
| Contagem de linhas por tabela (origem × restaurado, via `locentra_backup`) | 71 tabelas, 318 linhas, idênticas tabela a tabela (inclui `coupons`, `customer_price_agreements` e `additional_fees`) |
| RLS no banco restaurado com `locentra_app` | sem contexto: 0 cupons; com contexto da organização: 4 cupons, nenhum de outra (5 no total) |
| Permissões do banco restaurado | `PUBLIC` sem acesso; `CONNECT`/`TEMPORARY` para `locentra_app` e `locentra_worker`; `CONNECT` para `locentra_backup` |
| Anexo restaurado | SHA-256 do arquivo igual ao do arquivo enviado e ao registrado em `attachments.sha256` |

Exercícios anteriores: 20/11/2026 (14 migrations, 69 tabelas, 224 linhas, mesmas verificações, todas
conferidas) e 18/11/2026 (10 migrations e 67 tabelas), que encontrou e corrigiu a remoção do schema `public`
pelo script, que o dump não recria.

**Não exercitado:** recuperação em ponto no tempo (arquivamento contínuo de WAL) e restauração a partir de
object storage — dependem da infraestrutura de produção escolhida.

## 5. Tarefas com falha na fila — exercitado (testes de integração do worker)

1. Consultar: CLI operacional (`bin/locentra jobs failures`, com credencial `cli` da organização) ou as
   métricas `locentra_jobs_queue_size{status="dead"}` e `locentra_jobs_dead_total{queue,kind}`. Não há tela
   de tarefas na interface web.
2. Ler `last_error` e o histórico em `job_attempts` (tentativa, worker, resultado, erro).
3. Corrigir a causa (credencial do provedor, destino de webhook, dado inválido).
4. Reprocessar com `bin/locentra jobs retry <id>` usando credencial `cli` com o escopo `jobs.manage`
   (auditado). A tarefa volta a `pending`.

Tarefas sem organização (e-mails de confirmação e de recuperação de senha, `platform.fanout`,
`platform.housekeeping`) não aparecem na CLI operacional, que só enxerga a própria organização. Consulta e
reprocessamento são feitos pelo operador com o papel do worker (sem auditoria de aplicação; registre a
ação no controle de mudanças):

```bash
psql "$WORKER_DATABASE_URL" -c "SELECT id, kind, attempts, last_error, updated_at FROM jobs
  WHERE organization_id IS NULL AND status = 'dead' ORDER BY updated_at DESC LIMIT 50"
psql "$WORKER_DATABASE_URL" -c "UPDATE jobs SET status = 'pending', run_at = now(), attempts = 0, finished_at = NULL,
  updated_at = now() WHERE id = '<id>' AND organization_id IS NULL AND status = 'dead'"
```

`platform.*` é reagendado a cada minuto pelo próprio worker e não precisa ser reprocessado. Um e-mail de
recuperação de senha reprocessado gera um link novo (o anterior é invalidado).

Worker parado ou travado: tarefas `running` com lease vencido voltam a ser reivindicadas por outro worker; o
worker antigo não consegue concluí-las (fencing por `lease_token`). Uma tarefa com lease vencido na última
tentativa permitida termina `dead`.

## 6. Provedor de pagamento indisponível ou resposta perdida — exercitado (testes com simulador)

- Pagamentos em `submission_unknown` **não** são reenviados às cegas: a conciliação consulta o provedor por
  `externalReference` e só então conclui ou reenvia.
- Executar a conciliação manualmente pela tela Financeiro ou pela CLI (`finance reconcile`) e tratar os itens
  divergentes do relatório.
- Webhooks do provedor repetidos são deduplicados por `(organização, provedor, event_id)`.

## 7. Revogar acesso ou credencial comprometida — exercitado (testes de isolamento e API)

- Membro: Usuários e permissões → Revogar acesso (encerra sessões da organização e revoga as credenciais de
  API/CLI criadas pelo membro; efeito imediato). Rebaixar o papel limita, na requisição seguinte, os escopos
  das credenciais criadas por ele.
- Credencial de API/CLI: Usuários e permissões → Revogar. Requisições seguintes recebem 401.
- Sessões de um usuário: redefinição de senha revoga todas as sessões.

## 8. Rotação de segredos — procedimento escrito (rotação da chave de cifragem coberta por teste de integração)

- `APP_SECRET_KEY_BASE`: rotacionar invalida apenas mensagens de retorno (flash) em trânsito.
- `APP_ENCRYPTION_KEY` (segredos de webhook e chaves de API dos provedores, AES-256-GCM):
  1. Gere a chave nova e configure web e worker com `APP_ENCRYPTION_KEY=<nova>` e
     `APP_ENCRYPTION_KEY_PREVIOUS=<antiga>`; reinicie. Valores novos já saem com a chave nova e os antigos
     continuam legíveis, sem interromper entregas de webhook nem chamadas ao provedor.
  2. Regrave todos os segredos com a chave nova (percorre as organizações com o papel do worker; idempotente):
     `docker compose run --rm --no-deps worker ruby bin/locentra-admin secrets:reencrypt --json`
     (o serviço worker já tem `WORKER_DATABASE_URL` e as duas chaves).
  3. Remova `APP_ENCRYPTION_KEY_PREVIOUS` e reinicie. A chave antiga não decifra mais nada; descarte-a.
  Em caso de comprometimento, siga os mesmos passos imediatamente e, em seguida, troque os segredos de
  webhook (novo endpoint) e as chaves de API no provedor, porque os valores antigos podem ter sido lidos.
- Senhas dos papéis do banco: `ALTER ROLE ... PASSWORD` e atualização das URLs; reiniciar processos.

## 9. Retenção de dados operacionais

- Tarefas concluídas (`succeeded`, `cancelled`) e suas tentativas (`job_attempts`) são removidas pelo
  `platform.housekeeping` do worker 14 dias depois de concluídas, em lotes de 5.000 por minuto (índice
  `jobs_finished_idx`). Tarefas `dead` ficam até serem reprocessadas.
- Sessões e tokens de uso único vencidos há 30 dias e janelas de limite de taxa com mais de um dia também
  são removidos.
- Eventos da outbox, entregas de webhook e webhooks recebidos são histórico do negócio (reenvio manual,
  conciliação, auditoria) e não são removidos automaticamente; acompanhe o tamanho dessas tabelas no
  backup e defina, se necessário, um arquivamento conforme a política de retenção da operação.

## 10. Dimensionamento de conexões — procedimento escrito

Conexões máximas = processos web × `DB_POOL_SIZE` (≥ `PUMA_THREADS`) + workers × (`WORKER_CONCURRENCY` +
`WEBHOOK_CONCURRENCY` + 2) +
execuções de CLI/migrations. Mantenha abaixo de `max_connections` com folga. Espera por conexão aparece em
`locentra_db_pool_wait_seconds` e esgotamento em `locentra_db_pool_timeouts_total` (resposta 503).

## 11. Proxy reverso e IP do cliente — procedimento escrito

O IP do cliente alimenta os limites de taxa por IP, as sessões, a auditoria e o aceite de contratos. Sem
`TRUSTED_PROXIES`, a aplicação usa o par da conexão e ignora `X-Forwarded-For` e `Forwarded`. Atrás de um
proxy reverso (nginx, balanceador):

1. Defina `TRUSTED_PROXIES` com os endereços ou faixas do proxy (ex.: `10.0.0.0/8` ou `172.18.0.1`),
   separados por vírgula. Não inclua faixas por onde chegam clientes.
2. Configure o proxy para sobrescrever `X-Forwarded-For` com o endereço real (no nginx,
   `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` a partir de um proxy de borda que não
   aceite o cabeçalho do cliente). O cabeçalho `Forwarded` não é usado.
3. Confira em uma sessão nova (Usuários e permissões ou `sessions.ip`) que o IP gravado é o do cliente.

Limites por IP e por credencial (ADR-026) respondem `429` com `Retry-After`; `API_RATE_LIMIT` ajusta o
limite da API por credencial por minuto.

## 12. Implantação de uma versão publicada — exercitado com imagem local em 21/11/2026 (sem o GHCR)

A publicação está descrita em `CONTRIBUTING.md` (tag anotada `vX.Y.Z`, CI completa e `PUBLISH_IMAGE=true`).
A imagem publicada é `ghcr.io/<repositório>:X.Y.Z`; não existe tag `latest`, então a versão é sempre
explícita.

1. Faça o backup (seção 3).
2. Aplique as migrations com a imagem nova e a credencial do proprietário:
   `docker run --rm -e APP_ENV=production -e MIGRATION_DATABASE_URL=... ghcr.io/<repositório>:X.Y.Z ruby bin/locentra-admin db:migrate`.
3. Substitua web e worker pela imagem nova (mesmas variáveis de ambiente) e confira `/health/ready` (200).
4. Para voltar à versão anterior, use a imagem anterior; migrations são aditivas, mas confirme no
   `CHANGELOG.md` se a versão nova tem migration que a anterior não tolera antes de reverter.

Os passos 1 a 4 foram exercitados na atualização da 1.0.0 para a 1.1.0 (registro na seção 13.5) com imagens
construídas localmente; o download da imagem publicada no GHCR não foi exercitado, porque a publicação não
está habilitada no repositório.

Versões com verificação prévia ou restrição de retorno têm seção própria: migration 0015 na seção 13 e
migration 0016 na seção 14.

## 13. Atualização para a migration 0015 (condições comerciais) — exercitado em 21/11/2026

A migration `0015_condicoes_comerciais.sql` é aplicada numa única transação. A atualização a partir do
esquema da 0014 é coberta por `test/repository/migration_0015_test.rb` (colunas preenchidas, RLS forçada
restaurada, contador de usos preservado, cupons legados fora dos limites novos ainda desativáveis e recusa
de condições sobrepostas). O procedimento abaixo foi exercitado de ponta a ponta sobre um banco criado pela
1.0.0; o registro está na seção 13.5.

### 13.1 Verificação prévia (antes do passo 2 da seção 12)

A versão 1.0.0 aceitava condições negociadas sobrepostas para o mesmo cliente e escopo (valia a de maior
desconto). A 0015 não escolhe qual manter: se encontrar sobreposição, **aborta** com a mensagem
`migração 0015: N par(es) de condições negociadas com vigências sobrepostas (organização …, cliente …)` e
nada é alterado. Confira antes, com o papel `locentra_backup` (somente leitura, `BYPASSRLS`; os demais
papéis não enxergam linhas sem contexto de organização):

```sql
-- psql "postgres://locentra_backup:<senha>@<host>:5432/locentra"
-- 1) Pares sobrepostos (impedem a migration). Na 1.0.0 a vigência é [created_at, valid_until).
SELECT a.organization_id, a.customer_id, a.product_id,
       a.id AS condicao_a, a.discount_bps AS desconto_a, a.created_at AS inicio_a, a.valid_until AS fim_a,
       b.id AS condicao_b, b.discount_bps AS desconto_b, b.created_at AS inicio_b, b.valid_until AS fim_b
  FROM customer_price_agreements a
  JOIN customer_price_agreements b
    ON b.organization_id = a.organization_id AND b.customer_id = a.customer_id
   AND b.product_id IS NOT DISTINCT FROM a.product_id AND b.id > a.id
 WHERE (a.valid_until IS NULL OR a.valid_until > a.created_at)
   AND (b.valid_until IS NULL OR b.valid_until > b.created_at)
   AND a.created_at < COALESCE(b.valid_until, 'infinity')
   AND b.created_at < COALESCE(a.valid_until, 'infinity')
 ORDER BY 1, 2, 3;

-- 2) Vigências inválidas (não impedem a migration; servem para revisão).
SELECT 'condição' AS registro, organization_id, id, created_at AS inicio, valid_until AS fim
  FROM customer_price_agreements WHERE valid_until <= created_at
UNION ALL
SELECT 'cupom', organization_id, id, valid_from, valid_until
  FROM coupons WHERE valid_until <= valid_from OR max_redemptions > 1000000;
```

A consulta 2 lista condições que nunca valeram (fim anterior ao cadastro) e cupons com fim anterior ao início
ou máximo acima de 1.000.000. Essas linhas continuam aceitas depois da migration: o gatilho
`coupons_enforce_limits` verifica somente a inserção e as colunas alteradas, então um cupom nessa situação
pode ser desativado e reativado normalmente (tela **Cupons**, API ou CLI). A edição exige corrigir o campo
inválido, e o erro aparece no próprio campo (**Fim da vigência** ou **Máximo de usos**).

### 13.2 Ajuste das condições sobrepostas

Para cada par da consulta 1, decida com quem responde pela política comercial qual condição continua.
Ainda na versão 1.0.0, ajuste `valid_until` com o papel da aplicação e o contexto da organização (a RLS
exige o contexto; a transação limita o alcance do `set_config`):

```sql
-- psql "postgres://locentra_app:<senha>@<host>:5432/locentra"
BEGIN;
SELECT set_config('app.tenant_id', '<organization_id>', true);
-- Condições sucessivas: a mais antiga termina quando a mais nova começa.
UPDATE customer_price_agreements SET valid_until = '<created_at da condição mais nova>'
 WHERE organization_id = '<organization_id>' AND id = '<id da condição mais antiga>';
-- Ou: a condição que não deve valer fica com a vigência vazia.
UPDATE customer_price_agreements SET valid_until = created_at
 WHERE organization_id = '<organization_id>' AND id = '<id da condição descartada>';
COMMIT;
```

Lembre que, na 1.0.0, entre duas condições sobrepostas valia a de maior desconto: manter a de menor desconto
muda os preços das próximas reservas do cliente. Reservas, orçamentos e contratos já registrados não mudam.
Repita a consulta 1 até não haver linhas. Depois da migration, as condições não são mais editadas: o
ajuste passa a ser feito pelo encerramento (imediato ou agendado) na página do cliente.

### 13.3 Aplicação

- Faça o backup (seção 3) e aplique a migration no passo 2 da seção 12, **antes** de substituir web e
  worker. A 1.0.0 continua funcionando sobre o esquema da 0015 durante a troca.
- A 0015 executa `ALTER TABLE` em `coupons` e `customer_price_agreements` (colunas, constraints, gatilhos
  e privilégios) e cria gatilhos em `reservations` e `reservation_items`. As operações são rápidas, mas pedem
  trava exclusiva nas tabelas: transações longas em andamento sobre elas atrasam a migration, e a migration
  atrasa as requisições que chegam enquanto ela espera. Prefira um horário de pouco movimento.
- Depois da troca, confira `/health/ready` e, por alguns dias, a métrica
  `locentra_db_transaction_retries_total` em `/metrics`: a criação de reservas com cupom trava o cupom antes
  dos estoques, e um aumento sustentado de repetições por impasse (`reason="TRDeadlockDetected"`) deve ser
  investigado.
- Credenciais de integração existentes não recebem os escopos novos (`coupons.*`, `price_agreements.*`,
  `fees.*`); crie credenciais novas para as integrações que vão usar esses recursos.

### 13.4 Retorno à versão 1.0.0

O esquema da 0015 é tolerado pela 1.0.0 (nenhuma coluna foi renomeada ou removida, e a 1.0.0 mantém o
privilégio de atualizar `coupons.redemptions`). O que muda é a **regra**, porque a 1.0.0 não conhece as
colunas novas:

- **Cupons:** a 1.0.0 conta somente `coupons.redemptions`, que ficou congelado, e ignora os usos gravados em
  `coupon_redemptions`. Um cupom com limite que foi usado depois da migration volta a aceitar usos como se
  estivesse no ponto em que a 1.0.0 parou, e os usos feitos depois do retorno não entram no livro.
- **Condições negociadas:** a 1.0.0 ignora `valid_from`, `ended_at` e a regra de não sobreposição. Uma
  condição encerrada volta a valer (até `valid_until`) e uma condição agendada vale desde já.
- **Tarifas:** a 1.0.0 não aplica o catálogo; reservas já criadas mantêm as tarifas no snapshot.

Antes de voltar, verifique com `locentra_backup`:

```sql
SELECT (SELECT count(*) FROM coupon_redemptions) AS usos_no_livro,
       (SELECT count(*) FROM coupons WHERE active AND max_redemptions IS NOT NULL
                                       AND EXISTS (SELECT 1 FROM coupon_redemptions r
                                                    WHERE r.organization_id = coupons.organization_id AND r.coupon_id = coupons.id))
         AS cupons_com_limite_usados,
       (SELECT count(*) FROM customer_price_agreements
         WHERE ended_at IS NOT NULL OR valid_from > now()) AS condicoes_encerradas_ou_agendadas;
```

Com `cupons_com_limite_usados` maior que zero, desative esses cupons (tela **Cupons**, API ou
`bin/locentra coupons deactivate`) antes de voltar, ou não volte. Com `condicoes_encerradas_ou_agendadas`
maior que zero, não volte: as condições não podem mais ser ajustadas para a regra antiga. Nesses casos,
corrija o problema na versão nova. A restauração do backup anterior à migration (seção 4) descarta tudo o que
foi registrado depois dele.

### 13.5 Registro do exercício (21/11/2026, PostgreSQL 18.7, branch release/1.1.0)

Ambiente Compose da 1.0.0 com seed e dados legados criados pelo papel da aplicação: duas condições
negociadas sobrepostas para o mesmo cliente (5% com fim em 60 dias e 8% sem prazo), um cupom com limite já
usado duas vezes (`LEGADO10`, 2 de 5) e um cupom com fim de vigência anterior ao início (`INVERTIDO`). Web e
worker da 1.0.0 ficaram em execução durante a migration.

| Passo | Resultado |
|---|---|
| 13.1, consulta 1 (`locentra_backup`) | 1 par sobreposto listado, com organização, cliente, ids e descontos |
| 13.1, consulta 2 | o cupom `INVERTIDO` listado |
| `db:migrate` com a imagem 1.1.0 antes do ajuste | abortou com `migração 0015: 1 par(es) de condições negociadas com vigências sobrepostas (organização …, cliente …)`; o esquema continuou na 0014 |
| 13.2, ajuste com `locentra_app` e contexto da organização | a condição mais antiga passou a terminar no início da mais nova; a consulta 1 voltou vazia |
| Backup da seção 3 antes da migration | gravado |
| `db:migrate` (seção 12, passo 2) | 0015 aplicada em cerca de 3 s, com a 1.0.0 em execução |
| 1.0.0 sobre o esquema da 0015 | `/health/ready` 200 (`database` e `migrations` ok) e tela de entrada 200 |
| Troca de web e worker para a 1.1.0 (seção 12, passo 3) | os dois `healthy` em 16 s; `/health/ready` 200 |
| Dados legados depois da migration | `LEGADO10` exibido com "2 de 5" usos (contador antigo preservado); as duas condições com início preenchido e sem sobreposição |
| `db:seed` da 1.1.0 | tarifas, cupons e condições de demonstração acrescentados sem alterar os dados existentes |
| Cupom legado com vigência inválida | exibido como "Expirado" e desativado pela tela **Cupons**, com `coupon.deactivated` na auditoria |
| 13.4, consulta de retorno | `usos_no_livro` 0, `cupons_com_limite_usados` 0, `condicoes_encerradas_ou_agendadas` 0 |
| Retorno à imagem 1.0.0 e volta à 1.1.0 | os dois sentidos `healthy`, `/health/ready` 200; parada final de web e worker com código 0 |

No exercício, o Compose da 1.1.0 foi executado a partir de outro diretório, o que recriou o contêiner do
PostgreSQL (o caminho montado de `docker/postgres/init` mudou) sem perda de dados, porque o volume `pgdata`
é o mesmo. Numa atualização feita a partir do mesmo checkout isso não ocorre.

## 14. Atualização para a migration 0016 (configurações da organização) — procedimento escrito

A migration `0016_configuracoes_organizacao.sql` é aplicada numa única transação. A atualização a partir do
esquema da 0015, com dados no formato da 1.1.0 (política personalizada em `settings`, `settings` vazio, valores
JSON `null`, filial inativa, reservas com e sem contrato e versão de orçamento enviada), é coberta por
`test/repository/migration_0016_test.rb`, inclusive o aborto com diagnóstico. O procedimento abaixo ainda não
foi exercitado num ambiente Compose.

### 14.1 Verificação prévia (antes do passo 2 da seção 12)

A 0016 confere o formato de `organizations.settings` antes de alterar qualquer coisa. Se encontrar uma
organização com `settings` que não seja objeto JSON, com `cancellation_policy` sem `tiers` (lista de 1 a 6
faixas), com faixa sem `min_hours_before` ou `fee_bps` numéricos ou com `hold_minutes` fora de 5 a 1440,
**aborta** com
`migração 0016: configurações (settings) fora do formato esperado nas organizações …` e nada é alterado. A
1.1.0 não grava `settings`, então isso só ocorre com alteração manual. Confira antes com `locentra_backup`
(a consulta aplica as mesmas regras da migration e é conferida por
`test/repository/organization_settings_repository_test.rb`):

```sql
-- psql "postgres://locentra_backup:<senha>@<host>:5432/locentra"
SELECT id, settings
  FROM organizations
 WHERE jsonb_typeof(settings) <> 'object'
    OR (NULLIF(settings -> 'cancellation_policy', 'null'::jsonb) IS NOT NULL
        AND NOT CASE WHEN jsonb_typeof(settings -> 'cancellation_policy' -> 'tiers') = 'array'
                     THEN jsonb_array_length(settings -> 'cancellation_policy' -> 'tiers') BETWEEN 1 AND 6
                          AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(settings -> 'cancellation_policy' -> 'tiers') t
                                           WHERE jsonb_typeof(t -> 'min_hours_before') IS DISTINCT FROM 'number'
                                              OR jsonb_typeof(t -> 'fee_bps') IS DISTINCT FROM 'number')
                     ELSE false END)
    OR (NULLIF(settings -> 'hold_minutes', 'null'::jsonb) IS NOT NULL
        AND NOT ((settings ->> 'hold_minutes') ~ '^\d{1,4}$' AND (settings ->> 'hold_minutes')::int BETWEEN 5 AND 1440));
```

Para cada linha, corrija `settings` com o proprietário (por exemplo, removendo a chave inválida com
`settings - 'hold_minutes'`) ou restaure o valor anterior conhecido. Valores JSON `null` não impedem a
migration: são tratados como ausentes e removidos.

### 14.2 Aplicação

- Faça o backup (seção 3) e aplique a migration no passo 2 da seção 12, **antes** de substituir web e worker.
  A 1.1.0 continua funcionando sobre o esquema da 0016: os gatilhos de preenchimento gravam a política da
  organização (ou a padrão) nas reservas e versões que ela inserir sem a coluna.
- A migration mantém travas exclusivas em `organizations`, `branches`, `reservations`, `quote_versions` e
  `contracts` até o commit. A duração é dominada pelas verificações das CHECKs novas (varredura de
  `reservations` e `quote_versions`, sem reescrita das tabelas) e pelos preenchimentos direcionados
  (normalmente nenhuma linha). **Toda requisição da 1.1.0 espera durante a migration**, porque o
  autenticador lê `organizations`. Em bases grandes, use uma janela de manutenção; nas demais, um horário de
  pouco movimento. Limite a espera pelas travas para não acumular requisições atrás de uma transação longa:

  ```bash
  docker run --rm -e APP_ENV=production -e MIGRATION_DATABASE_URL=... -e PGOPTIONS='-c lock_timeout=5s' \
    ghcr.io/<repositório>:X.Y.Z ruby bin/locentra-admin db:migrate
  ```

  Se a migration falhar por `lock_timeout`, nada é aplicado; repita quando as transações longas terminarem.
- **Não altere configurações nem filiais até todas as instâncias estarem na versão nova.** Durante a troca,
  uma instância 1.1.0 não respeita filiais desativadas e emite contratos com a política atual de `settings`.
- Credenciais existentes não recebem `organization.read`; crie credenciais novas para as integrações e rotinas
  de CLI que vão consultar a organização.
- Depois da troca, confira `/health/ready` e a métrica `domain_conflicts_total` (códigos `stale_organization`,
  `stale_branch`, `last_active_branch` e `branch_in_use`).

### 14.3 Retorno à versão 1.1.0

O esquema da 0016 é tolerado pela 1.1.0 (colunas novas com default ou preenchidas pelos gatilhos; nenhuma
coluna renomeada ou removida). O que muda é a regra:

- a 1.1.0 ignora `reservations.cancellation_policy` e `quote_versions.cancellation_policy` e emite contratos
  com a política atual de `settings`, não com a registrada na reserva;
- a 1.1.0 não conhece a gestão de filiais: lista também as inativas nos formulários, recusa as criações nelas
  com "filial não encontrado" (inclusive baixa e perda de estoque, que a versão nova aceita), não confere a
  filial no envio de orçamento sem bloqueio e não oferece edição, desativação nem reativação;
- reservas antigas voltam a usar o fuso atual em extensões, multas e cobranças.

Antes de voltar, restaure as configurações anteriores (política e validade) na tela da versão nova, para que
os contratos emitidos durante o retorno usem a mesma política das reservas, ou aceite que contratos emitidos
durante o retorno não respeitem o snapshot. Confira com `locentra_backup` quantas reservas têm política
diferente da atual da organização:

```sql
SELECT r.organization_id, count(*) AS reservas_com_politica_diferente
  FROM reservations r JOIN organizations o ON o.id = r.organization_id
 WHERE r.status IN ('requested', 'held', 'confirmed')
   AND NOT EXISTS (SELECT 1 FROM contracts c WHERE c.organization_id = r.organization_id AND c.reservation_id = r.id)
   AND r.cancellation_policy IS DISTINCT FROM COALESCE(o.settings -> 'cancellation_policy', app_default_cancellation_policy())
 GROUP BY 1;
```

### 14.4 Remoção futura dos gatilhos de preenchimento

Os gatilhos `reservations_cancellation_policy_fill` e `quote_versions_cancellation_policy_fill` existem para as
inserções de instâncias 1.1.0 durante a implantação gradual e o retorno. A aplicação 1.2 sempre informa a
coluna (keyword obrigatória no repositório, coberta por teste). Quando não houver mais retorno possível à
1.1.0, uma migration futura remove os dois gatilhos e a função `app_cancellation_policy_fill()`; os gatilhos de
imutabilidade e as CHECKs permanecem.
