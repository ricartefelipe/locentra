-- Orçamentos versionados, conversão idempotente em reserva e contratos de locação com documentos
-- versionados, aceite eletrônico simples e aditivos.
--
-- Garantias:
-- * Conteúdo das versões de orçamento é imutável: somente o instante de envio (sent_at) é
--   preenchido, uma única vez (privilégio de coluna e trigger).
-- * Aprovação registrada (versão, quem aprovou, IP e instante) não muda; orçamento convertido não
--   muda mais (trigger).
-- * Uma reserva por orçamento: índice único parcial em reservations (organization_id, quote_id).
-- * Um contrato por reserva; termos, partes e número do contrato são imutáveis após a emissão
--   (trigger); contratos encerrados ou cancelados não mudam mais.
-- * Documentos do contrato são imutáveis; somente os campos de aceite podem ser preenchidos uma vez.
-- * Aditivos são somente inserção.

CREATE TABLE quotes (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL,
  customer_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'sent', 'approved', 'rejected', 'expired', 'converted')),
  current_version integer NOT NULL DEFAULT 1 CHECK (current_version >= 1),
  approved_version integer CHECK (approved_version IS NULL OR approved_version >= 1),
  hold_policy text NOT NULL DEFAULT 'none' CHECK (hold_policy IN ('none', 'hold_on_send')),
  hold_minutes integer CHECK (hold_minutes IS NULL OR hold_minutes BETWEEN 5 AND 1440),
  hold_reservation_id uuid,
  reservation_id uuid,
  sent_at timestamptz,
  approved_at timestamptz,
  approved_by_type text CHECK (approved_by_type IS NULL OR approved_by_type IN ('staff', 'customer')),
  approved_by_user_id uuid,
  approved_by_name text CHECK (approved_by_name IS NULL OR length(approved_by_name) BETWEEN 2 AND 160),
  approved_ip text,
  rejected_at timestamptz,
  rejection_reason text,
  expired_at timestamptz,
  converted_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  lock_version integer NOT NULL DEFAULT 1,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, hold_reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  CHECK (approved_version IS NULL OR approved_version <= current_version),
  CHECK ((status IN ('approved', 'converted')) = (approved_version IS NOT NULL AND approved_at IS NOT NULL AND approved_by_type IS NOT NULL)),
  CHECK ((status = 'converted') = (reservation_id IS NOT NULL)),
  CHECK (status <> 'sent' OR sent_at IS NOT NULL),
  CHECK (hold_policy = 'none' OR hold_minutes IS NOT NULL)
);
CREATE INDEX quotes_org_status_idx ON quotes (organization_id, status, created_at DESC);
CREATE INDEX quotes_customer_idx ON quotes (organization_id, customer_id, created_at DESC);
CREATE INDEX quotes_hold_idx ON quotes (organization_id, hold_reservation_id) WHERE hold_reservation_id IS NOT NULL;
REVOKE DELETE ON quotes FROM locentra_app, locentra_worker;

-- Evidências históricas do orçamento: organização, cliente, criação e número definitivo são fixos; a
-- versão atual só avança; depois da aprovação, versão aprovada, quem aprovou, usuário, IP e instante
-- não mudam e o único destino é a conversão; orçamento convertido não muda mais.
CREATE FUNCTION quotes_protect_history() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status = 'converted' THEN
    RAISE EXCEPTION 'orçamento convertido não pode ser alterado' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
     OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR (NEW.code IS DISTINCT FROM OLD.code AND OLD.code NOT LIKE 'PEND-%')
     OR NEW.current_version < OLD.current_version THEN
    RAISE EXCEPTION 'identificação do orçamento é imutável' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.approved_at IS NOT NULL AND (
       NEW.status NOT IN ('approved', 'converted')
       OR (NEW.approved_version, NEW.approved_at, NEW.approved_by_type, NEW.approved_by_user_id, NEW.approved_by_name, NEW.approved_ip,
           NEW.current_version, NEW.branch_id, NEW.hold_reservation_id)
          IS DISTINCT FROM
          (OLD.approved_version, OLD.approved_at, OLD.approved_by_type, OLD.approved_by_user_id, OLD.approved_by_name, OLD.approved_ip,
           OLD.current_version, OLD.branch_id, OLD.hold_reservation_id)) THEN
    RAISE EXCEPTION 'aprovação registrada do orçamento é imutável' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER quotes_protect_history BEFORE UPDATE ON quotes FOR EACH ROW EXECUTE FUNCTION quotes_protect_history();

-- Cada versão guarda o conteúdo proposto ao cliente e o snapshot de preços calculado no momento.
-- `sent_at` registra o envio da versão (cada versão é enviada no máximo uma vez): o cliente só
-- enxerga versões enviadas.
CREATE TABLE quote_versions (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  quote_id uuid NOT NULL,
  version integer NOT NULL CHECK (version >= 1),
  branch_id uuid NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  valid_until timestamptz NOT NULL,
  items jsonb NOT NULL CHECK (jsonb_typeof(items) = 'array' AND jsonb_array_length(items) > 0),
  pricing jsonb NOT NULL CHECK (jsonb_typeof(pricing) = 'object'),
  terms text CHECK (terms IS NULL OR length(terms) <= 5000),
  manual_discount_bps integer NOT NULL DEFAULT 0 CHECK (manual_discount_bps BETWEEN 0 AND 10000),
  deposit_cents bigint NOT NULL CHECK (deposit_cents >= 0),
  total_cents bigint NOT NULL CHECK (total_cents >= 0),
  created_by uuid,
  created_at timestamptz NOT NULL,
  sent_at timestamptz,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, quote_id, version),
  FOREIGN KEY (organization_id, quote_id) REFERENCES quotes (organization_id, id),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id),
  CHECK (ends_at > starts_at)
);
REVOKE UPDATE, DELETE ON quote_versions FROM locentra_app, locentra_worker;
GRANT UPDATE (sent_at) ON quote_versions TO locentra_app, locentra_worker;

CREATE FUNCTION quote_versions_protect() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.sent_at IS NOT NULL OR NEW.sent_at IS NULL THEN
    RAISE EXCEPTION 'o envio da versão do orçamento é registrado uma única vez' USING ERRCODE = 'check_violation';
  END IF;
  IF (NEW.id, NEW.organization_id, NEW.quote_id, NEW.version, NEW.branch_id, NEW.starts_at, NEW.ends_at, NEW.valid_until, NEW.items,
      NEW.pricing, NEW.terms, NEW.manual_discount_bps, NEW.deposit_cents, NEW.total_cents, NEW.created_by, NEW.created_at)
     IS DISTINCT FROM
     (OLD.id, OLD.organization_id, OLD.quote_id, OLD.version, OLD.branch_id, OLD.starts_at, OLD.ends_at, OLD.valid_until, OLD.items,
      OLD.pricing, OLD.terms, OLD.manual_discount_bps, OLD.deposit_cents, OLD.total_cents, OLD.created_by, OLD.created_at) THEN
    RAISE EXCEPTION 'versão de orçamento é imutável' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER quote_versions_protect BEFORE UPDATE ON quote_versions FOR EACH ROW EXECUTE FUNCTION quote_versions_protect();

-- Conversão idempotente: no máximo uma reserva por orçamento, inclusive sob concorrência.
ALTER TABLE reservations
  ADD CONSTRAINT reservations_quote_fk FOREIGN KEY (organization_id, quote_id) REFERENCES quotes (organization_id, id);
CREATE UNIQUE INDEX reservations_quote_key ON reservations (organization_id, quote_id) WHERE quote_id IS NOT NULL;

CREATE TABLE contracts (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL,
  reservation_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  quote_id uuid,
  status text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'active', 'closed', 'cancelled')),
  terms_snapshot jsonb NOT NULL CHECK (jsonb_typeof(terms_snapshot) = 'object'),
  current_document_version integer NOT NULL DEFAULT 1 CHECK (current_document_version >= 1),
  issued_by uuid,
  issued_at timestamptz NOT NULL,
  activated_at timestamptz,
  closed_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  cancellation_fee_cents bigint CHECK (cancellation_fee_cents IS NULL OR cancellation_fee_cents >= 0),
  updated_at timestamptz NOT NULL,
  lock_version integer NOT NULL DEFAULT 1,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  UNIQUE (reservation_id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  FOREIGN KEY (organization_id, quote_id) REFERENCES quotes (organization_id, id),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  CHECK ((status = 'closed') = (closed_at IS NOT NULL)),
  CHECK (status <> 'active' OR activated_at IS NOT NULL)
);
CREATE INDEX contracts_org_status_idx ON contracts (organization_id, status, issued_at DESC);
CREATE INDEX contracts_customer_idx ON contracts (organization_id, customer_id, issued_at DESC);
REVOKE DELETE ON contracts FROM locentra_app, locentra_worker;

-- Termos, partes, reserva e número definitivo do contrato não mudam após a emissão. O número é
-- atribuído uma única vez (substitui o identificador provisório PEND-*).
CREATE FUNCTION contracts_protect_terms() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status IN ('closed', 'cancelled') THEN
    RAISE EXCEPTION 'contrato encerrado ou cancelado não pode ser alterado' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.reservation_id IS DISTINCT FROM OLD.reservation_id
     OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
     OR NEW.quote_id IS DISTINCT FROM OLD.quote_id
     OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
     OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
     OR NEW.issued_by IS DISTINCT FROM OLD.issued_by
     OR (NEW.code IS DISTINCT FROM OLD.code AND OLD.code NOT LIKE 'PEND-%')
     OR NEW.current_document_version < OLD.current_document_version THEN
    RAISE EXCEPTION 'termos do contrato emitido são imutáveis' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER contracts_protect_terms BEFORE UPDATE ON contracts FOR EACH ROW EXECUTE FUNCTION contracts_protect_terms();

-- Documentos gerados (PDF em attachments) com o snapshot de dados usado na geração. Campos de
-- aceite eletrônico simples: preenchidos uma única vez.
CREATE TABLE contract_documents (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  contract_id uuid NOT NULL,
  version integer NOT NULL CHECK (version >= 1),
  reason text NOT NULL CHECK (reason IN ('issue', 'amendment')),
  attachment_id uuid NOT NULL,
  sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  data_snapshot jsonb NOT NULL CHECK (jsonb_typeof(data_snapshot) = 'object'),
  generated_by uuid,
  generated_at timestamptz NOT NULL,
  accepted_at timestamptz,
  accepted_by_name text CHECK (accepted_by_name IS NULL OR length(accepted_by_name) BETWEEN 3 AND 160),
  accepted_by_document text CHECK (accepted_by_document IS NULL OR accepted_by_document ~ '^[0-9]{11}$' OR accepted_by_document ~ '^[0-9]{14}$'),
  accepted_ip text,
  user_agent text CHECK (user_agent IS NULL OR length(user_agent) <= 500),
  accepted_via text CHECK (accepted_via IS NULL OR accepted_via IN ('staff', 'portal')),
  accepted_by_user_id uuid,
  acceptance_statement text,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, contract_id, version),
  UNIQUE (organization_id, attachment_id),
  FOREIGN KEY (organization_id, contract_id) REFERENCES contracts (organization_id, id),
  FOREIGN KEY (organization_id, attachment_id) REFERENCES attachments (organization_id, id),
  CHECK ((accepted_at IS NULL) = (accepted_by_name IS NULL)),
  CHECK (accepted_at IS NULL OR (accepted_by_document IS NOT NULL AND accepted_via IS NOT NULL AND acceptance_statement IS NOT NULL))
);
CREATE INDEX contract_documents_contract_idx ON contract_documents (organization_id, contract_id, version DESC);
REVOKE DELETE ON contract_documents FROM locentra_app, locentra_worker;

CREATE FUNCTION contract_documents_immutable() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'documento com aceite registrado é imutável' USING ERRCODE = 'check_violation';
  END IF;
  IF (NEW.id, NEW.organization_id, NEW.contract_id, NEW.version, NEW.reason, NEW.attachment_id, NEW.sha256, NEW.data_snapshot,
      NEW.generated_by, NEW.generated_at)
     IS DISTINCT FROM
     (OLD.id, OLD.organization_id, OLD.contract_id, OLD.version, OLD.reason, OLD.attachment_id, OLD.sha256, OLD.data_snapshot,
      OLD.generated_by, OLD.generated_at) THEN
    RAISE EXCEPTION 'documento do contrato é imutável' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER contract_documents_immutable BEFORE UPDATE ON contract_documents FOR EACH ROW EXECUTE FUNCTION contract_documents_immutable();

CREATE TABLE contract_amendments (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  contract_id uuid NOT NULL,
  number integer NOT NULL CHECK (number >= 1),
  kind text NOT NULL CHECK (kind IN ('extension')),
  description text NOT NULL CHECK (length(description) BETWEEN 1 AND 1000),
  changes jsonb NOT NULL CHECK (jsonb_typeof(changes) = 'object'),
  amount_delta_cents bigint NOT NULL,
  document_version integer NOT NULL,
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, contract_id, number),
  FOREIGN KEY (organization_id, contract_id) REFERENCES contracts (organization_id, id),
  FOREIGN KEY (organization_id, contract_id, document_version) REFERENCES contract_documents (organization_id, contract_id, version)
);
REVOKE UPDATE, DELETE ON contract_amendments FROM locentra_app, locentra_worker;

SELECT app_enable_tenant_rls('quotes');
SELECT app_enable_tenant_rls('quote_versions');
SELECT app_enable_tenant_rls('contracts');
SELECT app_enable_tenant_rls('contract_documents');
SELECT app_enable_tenant_rls('contract_amendments');
