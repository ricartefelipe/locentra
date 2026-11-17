-- Reservas, itens e alocações.
--
-- Garantias de disponibilidade:
-- * Ativos individuais: exclusion constraint impede duas alocações ativas do mesmo ativo com
--   períodos sobrepostos ([início, fim) — períodos adjacentes não conflitam).
-- * Estoque quantitativo: a aplicação bloqueia a linha de stock_pools (SELECT ... FOR UPDATE)
--   antes de calcular o pico de ocupação e inserir; o lock serializa alocações concorrentes.

CREATE TABLE reservations (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  branch_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  code text NOT NULL,
  status text NOT NULL
    CHECK (status IN ('requested', 'held', 'confirmed', 'in_progress', 'completed', 'cancelled', 'expired')),
  source text NOT NULL DEFAULT 'staff' CHECK (source IN ('staff', 'portal', 'quote', 'api')),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  hold_expires_at timestamptz,
  quote_id uuid,
  notes text,
  pricing jsonb NOT NULL DEFAULT '{}',
  total_cents bigint NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
  deposit_cents bigint NOT NULL DEFAULT 0 CHECK (deposit_cents >= 0),
  overdue_since timestamptz,
  created_by uuid,
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  expired_at timestamptz,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  CHECK (ends_at > starts_at),
  CHECK (status <> 'held' OR hold_expires_at IS NOT NULL)
);
CREATE INDEX reservations_org_status_idx ON reservations (organization_id, status, starts_at);
CREATE INDEX reservations_customer_idx ON reservations (organization_id, customer_id, starts_at DESC);
CREATE INDEX reservations_hold_expiry_idx ON reservations (organization_id, hold_expires_at) WHERE status = 'held';
CREATE INDEX reservations_ends_idx ON reservations (organization_id, ends_at) WHERE status = 'in_progress';

CREATE TABLE reservation_items (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  product_id uuid NOT NULL,
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 100000),
  position integer NOT NULL,
  pricing jsonb NOT NULL DEFAULT '{}',
  total_cents bigint NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (reservation_id, position),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id) ON DELETE CASCADE,
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id)
);
CREATE INDEX reservation_items_reservation_idx ON reservation_items (organization_id, reservation_id);

CREATE TABLE asset_allocations (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  product_id uuid NOT NULL,
  reservation_id uuid,
  reservation_item_id uuid,
  kind text NOT NULL CHECK (kind IN ('reservation', 'block')),
  reason text,
  period tstzrange NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL,
  released_at timestamptz,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_item_id) REFERENCES reservation_items (organization_id, id),
  CHECK (NOT isempty(period) AND lower_inc(period) AND NOT upper_inc(period) AND NOT lower_inf(period)),
  CHECK ((kind = 'reservation') = (reservation_id IS NOT NULL AND reservation_item_id IS NOT NULL)),
  CHECK (active OR released_at IS NOT NULL),
  CONSTRAINT asset_allocations_no_overlap EXCLUDE USING gist (asset_id WITH =, period WITH &&) WHERE (active)
);
CREATE INDEX asset_allocations_reservation_idx ON asset_allocations (organization_id, reservation_id) WHERE reservation_id IS NOT NULL;
CREATE INDEX asset_allocations_period_idx ON asset_allocations USING gist (organization_id, product_id, period) WHERE active;

CREATE TABLE stock_allocations (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  stock_pool_id uuid NOT NULL,
  product_id uuid NOT NULL,
  reservation_id uuid,
  reservation_item_id uuid,
  kind text NOT NULL CHECK (kind IN ('reservation', 'block')),
  reason text,
  quantity integer NOT NULL CHECK (quantity > 0),
  period tstzrange NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL,
  released_at timestamptz,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_item_id) REFERENCES reservation_items (organization_id, id),
  CHECK (NOT isempty(period) AND lower_inc(period) AND NOT upper_inc(period) AND NOT lower_inf(period)),
  CHECK ((kind = 'reservation') = (reservation_id IS NOT NULL AND reservation_item_id IS NOT NULL)),
  CHECK (active OR released_at IS NOT NULL)
);
CREATE INDEX stock_allocations_reservation_idx ON stock_allocations (organization_id, reservation_id) WHERE reservation_id IS NOT NULL;
CREATE INDEX stock_allocations_pool_period_idx ON stock_allocations USING gist (stock_pool_id, period) WHERE active;

SELECT app_enable_tenant_rls('reservations');
SELECT app_enable_tenant_rls('reservation_items');
SELECT app_enable_tenant_rls('asset_allocations');
SELECT app_enable_tenant_rls('stock_allocations');
