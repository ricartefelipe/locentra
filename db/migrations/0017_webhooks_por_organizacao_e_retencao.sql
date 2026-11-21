-- Webhooks por organização e retenção do histórico de integrações: circuito por endpoint (falhas
-- consecutivas e pausa automática), entregas retidas enquanto o endpoint está pausado, índice para a
-- reivindicação justa entre organizações na fila de webhooks, índices da retenção em lotes e totais
-- globais por desfecho gravados pelo worker.
--
-- Garantias:
-- * Circuito consistente: `failing_since` existe se e somente se há falhas consecutivas
--   (webhook_endpoints_failure_streak_check). O contador nunca é negativo.
-- * Entrega retida nunca está entregue (webhook_deliveries_held_check): a retenção vale só para o que
--   ainda precisa sair.
-- * Reivindicação por organização: `jobs_ready_org_idx` dá a cabeça de cada organização com tarefas
--   pendentes em O(log n), sem percorrer o backlog de uma organização para chegar à seguinte.
-- * Retenção: os índices parciais cobrem exatamente as condições de remoção (entregas concluídas e não
--   retidas, eventos despachados, webhooks recebidos já processados ou ignorados), e
--   `webhook_deliveries_event_idx` atende à verificação "evento sem entrega restante".
-- * `worker_outcome_totals` é global e sem dados de tenant (sem organização, identificadores ou
--   mensagens): somente família, desfecho e total, com a lista fechada de pares no CHECK. A aplicação
--   web só lê; o worker grava e ninguém remove.
-- * RLS: nenhuma política nova. As tabelas alteradas continuam com a RLS habilitada e forçada; a
--   retenção roda no contexto de cada organização.
--
-- Compatibilidade com a 1.2.0 (implantação gradual e retorno): somente colunas com DEFAULT ou anuláveis,
-- índices e uma tabela nova. A 1.2.0 continua inserindo endpoints e entregas sem as colunas novas e
-- ignora pausa e limite por organização. Sem CONCURRENTLY: o Migrator aplica cada migration numa
-- transação; a construção dos índices percorre as tabelas (ver docs/RUNBOOKS.md, lock_timeout).

-- Circuito por endpoint
ALTER TABLE webhook_endpoints
  ADD COLUMN consecutive_failures integer NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
  ADD COLUMN failing_since timestamptz,
  ADD COLUMN paused_at timestamptz,
  ADD CONSTRAINT webhook_endpoints_failure_streak_check CHECK ((consecutive_failures = 0) = (failing_since IS NULL));

-- Entregas retidas por pausa do endpoint
ALTER TABLE webhook_deliveries
  ADD COLUMN held_at timestamptz,
  ADD CONSTRAINT webhook_deliveries_held_check CHECK (held_at IS NULL OR status <> 'delivered');

-- Reivindicação por organização (cabeça de cada organização em O(log n))
CREATE INDEX jobs_ready_org_idx ON jobs (queue, organization_id, priority, run_at) WHERE status = 'pending';

-- Retenção e referência evento -> entregas
CREATE INDEX outbox_events_dispatched_idx ON outbox_events (organization_id, dispatched_at) WHERE dispatched_at IS NOT NULL;
CREATE INDEX webhook_deliveries_event_idx ON webhook_deliveries (organization_id, event_id);
CREATE INDEX webhook_deliveries_finished_idx ON webhook_deliveries (organization_id, last_attempt_at)
  WHERE status IN ('delivered', 'failed') AND held_at IS NULL;
CREATE INDEX webhook_deliveries_held_idx ON webhook_deliveries (organization_id, endpoint_id, created_at) WHERE held_at IS NOT NULL;
CREATE INDEX inbound_webhooks_processed_idx ON inbound_webhooks (organization_id, processed_at) WHERE status IN ('processed', 'ignored');

-- Totais globais por desfecho (sem dados de tenant), gravados pelo worker e lidos pela web
CREATE TABLE worker_outcome_totals (
  family text NOT NULL,
  outcome text NOT NULL,
  total bigint NOT NULL DEFAULT 0 CHECK (total >= 0),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (family, outcome),
  CHECK ((family, outcome) IN (
    ('webhook_delivery', 'delivered'), ('webhook_delivery', 'failed'), ('webhook_delivery', 'held'), ('webhook_delivery', 'released'),
    ('webhook_circuit', 'paused'),
    ('retention', 'jobs'), ('retention', 'outbox_events'), ('retention', 'webhook_deliveries'), ('retention', 'inbound_webhooks')))
);
REVOKE INSERT, UPDATE, DELETE ON worker_outcome_totals FROM locentra_app;
REVOKE DELETE ON worker_outcome_totals FROM locentra_worker;
