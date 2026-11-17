-- Financeiro: contas a receber, pagamentos, reembolsos, cauções, diário contábil, contas de provedores
-- de pagamento, simulador local, conciliação, alertas financeiros e faturas comerciais.
--
-- Garantias no banco (defesa em profundidade; as regras também existem no domínio):
-- * Registros confirmados são imutáveis: triggers recusam UPDATE em pagamentos e reembolsos
--   concluídos, e em cobranças e cauções; lançamentos, cancelamentos e movimentos de caução são
--   somente inserção (UPDATE/DELETE revogados). Correções ocorrem por operações compensatórias.
-- * A soma dos reembolsos pendentes e confirmados nunca excede o valor do pagamento (trigger com lock).
-- * Aplicações e devoluções de caução nunca excedem o saldo recebido (trigger com lock).
-- * Cada transação contábil é balanceada (débito = crédito), verificada no COMMIT.

-- Conta de provedor procurada pelo webhook público antes de existir contexto de tenant. A aplicação
-- define app.payment_account_id com o identificador da URL e só enxerga essa linha; o token é
-- verificado em seguida e o tenant passa a ser o da conta.
CREATE FUNCTION app_payment_account_id() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT NULLIF(current_setting('app.payment_account_id', true), '')::uuid $$;
GRANT EXECUTE ON FUNCTION app_payment_account_id() TO locentra_app, locentra_worker;

CREATE FUNCTION app_forbid_financial_update() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  RAISE EXCEPTION 'registro financeiro imutável em %: use uma operação compensatória', TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$;

-- ---------------------------------------------------------------------------
-- Contas de provedores de pagamento por organização. A chave de API é cifrada (AES-256-GCM pela
-- aplicação) e o token de autenticação dos webhooks recebidos é armazenado apenas como SHA-256.
-- ---------------------------------------------------------------------------
CREATE TABLE payment_provider_accounts (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  provider text NOT NULL CHECK (provider IN ('simulator', 'asaas')),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 80),
  environment text NOT NULL DEFAULT 'sandbox' CHECK (environment IN ('sandbox', 'production')),
  api_key_ciphertext text,
  api_key_hint text,
  webhook_token_digest text NOT NULL CHECK (webhook_token_digest ~ '^[0-9a-f]{64}$'),
  webhook_token_hint text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL,
  deactivated_at timestamptz,
  UNIQUE (organization_id, id),
  CHECK (provider <> 'asaas' OR api_key_ciphertext IS NOT NULL),
  CHECK (active = (deactivated_at IS NULL))
);
CREATE UNIQUE INDEX payment_provider_accounts_active_key ON payment_provider_accounts (organization_id) WHERE active;
REVOKE DELETE ON payment_provider_accounts FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Contas a receber. A origem (source_type, source_id) é única: a sincronização com reservas e
-- ajustes é idempotente. O valor nunca muda; cancelamento é uma operação compensatória registrada.
-- ---------------------------------------------------------------------------
CREATE TABLE receivables (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  reservation_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('rental', 'extension', 'late_fee', 'damage', 'missing', 'cancellation_fee', 'other')),
  source_type text NOT NULL CHECK (source_type IN ('reservation', 'reservation_adjustment', 'manual')),
  source_id uuid NOT NULL,
  description text NOT NULL CHECK (length(description) BETWEEN 1 AND 300),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL DEFAULT 'BRL' CHECK (currency = 'BRL'),
  due_on date NOT NULL,
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, source_type, source_id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  CHECK ((source_type = 'reservation') = (kind = 'rental'))
);
CREATE INDEX receivables_reservation_idx ON receivables (organization_id, reservation_id);
CREATE INDEX receivables_customer_idx ON receivables (organization_id, customer_id, due_on);
CREATE TRIGGER receivables_immutable BEFORE UPDATE ON receivables FOR EACH ROW EXECUTE FUNCTION app_forbid_financial_update();
REVOKE DELETE ON receivables FROM locentra_app, locentra_worker;

CREATE TABLE receivable_cancellations (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  receivable_id uuid NOT NULL,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  reason text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500),
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, receivable_id),
  FOREIGN KEY (organization_id, receivable_id) REFERENCES receivables (organization_id, id)
);
REVOKE UPDATE, DELETE ON receivable_cancellations FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Cauções: valores de terceiros (passivo), nunca receita. A pré-autorização em cartão está modelada,
-- mas é recusada pela aplicação: exige tokenização no provedor e o produto não armazena PAN/CVV.
-- ---------------------------------------------------------------------------
CREATE TABLE deposits (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  reservation_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('paid_deposit', 'card_preauthorization')),
  expected_cents bigint NOT NULL CHECK (expected_cents > 0),
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, reservation_id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id)
);
CREATE TRIGGER deposits_immutable BEFORE UPDATE ON deposits FOR EACH ROW EXECUTE FUNCTION app_forbid_financial_update();
REVOKE DELETE ON deposits FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Pagamentos (parciais), com finalidade cobrança ou caução. A referência externa enviada ao provedor
-- é o próprio identificador do pagamento (estável entre tentativas e na conciliação).
-- ---------------------------------------------------------------------------
CREATE TABLE payments (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  purpose text NOT NULL CHECK (purpose IN ('receivable', 'deposit')),
  receivable_id uuid,
  deposit_id uuid,
  reservation_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  method text NOT NULL CHECK (method IN ('pix', 'boleto', 'card', 'cash', 'transfer')),
  provider text NOT NULL CHECK (provider IN ('manual', 'simulator', 'asaas')),
  provider_account_id uuid,
  status text NOT NULL
    CHECK (status IN ('pending_submission', 'submission_unknown', 'pending', 'confirmed', 'failed', 'cancelled')),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL DEFAULT 'BRL' CHECK (currency = 'BRL'),
  external_reference text NOT NULL,
  provider_payment_id text CHECK (provider_payment_id IS NULL OR length(provider_payment_id) BETWEEN 1 AND 100),
  invoice_url text CHECK (invoice_url IS NULL OR (invoice_url ~ '^https?://' AND length(invoice_url) <= 2000)),
  due_on date,
  simulator_scenario text CHECK (simulator_scenario IS NULL OR simulator_scenario IN ('success', 'fail', 'timeout_after_success')),
  requires_review boolean NOT NULL DEFAULT false,
  review_reason text,
  failure_reason text,
  submission_attempts integer NOT NULL DEFAULT 0 CHECK (submission_attempts >= 0),
  notes text,
  paid_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, external_reference),
  FOREIGN KEY (organization_id, receivable_id) REFERENCES receivables (organization_id, id),
  FOREIGN KEY (organization_id, deposit_id) REFERENCES deposits (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  FOREIGN KEY (organization_id, provider_account_id) REFERENCES payment_provider_accounts (organization_id, id),
  CHECK (external_reference = id::text),
  CHECK ((purpose = 'receivable') = (receivable_id IS NOT NULL)),
  CHECK ((purpose = 'deposit') = (deposit_id IS NOT NULL)),
  CHECK ((provider = 'manual') = (provider_account_id IS NULL)),
  CHECK (provider <> 'manual' OR status = 'confirmed'),
  CHECK (provider = 'manual' OR method IN ('pix', 'boleto', 'card')),
  CHECK (simulator_scenario IS NULL OR provider = 'simulator'),
  CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL)),
  CHECK (requires_review = (review_reason IS NOT NULL))
);
CREATE UNIQUE INDEX payments_provider_payment_key ON payments (organization_id, provider_account_id, provider_payment_id)
  WHERE provider_payment_id IS NOT NULL;
CREATE INDEX payments_receivable_idx ON payments (organization_id, receivable_id) WHERE receivable_id IS NOT NULL;
CREATE INDEX payments_deposit_idx ON payments (organization_id, deposit_id) WHERE deposit_id IS NOT NULL;
CREATE INDEX payments_reservation_idx ON payments (organization_id, reservation_id, created_at DESC);
CREATE INDEX payments_open_idx ON payments (organization_id, status, created_at)
  WHERE status IN ('pending_submission', 'submission_unknown', 'pending');

-- Pagamentos concluídos (confirmados, falhos ou cancelados) não mudam; os dados de origem não mudam nunca.
CREATE FUNCTION payments_guard() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status IN ('confirmed', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'pagamento % imutável na situação %: use uma operação compensatória', OLD.id, OLD.status
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.organization_id <> OLD.organization_id OR NEW.amount_cents <> OLD.amount_cents OR NEW.purpose <> OLD.purpose
     OR NEW.receivable_id IS DISTINCT FROM OLD.receivable_id OR NEW.deposit_id IS DISTINCT FROM OLD.deposit_id
     OR NEW.reservation_id <> OLD.reservation_id OR NEW.customer_id <> OLD.customer_id OR NEW.method <> OLD.method
     OR NEW.provider <> OLD.provider OR NEW.provider_account_id IS DISTINCT FROM OLD.provider_account_id
     OR NEW.external_reference <> OLD.external_reference OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'dados de origem do pagamento % não podem ser alterados', OLD.id USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER payments_guard BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION payments_guard();
REVOKE DELETE ON payments FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Reembolsos de pagamentos de cobranças.
-- ---------------------------------------------------------------------------
CREATE TABLE refunds (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  payment_id uuid NOT NULL,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  reason text NOT NULL CHECK (length(reason) BETWEEN 3 AND 500),
  status text NOT NULL CHECK (status IN ('pending', 'confirmed', 'failed')),
  provider_reference text,
  failure_reason text,
  created_by uuid,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  confirmed_at timestamptz,
  failed_at timestamptz,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, payment_id) REFERENCES payments (organization_id, id),
  CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL)),
  CHECK ((status = 'failed') = (failed_at IS NOT NULL))
);
CREATE INDEX refunds_payment_idx ON refunds (organization_id, payment_id);

CREATE FUNCTION refunds_within_payment() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  paid bigint;
  payment_status text;
  committed bigint;
BEGIN
  SELECT amount_cents, status INTO paid, payment_status
    FROM payments WHERE organization_id = NEW.organization_id AND id = NEW.payment_id FOR UPDATE;
  IF payment_status IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'reembolso exige pagamento confirmado' USING ERRCODE = 'check_violation';
  END IF;
  SELECT COALESCE(sum(amount_cents), 0) INTO committed
    FROM refunds WHERE organization_id = NEW.organization_id AND payment_id = NEW.payment_id AND status IN ('pending', 'confirmed');
  IF committed + NEW.amount_cents > paid THEN
    RAISE EXCEPTION 'reembolsos acima do valor confirmado do pagamento' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER refunds_within_payment BEFORE INSERT ON refunds FOR EACH ROW EXECUTE FUNCTION refunds_within_payment();

CREATE FUNCTION refunds_guard() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status IN ('confirmed', 'failed') THEN
    RAISE EXCEPTION 'reembolso % imutável na situação %', OLD.id, OLD.status USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.amount_cents <> OLD.amount_cents OR NEW.payment_id <> OLD.payment_id OR NEW.organization_id <> OLD.organization_id THEN
    RAISE EXCEPTION 'dados de origem do reembolso % não podem ser alterados', OLD.id USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER refunds_guard BEFORE UPDATE ON refunds FOR EACH ROW EXECUTE FUNCTION refunds_guard();
REVOKE DELETE ON refunds FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Movimentos de caução: recebimento (por pagamento), aplicação a uma cobrança e devolução.
-- ---------------------------------------------------------------------------
CREATE TABLE deposit_entries (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  deposit_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('receive', 'apply', 'return')),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  payment_id uuid,
  receivable_id uuid,
  method text CHECK (method IS NULL OR method IN ('pix', 'boleto', 'card', 'cash', 'transfer')),
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, deposit_id) REFERENCES deposits (organization_id, id),
  FOREIGN KEY (organization_id, payment_id) REFERENCES payments (organization_id, id),
  FOREIGN KEY (organization_id, receivable_id) REFERENCES receivables (organization_id, id),
  CHECK ((kind = 'receive') = (payment_id IS NOT NULL)),
  CHECK ((kind = 'apply') = (receivable_id IS NOT NULL)),
  CHECK (kind <> 'return' OR method IS NOT NULL)
);
CREATE UNIQUE INDEX deposit_entries_payment_key ON deposit_entries (organization_id, payment_id) WHERE payment_id IS NOT NULL;
CREATE INDEX deposit_entries_deposit_idx ON deposit_entries (organization_id, deposit_id, created_at);
CREATE INDEX deposit_entries_receivable_idx ON deposit_entries (organization_id, receivable_id) WHERE receivable_id IS NOT NULL;

CREATE FUNCTION deposit_entries_within_balance() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  balance bigint;
BEGIN
  IF NEW.kind = 'receive' THEN
    RETURN NEW;
  END IF;
  PERFORM 1 FROM deposits WHERE organization_id = NEW.organization_id AND id = NEW.deposit_id FOR UPDATE;
  SELECT COALESCE(sum(CASE WHEN kind = 'receive' THEN amount_cents ELSE -amount_cents END), 0) INTO balance
    FROM deposit_entries WHERE organization_id = NEW.organization_id AND deposit_id = NEW.deposit_id;
  IF NEW.amount_cents > balance THEN
    RAISE EXCEPTION 'movimento acima do saldo da caução' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER deposit_entries_within_balance BEFORE INSERT ON deposit_entries FOR EACH ROW EXECUTE FUNCTION deposit_entries_within_balance();
REVOKE UPDATE, DELETE ON deposit_entries FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Diário contábil: somente inserção, partidas dobradas por transação contábil.
-- ---------------------------------------------------------------------------
CREATE TABLE financial_entries (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  transaction_id uuid NOT NULL,
  position smallint NOT NULL CHECK (position > 0),
  account text NOT NULL
    CHECK (account IN ('receivable', 'rental_revenue', 'additional_revenue', 'cash', 'deposit_liability', 'refunds_payable')),
  debit_cents bigint NOT NULL DEFAULT 0 CHECK (debit_cents >= 0),
  credit_cents bigint NOT NULL DEFAULT 0 CHECK (credit_cents >= 0),
  source_type text NOT NULL CHECK (source_type ~ '^[a-z_]{1,40}$'),
  source_id uuid NOT NULL,
  memo text NOT NULL,
  occurred_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, transaction_id, position),
  CHECK ((debit_cents > 0) <> (credit_cents > 0))
);
CREATE INDEX financial_entries_source_idx ON financial_entries (organization_id, source_type, source_id);
CREATE INDEX financial_entries_account_idx ON financial_entries (organization_id, account, occurred_at);

CREATE FUNCTION financial_entries_balanced() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  difference bigint;
BEGIN
  SELECT COALESCE(sum(debit_cents), 0) - COALESCE(sum(credit_cents), 0) INTO difference
    FROM financial_entries WHERE organization_id = NEW.organization_id AND transaction_id = NEW.transaction_id;
  IF difference <> 0 THEN
    RAISE EXCEPTION 'transação contábil % desbalanceada', NEW.transaction_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER financial_entries_balanced AFTER INSERT ON financial_entries
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION financial_entries_balanced();
REVOKE UPDATE, DELETE ON financial_entries FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Alertas financeiros que exigem decisão (ex.: pagamento após expiração ou cancelamento da reserva).
-- ---------------------------------------------------------------------------
CREATE TABLE finance_alerts (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  kind text NOT NULL CHECK (kind IN ('payment_after_expiration', 'payment_after_cancellation', 'payment_amount_mismatch',
                                     'reservation_closed_with_charges', 'duplicate_provider_charge')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  reservation_id uuid,
  payment_id uuid,
  message text NOT NULL,
  dedupe_key text NOT NULL,
  resolution text CHECK (resolution IS NULL OR resolution IN ('refund', 'new_reservation', 'no_action')),
  resolution_notes text,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, dedupe_key),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, payment_id) REFERENCES payments (organization_id, id),
  CHECK ((status = 'resolved') = (resolved_at IS NOT NULL)),
  CHECK (status = 'open' OR resolution IS NOT NULL)
);
CREATE INDEX finance_alerts_open_idx ON finance_alerts (organization_id, created_at DESC) WHERE status = 'open';
REVOKE DELETE ON finance_alerts FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Simulador local determinístico: o "lado do provedor" persistido no banco. Não há unicidade por
-- referência externa, como num provedor real: um reenvio às cegas criaria uma segunda cobrança.
-- ---------------------------------------------------------------------------
CREATE TABLE payment_simulator_charges (
  id text PRIMARY KEY CHECK (id ~ '^sim_[0-9a-f]{32}$'),
  organization_id uuid NOT NULL REFERENCES organizations (id),
  account_id uuid NOT NULL,
  external_reference text NOT NULL,
  customer_reference text NOT NULL,
  billing_type text NOT NULL CHECK (billing_type IN ('PIX', 'BOLETO', 'CREDIT_CARD')),
  value_cents bigint NOT NULL CHECK (value_cents > 0),
  due_date date NOT NULL,
  status text NOT NULL CHECK (status IN ('PENDING', 'RECEIVED', 'REFUNDED', 'DELETED')),
  refunds jsonb NOT NULL DEFAULT '[]',
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  FOREIGN KEY (organization_id, account_id) REFERENCES payment_provider_accounts (organization_id, id)
);
CREATE INDEX payment_simulator_charges_reference_idx ON payment_simulator_charges (organization_id, account_id, external_reference);

-- ---------------------------------------------------------------------------
-- Conciliação com o provedor: relatório por execução e divergências encontradas.
-- ---------------------------------------------------------------------------
CREATE TABLE reconciliation_reports (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  account_id uuid NOT NULL,
  provider text NOT NULL,
  status text NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
  window_start timestamptz NOT NULL,
  started_at timestamptz NOT NULL,
  finished_at timestamptz,
  summary jsonb NOT NULL DEFAULT '{}',
  error text,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, account_id) REFERENCES payment_provider_accounts (organization_id, id)
);
CREATE INDEX reconciliation_reports_org_idx ON reconciliation_reports (organization_id, started_at DESC);
REVOKE DELETE ON reconciliation_reports FROM locentra_app, locentra_worker;

CREATE TABLE reconciliation_items (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  report_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('missing_remote', 'missing_local', 'status_mismatch', 'amount_mismatch', 'duplicate_remote')),
  payment_id uuid,
  provider_payment_id text,
  external_reference text,
  local_status text,
  remote_status text,
  local_amount_cents bigint,
  remote_amount_cents bigint,
  action text NOT NULL CHECK (action IN ('review', 'local_updated', 'resubmission_scheduled')),
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, report_id) REFERENCES reconciliation_reports (organization_id, id),
  FOREIGN KEY (organization_id, payment_id) REFERENCES payments (organization_id, id)
);
CREATE INDEX reconciliation_items_report_idx ON reconciliation_items (organization_id, report_id);
REVOKE UPDATE, DELETE ON reconciliation_items FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Faturas comerciais (demonstrativo de cobranças). Não são documentos fiscais: emissão de NFS-e está
-- fora do escopo. Cada fatura é um retrato numerado e imutável das cobranças da reserva.
-- ---------------------------------------------------------------------------
CREATE TABLE invoices (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  number text NOT NULL,
  reservation_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  total_cents bigint NOT NULL CHECK (total_cents >= 0),
  settled_cents bigint NOT NULL,
  outstanding_cents bigint NOT NULL,
  lines jsonb NOT NULL,
  notes text,
  created_by uuid,
  issued_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, number),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id)
);
CREATE INDEX invoices_reservation_idx ON invoices (organization_id, reservation_id, issued_at DESC);
REVOKE UPDATE, DELETE ON invoices FROM locentra_app, locentra_worker;

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- ---------------------------------------------------------------------------
SELECT app_enable_tenant_rls('payment_provider_accounts');
SELECT app_enable_tenant_rls('receivables');
SELECT app_enable_tenant_rls('receivable_cancellations');
SELECT app_enable_tenant_rls('deposits');
SELECT app_enable_tenant_rls('payments');
SELECT app_enable_tenant_rls('refunds');
SELECT app_enable_tenant_rls('deposit_entries');
SELECT app_enable_tenant_rls('financial_entries');
SELECT app_enable_tenant_rls('finance_alerts');
SELECT app_enable_tenant_rls('payment_simulator_charges');
SELECT app_enable_tenant_rls('reconciliation_reports');
SELECT app_enable_tenant_rls('reconciliation_items');
SELECT app_enable_tenant_rls('invoices');

CREATE POLICY webhook_account_lookup ON payment_provider_accounts FOR SELECT USING (id = app_payment_account_id());
