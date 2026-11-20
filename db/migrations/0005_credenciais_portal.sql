-- Credenciais de integração (API e CLI) e acessos ao portal do cliente.

-- O token tem o formato lcn_<organization_id>_<segredo>. A organização extraída do token define o
-- contexto de tenant antes da consulta; o segredo é comparado pelo hash SHA-256.
CREATE TABLE api_credentials (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 80),
  kind text NOT NULL DEFAULT 'api' CHECK (kind IN ('api', 'cli')),
  token_digest text NOT NULL,
  token_hint text NOT NULL,
  scopes text[] NOT NULL CHECK (cardinality(scopes) > 0),
  created_by uuid REFERENCES users (id),
  created_at timestamptz NOT NULL,
  expires_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz,
  UNIQUE (organization_id, id)
);
CREATE UNIQUE INDEX api_credentials_digest_key ON api_credentials (token_digest);

CREATE TABLE portal_accesses (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  user_id uuid NOT NULL REFERENCES users (id),
  customer_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_by uuid,
  created_at timestamptz NOT NULL,
  revoked_at timestamptz,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, user_id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id)
);

SELECT app_enable_tenant_rls('api_credentials');
SELECT app_enable_tenant_rls('portal_accesses');
CREATE POLICY own_portal_read ON portal_accesses FOR SELECT USING (user_id = app_user_id());
CREATE POLICY portal_org_read ON organizations FOR SELECT USING (
  EXISTS (SELECT 1 FROM portal_accesses p
          WHERE p.organization_id = organizations.id AND p.user_id = app_user_id() AND p.status = 'active'));
