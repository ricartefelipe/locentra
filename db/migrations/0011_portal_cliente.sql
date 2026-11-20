-- Portal do cliente: convites de acesso enviados a contatos do cliente e dados do acesso concedido.
--
-- Garantias no banco:
-- * O contato convidado pertence ao cliente do convite e do acesso (chaves estrangeiras compostas
--   com customer_id).
-- * No máximo um convite pendente por e-mail em cada organização (índice único parcial).
-- * O token do convite é guardado somente como SHA-256; o worker substitui o valor no envio.
-- * Convites aceitos ou cancelados não mudam mais; os dados de origem do convite são imutáveis.
-- * Acesso revogado sempre registra o instante da revogação (revogado <=> revoked_at preenchido).

-- Permite referenciar o contato junto com o cliente ao qual ele pertence.
ALTER TABLE customer_contacts ADD CONSTRAINT customer_contacts_customer_key UNIQUE (organization_id, customer_id, id);

CREATE TABLE portal_invitations (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  customer_id uuid NOT NULL,
  contact_id uuid NOT NULL,
  email text NOT NULL CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 254),
  token_digest text NOT NULL,
  invited_by uuid NOT NULL REFERENCES users (id),
  expires_at timestamptz NOT NULL,
  accepted_at timestamptz,
  accepted_user_id uuid REFERENCES users (id),
  revoked_at timestamptz,
  revoked_by uuid REFERENCES users (id),
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  FOREIGN KEY (organization_id, customer_id, contact_id) REFERENCES customer_contacts (organization_id, customer_id, id),
  CHECK (expires_at > created_at),
  CHECK ((accepted_at IS NULL) = (accepted_user_id IS NULL)),
  CHECK (accepted_at IS NULL OR revoked_at IS NULL)
);
CREATE UNIQUE INDEX portal_invitations_token_key ON portal_invitations (token_digest);
CREATE UNIQUE INDEX portal_invitations_pending_email_key ON portal_invitations (organization_id, email)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;
CREATE INDEX portal_invitations_customer_idx ON portal_invitations (organization_id, customer_id, created_at DESC);

CREATE FUNCTION portal_invitations_protect() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.accepted_at IS NOT NULL OR OLD.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'convite do portal encerrado não pode ser alterado' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
     OR NEW.contact_id IS DISTINCT FROM OLD.contact_id OR NEW.email IS DISTINCT FROM OLD.email
     OR NEW.invited_by IS DISTINCT FROM OLD.invited_by OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'dados de origem do convite do portal são imutáveis' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER portal_invitations_protect BEFORE UPDATE ON portal_invitations
  FOR EACH ROW EXECUTE FUNCTION portal_invitations_protect();
REVOKE DELETE ON portal_invitations FROM locentra_app, locentra_worker;
SELECT app_enable_tenant_rls('portal_invitations');

-- Acessos ao portal (tabela da migration 0005): contato e convite de origem, autor da revogação.
ALTER TABLE portal_accesses
  ADD COLUMN contact_id uuid,
  ADD COLUMN invitation_id uuid,
  ADD COLUMN revoked_by uuid REFERENCES users (id),
  ADD COLUMN updated_at timestamptz,
  ADD CONSTRAINT portal_accesses_contact_fkey FOREIGN KEY (organization_id, customer_id, contact_id)
    REFERENCES customer_contacts (organization_id, customer_id, id),
  ADD CONSTRAINT portal_accesses_invitation_fkey FOREIGN KEY (organization_id, invitation_id)
    REFERENCES portal_invitations (organization_id, id),
  ADD CONSTRAINT portal_accesses_revocation_check CHECK ((status = 'revoked') = (revoked_at IS NOT NULL));
CREATE INDEX portal_accesses_customer_idx ON portal_accesses (organization_id, customer_id);
REVOKE DELETE ON portal_accesses FROM locentra_app, locentra_worker;
