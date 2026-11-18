# Runbooks operacionais

Cada procedimento indica se foi **exercitado** (executado de ponta a ponta com resultado registrado) ou se é
**procedimento escrito** (ainda não executado em ambiente real).

## 1. Subir o ambiente local — exercitado

```bash
bin/setup        # build, PostgreSQL + Mailpit, migrations, seed, web e worker
```

Verificar: `curl -fsS localhost:9292/health/live` e `localhost:9292/health/ready` (200 com banco e migrations
em dia; 503 caso contrário). Mailpit em `localhost:8025`.

## 2. Aplicar migrations — exercitado (CI "Reconstrução do banco e seed" a cada PR)

```bash
docker compose --profile ops run --rm migrate          # usa MIGRATION_DATABASE_URL (locentra_owner)
docker compose run --rm --no-deps web ruby bin/locentra-admin db:status
```

- Exclusão mútua por `pg_advisory_lock`: execuções simultâneas aguardam.
- `checksum divergente` indica migration aplicada que foi editada: **não** edite o arquivo; restaure o
  conteúdo original e crie uma migration nova.
- A aplicação e o worker nunca usam a credencial de migration.

## 3. Backup do banco e dos anexos — exercitado em 18/11/2026

Papel dedicado `locentra_backup` (somente leitura, `BYPASSRLS`, membro de `pg_read_all_data`). Como a RLS é
forçada inclusive para o proprietário, um backup feito com o proprietário ou com o papel da aplicação sairia
vazio. O cliente `pg_dump` deve ter a mesma versão principal do servidor (18) ou mais nova.

```bash
docker run --rm --network <rede> -v "$PWD":/app -w /app \
  -e BACKUP_DATABASE_URL=postgres://locentra_backup:<senha>@postgres:5432/locentra \
  -e STORAGE_ROOT=/app/storage \
  postgres:18.7-trixie bash bin/backup /app/tmp/backups
```

Gera `banco.dump` (formato custom), `banco.indice`, `anexos.tar.gz` e `MANIFESTO.sha256`. Guarde o diretório
fora do servidor, cifrado, com retenção definida pela política da operação.

## 4. Restauração — exercitada em 18/11/2026

Executada por administrador do PostgreSQL (superusuário), sempre em **banco novo**; os proprietários
originais (`locentra_owner`) e as políticas de RLS são preservados.

```bash
docker run --rm --network <rede> -v "$PWD":/app -w /app \
  -e RESTORE_ADMIN_URL=postgres://postgres:<senha>@postgres:5432/postgres \
  postgres:18.7-trixie bash bin/restore /app/tmp/backups/<carimbo> locentra_restaurado /app/tmp/anexos-restaurados
MIGRATION_DATABASE_URL=postgres://locentra_owner:<senha>@postgres:5432/locentra_restaurado bin/locentra-admin db:status
```

Depois de validar, aponte `DATABASE_URL`/`WORKER_DATABASE_URL` para o banco restaurado, mova os anexos para o
`STORAGE_ROOT` e reinicie web e worker.

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

1. Consultar: tela/CLI de falhas (`jobs failures`) ou métricas `locentra_jobs_queue_size{kind="dead"}`.
2. Ler `last_error` e o histórico em `job_attempts` (tentativa, worker, resultado, erro).
3. Corrigir a causa (credencial do provedor, destino de webhook, dado inválido).
4. Reprocessar com usuário/credencial que tenha `jobs.manage` (auditado). A tarefa volta a `pending`.

Worker parado ou travado: tarefas `running` com lease vencido voltam a ser reivindicadas por outro worker; o
worker antigo não consegue concluí-las (fencing por `lease_token`).

## 6. Provedor de pagamento indisponível ou resposta perdida — exercitado (testes com simulador)

- Pagamentos em `submission_unknown` **não** são reenviados às cegas: a conciliação consulta o provedor por
  `externalReference` e só então conclui ou reenvia.
- Executar a conciliação manualmente pela tela Financeiro ou pela CLI (`finance reconcile`) e tratar os itens
  divergentes do relatório.
- Webhooks do provedor repetidos são deduplicados por `(organização, provedor, event_id)`.

## 7. Revogar acesso ou credencial comprometida — exercitado (testes de isolamento e API)

- Membro: Usuários e permissões → Revogar acesso (encerra sessões da organização; efeito imediato).
- Credencial de API/CLI: Usuários e permissões → Revogar. Requisições seguintes recebem 401.
- Sessões de um usuário: redefinição de senha revoga todas as sessões.

## 8. Rotação de segredos — procedimento escrito

- `APP_SECRET_KEY_BASE`: rotacionar invalida apenas mensagens de retorno (flash) em trânsito.
- `APP_ENCRYPTION_KEY`: decifrar os segredos de webhook e chaves de provedor com a chave antiga e cifrar com a
  nova em uma migração de dados controlada antes de trocar a variável (sem isso, entregas de webhook e
  chamadas ao provedor falham com erro de decifragem, sem expor dados).
- Senhas dos papéis do banco: `ALTER ROLE ... PASSWORD` e atualização das URLs; reiniciar processos.

## 9. Dimensionamento de conexões — procedimento escrito

Conexões máximas = processos web × `DB_POOL_SIZE` (≥ `PUMA_THREADS`) + workers × (`WORKER_CONCURRENCY` + 2) +
execuções de CLI/migrations. Mantenha abaixo de `max_connections` com folga. Espera por conexão aparece em
`locentra_db_pool_wait_seconds` e esgotamento em `locentra_db_pool_timeouts_total` (resposta 503).
