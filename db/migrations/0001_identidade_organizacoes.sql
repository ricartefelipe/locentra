-- Fundação: extensões, funções de contexto, permissões padrão, identidade, organizações e planos.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Contexto da transação definido pela aplicação com set_config(..., true) (escopo local).
-- Ausência de contexto resulta em NULL e, portanto, em nenhuma linha visível.
CREATE FUNCTION app_tenant_id() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid $$;

CREATE FUNCTION app_user_id() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT NULLIF(current_setting('app.user_id', true), '')::uuid $$;

-- Aplica isolamento por tenant: RLS habilitada e forçada (inclusive para o proprietário).
CREATE FUNCTION app_enable_tenant_rls(target regclass) RETURNS void
  LANGUAGE plpgsql
  AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', target);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', target);
  EXECUTE format(
    'CREATE POLICY tenant_isolation ON %s USING (organization_id = app_tenant_id()) WITH CHECK (organization_id = app_tenant_id())',
    target);
END;
$$;
REVOKE ALL ON FUNCTION app_enable_tenant_rls(regclass) FROM PUBLIC;

-- Privilégios padrão para objetos criados pelo proprietário do schema.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO locentra_app, locentra_worker;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO locentra_app, locentra_worker;
GRANT SELECT ON schema_migrations TO locentra_app, locentra_worker;
GRANT EXECUTE ON FUNCTION app_tenant_id(), app_user_id() TO locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Catálogo de planos da plataforma (global, somente leitura para a aplicação).
-- ---------------------------------------------------------------------------
CREATE TABLE plans (
  id text PRIMARY KEY CHECK (id ~ '^[a-z0-9_]+$'),
  name text NOT NULL,
  monthly_price_cents bigint NOT NULL CHECK (monthly_price_cents >= 0),
  implementation_fee_cents bigint NOT NULL DEFAULT 0 CHECK (implementation_fee_cents >= 0),
  max_assets integer CHECK (max_assets IS NULL OR max_assets > 0),
  max_branches integer CHECK (max_branches IS NULL OR max_branches > 0),
  max_users integer CHECK (max_users IS NULL OR max_users > 0),
  features text[] NOT NULL DEFAULT '{}',
  position integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true
);
REVOKE INSERT, UPDATE, DELETE ON plans FROM locentra_app, locentra_worker;

-- Valores comerciais são hipóteses de produto e podem ser alterados por nova migration.
INSERT INTO plans (id, name, monthly_price_cents, implementation_fee_cents, max_assets, max_branches, max_users, features, position) VALUES
  ('essencial', 'Essencial', 29900, 150000, 300, 1, 5, '{}', 1),
  ('profissional', 'Profissional', 69900, 350000, 2000, 3, 20, '{portal,api,webhooks,pagamentos_online}', 2),
  ('empresarial', 'Empresarial', 149900, 900000, NULL, NULL, NULL, '{portal,api,webhooks,pagamentos_online}', 3);

-- ---------------------------------------------------------------------------
-- Identidade (global): usuários, sessões, tokens de uso único, limites de taxa.
-- Exceção documentada ao RLS: a autenticação ocorre antes de haver contexto de organização.
-- ---------------------------------------------------------------------------
CREATE TABLE users (
  id uuid PRIMARY KEY,
  email text NOT NULL CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 254),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  password_digest text NOT NULL,
  email_confirmed_at timestamptz,
  failed_login_count integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
  locked_until timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX users_email_key ON users (email);

CREATE TABLE organizations (
  id uuid PRIMARY KEY,
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
  slug text NOT NULL CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(slug) <= 60),
  legal_document text,
  timezone text NOT NULL DEFAULT 'America/Sao_Paulo',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'closed')),
  settings jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX organizations_slug_key ON organizations (slug);

CREATE TABLE sessions (
  id uuid PRIMARY KEY,
  token_digest text NOT NULL,
  kind text NOT NULL DEFAULT 'staff' CHECK (kind IN ('staff', 'portal')),
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  organization_id uuid REFERENCES organizations (id),
  csrf_token text NOT NULL,
  ip text,
  user_agent text,
  created_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  idle_expires_at timestamptz NOT NULL,
  absolute_expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  revoked_reason text
);
CREATE UNIQUE INDEX sessions_token_digest_key ON sessions (token_digest);
CREATE INDEX sessions_user_active_idx ON sessions (user_id) WHERE revoked_at IS NULL;

CREATE TABLE user_tokens (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  purpose text NOT NULL CHECK (purpose IN ('password_reset', 'email_confirmation')),
  token_digest text NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL
);
CREATE UNIQUE INDEX user_tokens_digest_key ON user_tokens (token_digest);
CREATE INDEX user_tokens_user_idx ON user_tokens (user_id, purpose) WHERE used_at IS NULL;

CREATE TABLE rate_limits (
  bucket text NOT NULL,
  window_start timestamptz NOT NULL,
  hits integer NOT NULL CHECK (hits >= 0),
  PRIMARY KEY (bucket, window_start)
);

-- ---------------------------------------------------------------------------
-- Organização (tenant): filiais, vínculos, convites, assinatura, contadores, auditoria.
-- ---------------------------------------------------------------------------
CREATE TABLE branches (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
  code text NOT NULL CHECK (code ~ '^[A-Z0-9-]{1,12}$'),
  address text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code)
);

CREATE TABLE memberships (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  user_id uuid NOT NULL REFERENCES users (id),
  role text NOT NULL CHECK (role IN ('owner', 'admin', 'manager', 'attendant', 'stock_operator', 'finance', 'auditor')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  revoked_at timestamptz,
  revoked_by uuid,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, user_id),
  CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE INDEX memberships_user_idx ON memberships (user_id) WHERE status = 'active';

CREATE TABLE invitations (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  email text NOT NULL CHECK (email = lower(email)),
  role text NOT NULL CHECK (role IN ('admin', 'manager', 'attendant', 'stock_operator', 'finance', 'auditor')),
  token_digest text NOT NULL,
  invited_by uuid NOT NULL REFERENCES users (id),
  expires_at timestamptz NOT NULL,
  accepted_at timestamptz,
  accepted_user_id uuid REFERENCES users (id),
  revoked_at timestamptz,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id)
);
CREATE UNIQUE INDEX invitations_token_key ON invitations (token_digest);
CREATE UNIQUE INDEX invitations_pending_email_key ON invitations (organization_id, email)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

CREATE TABLE subscriptions (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  plan_id text NOT NULL REFERENCES plans (id),
  status text NOT NULL CHECK (status IN ('trialing', 'active', 'past_due', 'suspended', 'cancelled')),
  started_at timestamptz NOT NULL,
  trial_ends_at timestamptz,
  current_period_start date NOT NULL,
  current_period_end date NOT NULL,
  implementation_fee_cents bigint NOT NULL DEFAULT 0 CHECK (implementation_fee_cents >= 0),
  extra_features text[] NOT NULL DEFAULT '{}',
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id),
  CHECK (current_period_end > current_period_start)
);

CREATE TABLE organization_counters (
  organization_id uuid NOT NULL REFERENCES organizations (id),
  name text NOT NULL,
  value bigint NOT NULL CHECK (value >= 0),
  PRIMARY KEY (organization_id, name)
);

CREATE TABLE audit_events (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'api', 'cli', 'system', 'customer')),
  actor_id uuid,
  action text NOT NULL,
  resource_type text NOT NULL,
  resource_id uuid,
  request_id text,
  ip text,
  details jsonb NOT NULL DEFAULT '{}',
  occurred_at timestamptz NOT NULL
);
CREATE INDEX audit_events_org_time_idx ON audit_events (organization_id, occurred_at DESC);
CREATE INDEX audit_events_resource_idx ON audit_events (organization_id, resource_type, resource_id);
-- Registro de auditoria é somente inserção.
REVOKE UPDATE, DELETE ON audit_events FROM locentra_app, locentra_worker;

CREATE TABLE idempotency_keys (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  scope text NOT NULL,
  key text NOT NULL CHECK (length(key) BETWEEN 8 AND 255),
  fingerprint text NOT NULL,
  response_status integer NOT NULL,
  response_body jsonb NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  UNIQUE (organization_id, scope, key)
);
CREATE INDEX idempotency_keys_expiry_idx ON idempotency_keys (expires_at);

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- ---------------------------------------------------------------------------
SELECT app_enable_tenant_rls('branches');
SELECT app_enable_tenant_rls('invitations');
SELECT app_enable_tenant_rls('subscriptions');
SELECT app_enable_tenant_rls('organization_counters');
SELECT app_enable_tenant_rls('audit_events');
SELECT app_enable_tenant_rls('idempotency_keys');

-- Vínculos: visíveis no tenant ativo ou para o próprio usuário (lista de organizações na entrada).
SELECT app_enable_tenant_rls('memberships');
CREATE POLICY own_memberships_read ON memberships FOR SELECT USING (user_id = app_user_id());

-- Organizações: a própria organização do contexto, as organizações das quais o usuário é membro
-- ativo e leitura completa pelo worker (varreduras periódicas por tenant).
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON organizations USING (id = app_tenant_id()) WITH CHECK (id = app_tenant_id());
CREATE POLICY member_read ON organizations FOR SELECT USING (
  EXISTS (SELECT 1 FROM memberships m
          WHERE m.organization_id = organizations.id AND m.user_id = app_user_id() AND m.status = 'active'));
CREATE POLICY worker_read ON organizations FOR SELECT TO locentra_worker USING (true);
