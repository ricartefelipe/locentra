# Worker: justiça entre organizações na fila de webhooks, circuito por endpoint e retenção

Complementa o worker descrito em [`../ARQUITETURA.md`](../ARQUITETURA.md) (ADR-020) e os webhooks enviados
(ADR-021). As decisões estão na ADR-029 de [`../DECISOES.md`](../DECISOES.md); a operação, em
[`../RUNBOOKS.md`](../RUNBOOKS.md) §9, §10, §15 e §16.

| Camada | Arquivos |
|---|---|
| Migration | `db/migrations/0017_webhooks_por_organizacao_e_retencao.sql` |
| Domínio | `lib/locentra/domain/webhooks.rb` (`Circuit`) |
| Aplicação | `lib/locentra/application/webhooks.rb` (`DispatchEvent`, `Deliver`, `Redeliver`, `ResumeEndpoint`, `ReleaseHeld`), `application/retention.rb` (`PurgeHistory`, `Windows`, `STEPS`), `application/reports.rb` (`CollectMetrics`) |
| Infraestrutura | `lib/locentra/infrastructure/jobs/queue.rb` (limite por organização), `persistence/webhooks.rb`, `persistence/retention.rb` (`RetentionRepository`, `OutcomeTotalsRepository`), `persistence/reports.rb`, `observability/logger.rb` (`Metrics::HELP`) |
| Worker | `interfaces/worker/handlers.rb` (`webhooks.release_held`, `organization.retention`, `schedule_retention`, total do housekeeping), `interfaces/worker/runner.rb` (log `worker.started`), `bin/worker` |
| Interface web | `interfaces/http/routes.rb` (`POST /integracoes/:id/reativar`), `interfaces/http/web/integrations_controller.rb` (`resume`), `interfaces/http/labels.rb`, `views/integrations/index.html.erb` |
| Configuração | `lib/locentra/config.rb` (`WEBHOOK_MAX_PER_ORGANIZATION`, janelas de retenção, `validate_worker!`), `lib/locentra/system.rb` |

Não há API v1 nem comando de CLI para webhooks enviados: a reativação é feita somente pela interface web.

## Faixas e threads

O worker tem duas faixas de threads: `WORKER_CONCURRENCY` (padrão 4) para a fila `default` e
`WEBHOOK_CONCURRENCY` (padrão **4**, antes 1) para a fila `webhooks`. O pool de conexões do worker continua
`WORKER_CONCURRENCY + WEBHOOK_CONCURRENCY + 2` (heartbeat e agendador): 10 conexões com os padrões. A
retenção (`organization.retention`), a liberação de entregas retidas (`webhooks.release_held`) e o
`platform.housekeeping` rodam nas threads da fila `default`. O log `worker.started` informa as faixas e o
limite por organização em vigor (`webhook_max_per_organization`).

## Limite de execuções simultâneas por organização

`WEBHOOK_MAX_PER_ORGANIZATION` (padrão 2, de 1 a 100) é o número máximo de tarefas da fila `webhooks` de
uma mesma organização em execução com lease válido (`status = 'running' AND lease_expires_at > agora`),
somadas entre todos os workers. Um lease vencido não conta: a tarefa já pode ser reivindicada de novo. A fila
`default` e as tarefas sem organização não têm limite.

### Reivindicação

`Queue#claim` separa as filas pedidas em limitadas e livres. As livres usam o `SELECT ... FOR UPDATE SKIP
LOCKED` de sempre. Para cada fila limitada:

1. **Candidatos** (`candidates`): uma CTE recursiva percorre as organizações com tarefas pendentes pelo
   índice `jobs_ready_org_idx (queue, organization_id, priority, run_at) WHERE status = 'pending'` (cada passo
   é uma busca no índice pela próxima organização), e um `LATERAL` pega até N cabeças de cada uma. Entram
   também as tarefas sem organização e as de lease vencido. Os candidatos de organizações já no limite saem,
   e o restante é ordenado por **execuções em curso da organização**, prioridade e horário, até 32
   candidatos (`CANDIDATE_WINDOW`).
2. **Lock consultivo** (`organization_slot?`): `pg_try_advisory_xact_lock(74201, hashtext('<fila>:<organização>'))`.
   Se outra reivindicação em andamento detém o lock, a organização é pulada. O lock nunca espera e não
   causa impasse.
3. **Recontagem:** um comando novo conta as execuções válidas da organização. Em READ COMMITTED, ele vê os
   commits das reivindicações anteriores. A organização só segue se `em curso + já escolhidas nesta
   reivindicação < limite`.
4. **Bloqueio da linha com revalidação:** `SELECT ... WHERE id = $1 AND (pendente pronta OR lease vencido
   com tentativas restantes) FOR UPDATE SKIP LOCKED`.

Os escolhidos das filas livres e das limitadas são reunidos e ordenados por `(priority, run_at)`. O lease
(`UPDATE ... RETURNING` com token, encerramento da tentativa abandonada e linha nova em `job_attempts`) é o
mesmo de antes, extraído para `lease`. O lock consultivo é liberado no commit da reivindicação: nenhum lock
fica aberto durante a execução da tarefa.

### Exatidão, custo e colisões

- Sem o lock, duas reivindicações simultâneas veriam "0 em execução" e passariam do limite. O lock por
  transação serializa somente as reivindicações da **mesma organização na mesma fila**, e a recontagem, feita
  depois do lock, vê o que já foi confirmado.
- O custo cresce com o número de organizações que têm pendências, não com o backlog de cada uma: uma
  organização com 50 mil entregas pendentes não encarece a reivindicação das outras.
- Ordenar primeiro pelas execuções em curso intercala as organizações quando há várias threads livres: quem
  não tem nada em execução passa à frente do backlog de quem já tem.
- O espaço de dois inteiros do lock consultivo (classe 74201) não colide com o lock bigint do `Migrator`. Uma
  colisão de `hashtext` entre duas organizações só adia a reivindicação de uma delas.
- Não há contador de métrica no caminho da reivindicação (seria um ponto de contenção). A justiça é
  observável por `locentra_jobs_oldest_age_seconds{queue="webhooks"}`.

## Circuito por endpoint

### Regras

- Cada tentativa com falha (HTTP fora de 2xx, erro de rede, tempo esgotado, destino bloqueado) soma 1 em
  `webhook_endpoints.consecutive_failures`, e a primeira da sequência grava `failing_since`. Um sucesso zera os
  dois. Sucesso com a sequência já zerada não grava nada: o caminho comum não disputa a linha do endpoint.
- O endpoint é pausado (`paused_at`) quando há **pelo menos 20 falhas consecutivas e pelo menos 1 hora desde a
  primeira** (`Domain::Webhooks::Circuit`, constantes `FAILURE_THRESHOLD` e `MIN_FAILING_SECONDS`, sem variável
  de ambiente). As duas condições evitam pausar por uma queda curta de um destino com muito tráfego e ainda
  pausam destinos pouco usados que falham há horas (uma entrega faz até 10 tentativas em cerca de 3 h).
- A contagem e a pausa são gravadas na mesma transação da tentativa (`record_attempt`). Se a tentativa não
  foi gravada (entrega já concluída por outra execução), nada muda no circuito nem nos totais.
- A pausa acontece uma única vez (`UPDATE ... WHERE paused_at IS NULL`) e é auditada como ação do sistema
  (`webhook.endpoint_paused`, `actor_type = 'system'`, `request_id` igual ao correlation_id da tarefa), com
  `consecutive_failures`, `failing_since`, `last_status_code` e `last_error` redigido (`Jobs::ErrorText`) e
  limitado a 200 caracteres. A URL não entra na auditoria.

### Entregas retidas

- Endpoint pausado **retém** as entregas (`webhook_deliveries.held_at`): a tarefa `webhooks.deliver` não faz
  chamada de rede nem gasta tentativa e conclui com `:endpoint_paused`.
- `DispatchEvent` com o endpoint pausado já cria a entrega retida, sem tarefa. Nada se perde e não há
  tarefas paradas sendo consultadas periodicamente.
- O reenvio manual (`Redeliver`) limpa `held_at` e enfileira a entrega; com o endpoint ainda pausado, a tarefa
  retém a entrega de novo.
- A tela de integrações mostra o endpoint "Pausado", com o número de falhas, o início da sequência e as
  entregas retidas, e as entregas como "Retida (endpoint pausado)", sem o botão de reenvio.

### Reativação e liberação em lotes

- Somente pela interface web: `POST /integracoes/:id/reativar`, com `integrations.manage` (proprietário e
  administrador) e CSRF. Endpoint desativado (`endpoint_disabled`) ou não pausado (`endpoint_not_paused`)
  volta com o alerta; o auditor recebe 403.
- `ResumeEndpoint` trava o endpoint (`FOR UPDATE`), conta as retidas, zera o circuito, grava a auditoria
  `webhook.endpoint_resumed` (`paused_at`, `consecutive_failures`, `held_deliveries`) e, se houver retidas,
  enfileira **uma** tarefa `webhooks.release_held` (fila `default`, prioridade 45).
- `ReleaseHeld` libera lotes de 500 (`RELEASE_BATCH`): devolve as entregas a `pending`, enfileira uma tarefa
  `webhooks.deliver` por entrega (sujeita ao limite por organização) e se reagenda enquanto o lote vier cheio.
  Endpoint pausado de novo ou desativado interrompe a liberação.

### Corridas e locks

| Disputa | Lock | Resultado |
|---|---|---|
| Despacho × reativação | `endpoints_for` com `FOR KEY SHARE`; reativação com `FOR UPDATE` | A reativação espera o commit do despacho e conta as entregas retidas por ele |
| Retenção na entrega × reativação | `hold_delivery` com `FOR KEY SHARE` no endpoint | Reativação primeiro: a retenção não acontece (0 linhas) e a entrega segue. Retenção primeiro: a reativação espera, vê a entrega retida e a liberação a entrega |
| Liberação × nova pausa | `lock_endpoint_for_release` com `FOR KEY SHARE` | Com o endpoint pausado de novo, a liberação para |
| Pausa × despacho | Pausa é `UPDATE` comum (`FOR NO KEY UPDATE`) | Não conflita com `FOR KEY SHARE`: a pausa não espera o despacho |

`FOR KEY SHARE` exige privilégio de `UPDATE`, que a aplicação e o worker têm em `webhook_endpoints`.

## Retenção do histórico de integrações

### O que sai e o que fica

| Tabela | Sai | Fica sempre |
|---|---|---|
| `webhook_deliveries` | `delivered`/`failed` não retidas com `last_attempt_at` antes do corte; todas as entregas de endpoint **desativado** antes do corte e criadas antes do corte (a desativação é definitiva) | retidas, `pending`, recentes |
| `outbox_events` | despachados antes do corte e **sem nenhuma entrega restante** | não despachados, com entrega restante, recentes |
| `inbound_webhooks` | `processed`/`ignored` com `processed_at` antes do corte | `received` (aguardando processamento), `failed`, recentes |

O reenvio manual, a leitura do evento pela entrega (`delivery_bundle`, que faz JOIN com `outbox_events`,
sem FK) e a deduplicação dos recebidos continuam funcionando. Uma entrega removida responde 404 ao reenvio, e
uma tarefa de entrega removida conclui com `:missing`.

### Janelas e mínimos

| Variável | Padrão | Mínimo | Justificativa do mínimo |
|---|---|---|---|
| `WEBHOOK_DELIVERY_RETENTION_DAYS` | 30 | 7 | Supera com folga a janela de retentativas (backoff limitado a 6 h, cerca de 3 h no total) |
| `OUTBOX_RETENTION_DAYS` | 30 | 7 | Idem; um evento só sai depois das suas entregas |
| `INBOUND_WEBHOOK_RETENTION_DAYS` | 90 | 45 | 30 dias da conciliação (`Finance::Reconcile::WINDOW_DAYS`) + 14 dias de reenvio do provedor (hipótese adotada) + 1 de margem |

O máximo de todas é 3650 dias; valores fora do intervalo são recusados na leitura da configuração. Dentro da
janela dos recebidos, um reenvio do provedor continua sendo reconhecido como `duplicate`
(`UNIQUE (organization_id, provider, event_id)`). Fora dela, seria aceito e reprocessado de forma idempotente:
uma confirmação repetida da mesma cobrança vira `ignored`, e os alertas são deduplicados por `dedupe_key`. O
padrão de 90 dias dá margem dupla.

### Execução

- `organization_tick` (por organização ativa, a cada minuto) agenda `organization.retention` uma vez por hora
  (`unique_key "org-retention:<organização>:<AAAA-MM-DDTHH>"`, prioridade 95, fila `default`).
- `PurgeHistory` calcula o corte de cada tipo uma vez por execução e segue a ordem entregas → outbox →
  recebidos. Cada lote tem até 1.000 linhas, numa transação curta própria, e cada passo para no primeiro lote
  incompleto ou em 10 lotes. A capacidade é de até 240 mil linhas por tabela, por organização, por dia.
- **Contexto do tenant:** `webhook_deliveries` e `inbound_webhooks` só são visíveis com o contexto de uma
  organização. Uma limpeza global veria zero entregas, e o `NOT EXISTS` contra `webhook_deliveries` seria
  sempre verdadeiro: apagaria eventos com entrega pendente. Por isso a retenção roda por organização, e
  nenhuma política nova de leitura entre tenants foi criada. O repositório exige o tenant (`tenant_id!`).
- **Reavaliação no DELETE:** todo `DELETE` repete as condições de elegibilidade na tabela-alvo
  (`DELETE ... WHERE id IN (subconsulta LIMIT) AND <condições>`). Em READ COMMITTED, depois de esperar o lock
  de uma linha, o PostgreSQL reavalia só as condições da tabela-alvo. Assim, um reenvio concorrente que volta
  a entrega para `pending` impede a remoção.
- `platform.housekeeping` (sem tenant) continua removendo as tarefas concluídas depois de 14 dias e passa a
  somar o total removido em `retention/jobs`.
- Somente organizações ativas são limpas (o `platform.fanout` agenda a rotina só para elas).

## Métricas

Totais globais na tabela `worker_outcome_totals (family, outcome, total)`, sem organização nem
identificadores, com a lista fechada de pares no CHECK. O worker grava na mesma transação do fato, e o
processo web publica no `/metrics` (`CollectMetrics`):

| Métrica | Rótulo | Valores |
|---|---|---|
| `locentra_webhook_deliveries_total` | `outcome` | `delivered`, `failed`, `held`, `released` |
| `locentra_webhook_endpoint_pauses_total` | — | pausas automáticas |
| `locentra_retention_purged_total` | `kind` | `jobs`, `outbox_events`, `webhook_deliveries`, `inbound_webhooks` |

A aplicação web só lê a tabela; o worker grava e ninguém remove.

## Decisões

| # | Decisão |
|---|---|
| D1 | Limite por organização na fila `webhooks` (`WEBHOOK_MAX_PER_ORGANIZATION`, padrão 2, 1..100), aplicado no SQL da reivindicação; lease vencido não conta |
| D2 | Exatidão com `pg_try_advisory_xact_lock` por fila e organização antes da recontagem, mais bloqueio da linha com revalidação; nunca espera |
| D3 | Candidatos por varredura recursiva das organizações (`jobs_ready_org_idx`), ordenados por execuções em curso, prioridade e horário |
| D4 | `WEBHOOK_CONCURRENCY` passa de 1 para 4: com uma thread o limite não teria efeito |
| D5 | Pausa com ≥ 20 falhas consecutivas e ≥ 1 h desde a primeira, em constantes do domínio |
| D6 | Endpoint pausado retém entregas (`held_at`), sem rede e sem tentativa; o despacho já cria a entrega retida |
| D7 | Reativação só pela tela, com `integrations.manage` e auditoria; liberação em lotes de 500 por tarefa própria |
| D8 | `FOR KEY SHARE` no despacho e na retenção, `FOR UPDATE` na reativação: nenhuma entrega fica retida depois da reativação |
| D9 | Retenção por organização, no contexto do tenant, em tarefa horária própria (lotes de 1.000, até 10 por execução) |
| D10 | Janelas configuráveis com mínimos (7, 7 e 45 dias) verificados na configuração; máximo de 3650 |
| D11 | Removem-se só entregas concluídas antigas, entregas de endpoints desativados antigos, eventos sem entrega e recebidos processados ou ignorados |
| D12 | Todo `DELETE` repete as condições na tabela-alvo (reavaliação após o lock) |
| D13 | Totais por desfecho em `worker_outcome_totals`, gravados pelo worker e expostos pela web; nada no caminho da reivindicação |
| D14 | Migration compatível com a 1.2.0: colunas anuláveis ou com DEFAULT, índices e uma tabela nova |

## Compatibilidade com a 1.2.0

Durante a implantação gradual, a 1.2.0 continua inserindo endpoints e entregas (sem as colunas novas) e
ignora a pausa e o limite. No retorno à 1.2.0, as entregas retidas continuam retidas, sem tarefa, até o
endpoint ser reativado na versão nova. O procedimento está em [`../RUNBOOKS.md`](../RUNBOOKS.md) §16.

## Como testar

| Arquivo | O que prova |
|---|---|
| `test/unit/domain/webhooks_test.rb` | Limites exatos da pausa (19 falhas, 59 min 59 s, 3600 s, sem início) |
| `test/unit/application/webhooks_circuit_test.rb` | Retenção sem rede, tentativa quando a reativação chegou antes, pausa única auditada sem URL, nada muda sem tentativa gravada, liberação reagendada e interrompida |
| `test/unit/application/retention_test.rb` | Ordem dos passos, lote incompleto, teto de lotes, corte por tipo, totais e transação por lote |
| `test/unit/config_test.rb` | Padrões e mínimos das variáveis novas |
| `test/unit/application/observability_test.rb`, `test/unit/infrastructure/metrics_test.rb` | Métricas novas, rótulos e HELP |
| `test/repository/migration_0017_test.rb` | Atualização da 1.2.0: colunas, índices, CHECKs, RLS e inserções no formato antigo |
| `test/repository/observability_tables_test.rb` | `worker_outcome_totals` sem dados de tenant, só gravável pelo worker |
| `test/integration/webhook_fairness_test.rb` | Ordem justa, limite, lease vencido com fencing, tarefas sem organização, fila `default` sem limite, prioridade entre filas, `run_at` futuro e tarefas esgotadas |
| `test/integration/webhook_circuit_test.rb` | Pausa só depois de 1 h, auditoria, totais, retenção, despacho retido, sucesso que zera, regras e lotes da reativação, reenvio retido de novo |
| `test/integration/retention_test.rb` | O que sai e o que fica, outra organização intocada, exigência do tenant, lotes, totais, reenvio e tarefa de entrega removida, deduplicação dentro da janela e idempotência fora dela, tarefa pelo worker |
| `test/integration/worker_test.rb` | Agendamento horário da retenção e total do housekeeping |
| `test/concurrency/webhook_fairness_race_test.rb` | 20 rodadas de 6 reivindicações simultâneas sem passar do limite, controle com o lock consultivo, endpoints lentos sem monopolizar as threads (`HoldingServer`), reativação contra retenção nas duas ordens e retenção contra reenvio concorrente |
| `test/http/integrations_pages_test.rb` | Tela do endpoint pausado, CSRF, reativação por administrador, alerta, auditor recusado e entrega retida sem reenvio |
| `test/http/observability_test.rb`, `test/http/interface_labels_test.rb` | `/metrics` sem identificadores e rótulos das ações de auditoria |

## Limitações

- A retenção só limpa organizações ativas; as suspensas ou encerradas ficam com o histórico.
- Os parâmetros do circuito (20 falhas e 1 h) são fixos.
- Não há API para consultar ou reativar endpoints; a reativação é somente pela interface web.
- O limite por organização vale só para a fila `webhooks`.
