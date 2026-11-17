-- Clientes, catálogo (produtos, kits), ativos individuais e estoque quantitativo.
-- Chaves estrangeiras compostas (organization_id, id) impedem relações entre tenants.

CREATE TABLE customers (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  kind text NOT NULL CHECK (kind IN ('individual', 'company')),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 160),
  trade_name text,
  document text NOT NULL CHECK (document ~ '^[0-9]{11}$' OR document ~ '^[0-9]{14}$'),
  email text,
  phone text,
  notes text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'blocked', 'inactive')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, document),
  CHECK ((kind = 'individual' AND length(document) = 11) OR (kind = 'company' AND length(document) = 14))
);
CREATE INDEX customers_name_idx ON customers (organization_id, lower(name));

CREATE TABLE customer_contacts (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  name text NOT NULL,
  email text,
  phone text,
  role text,
  document text,
  authorized_pickup boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id) ON DELETE CASCADE
);
CREATE INDEX customer_contacts_customer_idx ON customer_contacts (organization_id, customer_id);

CREATE TABLE customer_addresses (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  label text NOT NULL DEFAULT 'principal',
  street text NOT NULL,
  number text,
  complement text,
  district text,
  city text NOT NULL,
  state text NOT NULL CHECK (state ~ '^[A-Z]{2}$'),
  postal_code text CHECK (postal_code IS NULL OR postal_code ~ '^[0-9]{8}$'),
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id) ON DELETE CASCADE
);
CREATE INDEX customer_addresses_customer_idx ON customer_addresses (organization_id, customer_id);

CREATE TABLE products (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  sku text NOT NULL CHECK (sku ~ '^[A-Z0-9][A-Z0-9-]{0,39}$'),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 160),
  description text,
  category text,
  tracking text NOT NULL CHECK (tracking IN ('serialized', 'bulk', 'kit')),
  buffer_before_minutes integer NOT NULL DEFAULT 0 CHECK (buffer_before_minutes BETWEEN 0 AND 10080),
  buffer_after_minutes integer NOT NULL DEFAULT 0 CHECK (buffer_after_minutes BETWEEN 0 AND 10080),
  deposit_cents bigint NOT NULL DEFAULT 0 CHECK (deposit_cents >= 0),
  replacement_cost_cents bigint NOT NULL DEFAULT 0 CHECK (replacement_cost_cents >= 0),
  pricing jsonb NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, sku),
  UNIQUE (organization_id, id, tracking)
);
CREATE INDEX products_name_idx ON products (organization_id, lower(name));

-- Componentes de kit: o kit precisa ter tracking 'kit' e o componente não pode ser kit.
-- A coluna de tracking participa da chave estrangeira para que a regra seja garantida pelo banco.
CREATE TABLE kit_components (
  organization_id uuid NOT NULL,
  kit_id uuid NOT NULL,
  kit_tracking text NOT NULL DEFAULT 'kit' CHECK (kit_tracking = 'kit'),
  component_id uuid NOT NULL,
  component_tracking text NOT NULL CHECK (component_tracking IN ('serialized', 'bulk')),
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 1000),
  PRIMARY KEY (organization_id, kit_id, component_id),
  CHECK (kit_id <> component_id),
  FOREIGN KEY (organization_id, kit_id, kit_tracking) REFERENCES products (organization_id, id, tracking) ON DELETE CASCADE,
  FOREIGN KEY (organization_id, component_id, component_tracking) REFERENCES products (organization_id, id, tracking)
);

CREATE TABLE assets (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_tracking text NOT NULL DEFAULT 'serialized' CHECK (product_tracking = 'serialized'),
  branch_id uuid NOT NULL,
  tag text NOT NULL CHECK (tag ~ '^[A-Z0-9][A-Z0-9-]{0,39}$'),
  serial_number text,
  condition text NOT NULL DEFAULT 'good' CHECK (condition IN ('new', 'good', 'fair', 'poor', 'damaged')),
  status text NOT NULL DEFAULT 'available'
    CHECK (status IN ('available', 'checked_out', 'in_inspection', 'in_maintenance', 'in_transit', 'lost', 'retired')),
  unavailable_until timestamptz,
  acquisition_cost_cents bigint NOT NULL DEFAULT 0 CHECK (acquisition_cost_cents >= 0),
  acquired_on date,
  notes text,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, tag),
  FOREIGN KEY (organization_id, product_id, product_tracking) REFERENCES products (organization_id, id, tracking),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id)
);
CREATE INDEX assets_product_branch_idx ON assets (organization_id, product_id, branch_id);
CREATE UNIQUE INDEX assets_serial_key ON assets (organization_id, product_id, serial_number) WHERE serial_number IS NOT NULL;

-- Histórico do ativo: somente inserção.
CREATE TABLE asset_events (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  kind text NOT NULL,
  from_status text,
  to_status text,
  from_branch_id uuid,
  to_branch_id uuid,
  actor_id uuid,
  reference_type text,
  reference_id uuid,
  notes text,
  occurred_at timestamptz NOT NULL,
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id)
);
CREATE INDEX asset_events_asset_idx ON asset_events (organization_id, asset_id, occurred_at DESC);
REVOKE UPDATE, DELETE ON asset_events FROM locentra_app, locentra_worker;

CREATE TABLE stock_pools (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_tracking text NOT NULL DEFAULT 'bulk' CHECK (product_tracking = 'bulk'),
  branch_id uuid NOT NULL,
  total_quantity integer NOT NULL DEFAULT 0 CHECK (total_quantity >= 0),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, product_id, branch_id),
  FOREIGN KEY (organization_id, product_id, product_tracking) REFERENCES products (organization_id, id, tracking),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id)
);

CREATE TABLE stock_movements (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  stock_pool_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('acquisition', 'write_off', 'loss', 'adjustment', 'transfer_out', 'transfer_in')),
  quantity_delta integer NOT NULL CHECK (quantity_delta <> 0),
  reason text,
  actor_id uuid,
  reference_type text,
  reference_id uuid,
  occurred_at timestamptz NOT NULL,
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id)
);
CREATE INDEX stock_movements_pool_idx ON stock_movements (organization_id, stock_pool_id, occurred_at DESC);
REVOKE UPDATE, DELETE ON stock_movements FROM locentra_app, locentra_worker;

SELECT app_enable_tenant_rls('customers');
SELECT app_enable_tenant_rls('customer_contacts');
SELECT app_enable_tenant_rls('customer_addresses');
SELECT app_enable_tenant_rls('products');
SELECT app_enable_tenant_rls('kit_components');
SELECT app_enable_tenant_rls('assets');
SELECT app_enable_tenant_rls('asset_events');
SELECT app_enable_tenant_rls('stock_pools');
SELECT app_enable_tenant_rls('stock_movements');
