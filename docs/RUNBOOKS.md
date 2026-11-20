# Runbooks operacionais

Cada procedimento indica se foi **exercitado** (executado de ponta a ponta com resultado registrado) ou se é
**procedimento escrito** (ainda não executado em ambiente real).

## 1. Subir o ambiente local — procedimento escrito (o healthcheck do worker mudou depois do último exercício)

```bash
bin/setup        # build, PostgreSQL + Mailpit, migrations, seed, web e worker
```

Verificar: `curl -fsS localhost:9292/health/live` e `localhost:9292/health/ready` (200 com banco e migrations
em dia; 503 caso contrário); `docker compose ps` com web e worker `healthy`. Mailpit em `localhost:8025`.

O healthcheck da imagem consulta `/health/live` e vale para o processo web. O worker não serve HTTP: o
serviço `worker` do Compose usa `ruby bin/worker --check`, que confere o arquivo de vida
(`WORKER_HEALTH_FILE`, padrão `/app/tmp/worker.alive`) atualizado a cada 20 s pela thread de heartbeat
(vencido após 90 s). Em outro orquestrador, configure o mesmo comando como liveness do worker. Web e worker
têm `stop_grace_period` de 30 s, acima dos 25 s de encerramento gracioso de cada um.

## 2. Aplicar migrations — exercitado (CI "Reconstrução do banco e seed" a cada PR)

```bash
docker compose --profile ops run --rm migrate          # usa MIGRATION_DATABASE_URL (locentra_owner)
docker compose --profile ops run --rm migrate ruby bin/locentra-admin db:status
```

- Exclusão mútua por `pg_advisory_lock`: execuções simultâneas aguardam.
- `checksum divergente` indica migration aplicada que foi editada: **não** edite o arquivo; restaure o
  conteúdo original e crie uma migration nova.
- A aplicação e o worker nunca usam a credencial de migration.

## 3. Backup do banco e dos anexos — exercitado em 18/11/2026

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

## 4. Restauração — exercitada em 18/11/2026

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

### Registro do exercício (18/11/2026, PostgreSQL 18.7, banco de desenvolvimento semeado)

| Verificação | Resultado |
|---|---|
| Manifesto SHA-256 do backup | conferido antes da restauração |
| `db:status` no banco restaurado | 10 migrations aplicadas, sem checksum divergente |
| Contagem de linhas de todas as tabelas (origem × restaurado, via `locentra_backup`) | 67 tabelas, 192 linhas, idênticas |
| RLS no banco restaurado com `locentra_app` | sem contexto: 0 clientes; com contexto da organização: somente os clientes dela |
| Anexo restaurado | SHA-256 do arquivo igual ao registrado em `attachments.sha256` |
| Defeito encontrado e corrigido no exercício | o script removia o schema `public`, que o dump não recria; removido |

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

## 12. Implantação de uma versão publicada — procedimento escrito

A publicação está descrita em `CONTRIBUTING.md` (tag anotada `vX.Y.Z`, CI completa e `PUBLISH_IMAGE=true`).
A imagem publicada é `ghcr.io/<repositório>:X.Y.Z`; não existe tag `latest`, então a versão é sempre
explícita.

1. Faça o backup (seção 3).
2. Aplique as migrations com a imagem nova e a credencial do proprietário:
   `docker run --rm -e APP_ENV=production -e MIGRATION_DATABASE_URL=... ghcr.io/<repositório>:X.Y.Z ruby bin/locentra-admin db:migrate`.
3. Substitua web e worker pela imagem nova (mesmas variáveis de ambiente) e confira `/health/ready` (200).
4. Para voltar à versão anterior, use a imagem anterior; migrations são aditivas, mas confirme no
   `CHANGELOG.md` se a versão nova tem migration que a anterior não tolera antes de reverter.
