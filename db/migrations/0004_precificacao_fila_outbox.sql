-- Precificação (cupons, condições negociadas, ajustes), outbox de eventos e fila persistente.

CREATE TABLE coupons (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{2,39}$'),
  kind text NOT NULL CHECK (kind IN ('percent', 'fixed')),
  value bigint NOT NULL CHECK (value > 0),
  valid_from timestamptz,
  valid_until timestamptz,
  max_redemptions integer CHECK (max_redemptions IS NULL OR max_redemptions > 0),
  redemptions integer NOT NULL DEFAULT 0 CHECK (redemptions >= 0),
  min_subtotal_cents bigint NOT NULL DEFAULT 0 CHECK (min_subtotal_cents >= 0),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  CHECK (kind <> 'percent' OR value <= 10000),
  CHECK (max_redemptions IS NULL OR redemptions <= max_redemptions)
);

CREATE TABLE customer_price_agreements (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  product_id uuid,
  discount_bps integer NOT NULL CHECK (discount_bps BETWEEN 1 AND 9000),
  valid_until timestamptz,
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id)
);
CREATE INDEX customer_price_agreements_idx ON customer_price_agreements (organization_id, customer_id);

-- Ajustes posteriores ao preço original (extensões, aditivos, multas). O preço original nunca é alterado.
CREATE TABLE reservation_adjustments (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  reservation_item_id uuid,
  kind text NOT NULL CHECK (kind IN ('extension', 'amendment', 'late_fee', 'damage', 'missing', 'cancellation_fee')),
  amount_cents bigint NOT NULL,
  details jsonb NOT NULL DEFAULT '{}',
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_item_id) REFERENCES reservation_items (organization_id, id)
);
CREATE INDEX reservation_adjustments_reservation_idx ON reservation_adjustments (organization_id, reservation_id);
REVOKE UPDATE, DELETE ON reservation_adjustments FROM locentra_app, locentra_worker;

-- Outbox: eventos de negócio gravados na mesma transação da alteração.
CREATE TABLE outbox_events (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  event_type text NOT NULL,
  aggregate_type text NOT NULL,
  aggregate_id uuid NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}',
  correlation_id text,
  occurred_at timestamptz NOT NULL,
  dispatched_at timestamptz
);
CREATE INDEX outbox_events_pending_idx ON outbox_events (occurred_at) WHERE dispatched_at IS NULL;
CREATE INDEX outbox_events_aggregate_idx ON outbox_events (organization_id, aggregate_type, aggregate_id);

-- Fila persistente com lease. `lease_token` funciona como fencing token: somente o worker que
-- detém o token atual pode concluir ou reagendar a execução.
CREATE TABLE jobs (
  id uuid PRIMARY KEY,
  organization_id uuid REFERENCES organizations (id),
  queue text NOT NULL DEFAULT 'default' CHECK (queue ~ '^[a-z_]{1,30}$'),
  kind text NOT NULL CHECK (kind ~ '^[a-z_.]{1,60}$'),
  payload jsonb NOT NULL DEFAULT '{}',
  priority smallint NOT NULL DEFAULT 100,
  run_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'succeeded', 'dead', 'cancelled')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts integer NOT NULL DEFAULT 10 CHECK (max_attempts BETWEEN 1 AND 50),
  lease_token uuid,
  lease_expires_at timestamptz,
  locked_by text,
  last_error text,
  unique_key text,
  correlation_id text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  finished_at timestamptz,
  CHECK (status <> 'running' OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL))
);
CREATE UNIQUE INDEX jobs_unique_key ON jobs (unique_key) WHERE unique_key IS NOT NULL;
CREATE INDEX jobs_ready_idx ON jobs (queue, priority, run_at) WHERE status = 'pending';
CREATE INDEX jobs_lease_idx ON jobs (lease_expires_at) WHERE status = 'running';
CREATE INDEX jobs_org_status_idx ON jobs (organization_id, status, updated_at DESC);

CREATE TABLE job_attempts (
  id uuid PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES jobs (id) ON DELETE CASCADE,
  organization_id uuid REFERENCES organizations (id),
  attempt integer NOT NULL,
  worker text NOT NULL,
  started_at timestamptz NOT NULL,
  finished_at timestamptz,
  outcome text CHECK (outcome IN ('succeeded', 'retry', 'dead', 'lease_lost')),
  error text
);
CREATE INDEX job_attempts_job_idx ON job_attempts (job_id, attempt);

SELECT app_enable_tenant_rls('coupons');
SELECT app_enable_tenant_rls('customer_price_agreements');
SELECT app_enable_tenant_rls('reservation_adjustments');
SELECT app_enable_tenant_rls('outbox_events');
SELECT app_enable_tenant_rls('jobs');
SELECT app_enable_tenant_rls('job_attempts');

-- O worker consome a fila de todas as organizações e executa cada tarefa com o contexto de tenant
-- da própria tarefa. Tarefas sem organização (organization_id NULL) só são visíveis ao worker.
CREATE POLICY worker_all ON jobs TO locentra_worker USING (true) WITH CHECK (true);
CREATE POLICY worker_all ON job_attempts TO locentra_worker USING (true) WITH CHECK (true);
CREATE POLICY worker_all ON outbox_events TO locentra_worker USING (true) WITH CHECK (true);
