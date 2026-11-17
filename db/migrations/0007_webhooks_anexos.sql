-- Webhooks enviados, webhooks recebidos e anexos.

CREATE TABLE webhook_endpoints (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  url text NOT NULL CHECK (url ~ '^https?://' AND length(url) <= 2000),
  description text,
  events text[] NOT NULL CHECK (cardinality(events) > 0),
  secret_ciphertext text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL,
  disabled_at timestamptz,
  UNIQUE (organization_id, id)
);

-- Uma entrega por par (endpoint, evento): identificador estável reutilizado nas retentativas.
CREATE TABLE webhook_deliveries (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  endpoint_id uuid NOT NULL,
  event_id uuid NOT NULL,
  event_type text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'delivered', 'failed')),
  attempts integer NOT NULL DEFAULT 0,
  last_status_code integer,
  last_error text,
  created_at timestamptz NOT NULL,
  last_attempt_at timestamptz,
  delivered_at timestamptz,
  UNIQUE (organization_id, id),
  UNIQUE (endpoint_id, event_id),
  FOREIGN KEY (organization_id, endpoint_id) REFERENCES webhook_endpoints (organization_id, id)
);
CREATE INDEX webhook_deliveries_endpoint_idx ON webhook_deliveries (organization_id, endpoint_id, created_at DESC);

-- Webhooks recebidos: autenticados, persistidos e deduplicados antes do processamento.
CREATE TABLE inbound_webhooks (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  provider text NOT NULL,
  event_id text NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'processed', 'ignored', 'failed')),
  received_at timestamptz NOT NULL,
  processed_at timestamptz,
  error text,
  UNIQUE (organization_id, provider, event_id)
);

-- Anexos: chave de armazenamento gerada pelo servidor, associada ao tenant; o nome original é
-- apenas exibido. Exclusão lógica preserva a trilha até o fim da retenção.
CREATE TABLE attachments (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  owner_type text NOT NULL CHECK (owner_type IN ('contract', 'damage_report', 'customer', 'return', 'maintenance_order', 'quote')),
  owner_id uuid NOT NULL,
  filename text NOT NULL CHECK (length(filename) BETWEEN 1 AND 200),
  content_type text NOT NULL CHECK (content_type IN ('application/pdf', 'image/png', 'image/jpeg', 'image/webp')),
  byte_size bigint NOT NULL CHECK (byte_size > 0),
  sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  storage_key text NOT NULL,
  created_by uuid,
  created_at timestamptz NOT NULL,
  retain_until timestamptz,
  deleted_at timestamptz,
  UNIQUE (organization_id, id),
  UNIQUE (storage_key)
);
CREATE INDEX attachments_owner_idx ON attachments (organization_id, owner_type, owner_id) WHERE deleted_at IS NULL;

SELECT app_enable_tenant_rls('webhook_endpoints');
SELECT app_enable_tenant_rls('webhook_deliveries');
SELECT app_enable_tenant_rls('inbound_webhooks');
SELECT app_enable_tenant_rls('attachments');
