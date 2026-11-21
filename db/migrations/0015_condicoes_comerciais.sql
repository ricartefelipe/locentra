-- Condições comerciais: cadastro de cupons com livro de usos, condições negociadas por cliente com
-- vigência e encerramento, e catálogo de tarifas adicionais da organização.
--
-- Garantias:
-- * Código de cupom e de tarifa únicos por organização (formato normalizado pela aplicação); código,
--   tipo e valor do cupom e código da tarifa não são alterados (UPDATE concedido só às colunas editáveis).
-- * Cada uso de cupom é uma linha imutável de coupon_redemptions (no máximo uma por reserva). O uso é
--   ativo enquanto a reserva está solicitada, confirmada, em andamento ou concluída, ou em bloqueio
--   temporário ainda válido; cancelamento e expiração liberam o uso sem escrita. O gatilho de inserção
--   recusa o uso além de max_redemptions sob a trava do cupom (bloqueio vencido conta durante a carência).
--   Cupom com uso registrado não é excluído.
-- * coupons.redemptions é o contador da versão 1.0.0, congelado: a partir desta migration os usos novos
--   são linhas de coupon_redemptions (usos ativos = contador legado + usos ativos do livro).
-- * Condições negociadas não mudam depois de criadas: somente o encerramento (imediato ou agendado) é
--   preenchido, uma única vez. Vigências efetivas do mesmo cliente e escopo não se sobrepõem.
-- * Snapshots de preço de reservas e itens não são alterados.
-- * Preenchimento de colunas novas: com a RLS forçada nem o proprietário enxerga linhas sem contexto de
--   organização; por isso as tabelas afetadas ficam sem FORCE apenas dentro desta transação.

-- Cupons ----------------------------------------------------------------------------------------------
ALTER TABLE coupons NO FORCE ROW LEVEL SECURITY;
ALTER TABLE coupons
  ADD COLUMN description text CHECK (description IS NULL OR length(description) BETWEEN 1 AND 200),
  ADD COLUMN created_by uuid,
  ADD COLUMN updated_at timestamptz,
  ADD COLUMN deactivated_at timestamptz,
  ADD COLUMN lock_version integer NOT NULL DEFAULT 1 CHECK (lock_version > 0);
UPDATE coupons SET updated_at = created_at;
ALTER TABLE coupons ALTER COLUMN updated_at SET NOT NULL;
ALTER TABLE coupons FORCE ROW LEVEL SECURITY;
-- Ordem da vigência e máximo de usos: verificados por gatilho, e não por CHECK, porque a 1.0.0 aceitava fim
-- anterior ao início e máximo acima de 1.000.000. Uma CHECK, mesmo NOT VALID, seria avaliada em qualquer
-- UPDATE da linha e impediria desativar ou reativar esses cupons; o gatilho verifica a inserção e somente
-- as colunas alteradas. A aplicação valida o estado completo antes de editar (erro no campo).
CREATE FUNCTION coupons_enforce_limits() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  validity_changed boolean := true;
  maximum_changed boolean := true;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    validity_changed := NEW.valid_from IS DISTINCT FROM OLD.valid_from OR NEW.valid_until IS DISTINCT FROM OLD.valid_until;
    maximum_changed := NEW.max_redemptions IS DISTINCT FROM OLD.max_redemptions;
  END IF;
  IF validity_changed AND NEW.valid_until <= NEW.valid_from THEN
    RAISE EXCEPTION 'o fim da vigência do cupom deve ser posterior ao início' USING ERRCODE = 'check_violation';
  END IF;
  IF maximum_changed AND NEW.max_redemptions > 1000000 THEN
    RAISE EXCEPTION 'o máximo de usos do cupom é 1.000.000' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER coupons_enforce_limits BEFORE INSERT OR UPDATE ON coupons
  FOR EACH ROW EXECUTE FUNCTION coupons_enforce_limits();
COMMENT ON COLUMN coupons.redemptions IS
  'Usos registrados até a versão 1.0.0 (contador congelado). Usos posteriores: coupon_redemptions.';
CREATE INDEX coupons_org_created_idx ON coupons (organization_id, created_at DESC);
REVOKE UPDATE ON coupons FROM locentra_app, locentra_worker;
-- redemptions continua concedida apenas para o retorno à 1.0.0 (docs/RUNBOOKS.md); a 1.1.0 não grava a coluna.
GRANT UPDATE (description, valid_from, valid_until, max_redemptions, min_subtotal_cents, active, deactivated_at, updated_at,
              lock_version, redemptions) ON coupons TO locentra_app;
REVOKE DELETE ON coupons FROM locentra_worker;

-- Livro de usos ---------------------------------------------------------------------------------------
CREATE TABLE coupon_redemptions (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  coupon_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  subtotal_cents bigint NOT NULL CHECK (subtotal_cents >= 0),
  discount_cents bigint NOT NULL CHECK (discount_cents >= 0),
  redeemed_by uuid,
  redeemed_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, reservation_id),
  FOREIGN KEY (organization_id, coupon_id) REFERENCES coupons (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  CHECK (discount_cents <= subtotal_cents)
);
CREATE INDEX coupon_redemptions_coupon_idx ON coupon_redemptions (organization_id, coupon_id, redeemed_at DESC);
REVOKE UPDATE, DELETE ON coupon_redemptions FROM locentra_app, locentra_worker;

-- Limite de usos verificado no banco sob a trava do cupom. O instante de referência é o do próprio uso
-- (relógio da aplicação), recuado pela carência de 300 s (Domain::Pricing::Redemptions::LIMIT_GRACE): um
-- bloqueio temporário vencido há menos que isso ainda pode estar sendo confirmado por uma transação que
-- leu o relógio antes do vencimento e continua contando para o limite; depois da carência, não conta.
CREATE FUNCTION coupon_redemptions_enforce_limit() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  target record;
  active_count bigint;
BEGIN
  SELECT max_redemptions, redemptions INTO target FROM coupons
   WHERE organization_id = NEW.organization_id AND id = NEW.coupon_id FOR UPDATE;
  IF target.max_redemptions IS NOT NULL THEN
    SELECT count(*) INTO active_count
      FROM coupon_redemptions r
      JOIN reservations v ON v.organization_id = r.organization_id AND v.id = r.reservation_id
     WHERE r.organization_id = NEW.organization_id AND r.coupon_id = NEW.coupon_id
       AND (v.status IN ('requested', 'confirmed', 'in_progress', 'completed')
            OR (v.status = 'held' AND v.hold_expires_at > NEW.redeemed_at - interval '300 seconds'));
    IF target.redemptions + active_count >= target.max_redemptions THEN
      RAISE EXCEPTION 'limite de usos do cupom atingido' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER coupon_redemptions_enforce_limit BEFORE INSERT ON coupon_redemptions
  FOR EACH ROW EXECUTE FUNCTION coupon_redemptions_enforce_limit();

-- Condições negociadas por cliente ----------------------------------------------------------------------
-- Janela efetiva [início, menor entre fim e encerramento); encerramento anterior ao início = janela vazia.
-- LEAST/GREATEST ignoram nulos no PostgreSQL.
CREATE FUNCTION price_agreement_window(starts timestamptz, ends timestamptz, ended timestamptz) RETURNS tstzrange
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  AS $$
    SELECT CASE WHEN LEAST(ends, ended) IS NULL THEN tstzrange(starts, NULL, '[)')
                ELSE tstzrange(starts, GREATEST(starts, LEAST(ends, ended)), '[)') END
  $$;
GRANT EXECUTE ON FUNCTION price_agreement_window(timestamptz, timestamptz, timestamptz) TO locentra_app, locentra_worker;

ALTER TABLE customer_price_agreements NO FORCE ROW LEVEL SECURITY;
ALTER TABLE customer_price_agreements
  ADD COLUMN valid_from timestamptz,
  ADD COLUMN ended_at timestamptz,
  ADD COLUMN ended_by uuid,
  ADD COLUMN end_reason text CHECK (end_reason IS NULL OR length(end_reason) BETWEEN 3 AND 500);
UPDATE customer_price_agreements SET valid_from = created_at;
ALTER TABLE customer_price_agreements ALTER COLUMN valid_from SET NOT NULL;
ALTER TABLE customer_price_agreements
  ADD CONSTRAINT customer_price_agreements_validity_check CHECK (valid_until IS NULL OR valid_until > valid_from) NOT VALID,
  ADD CONSTRAINT customer_price_agreements_end_check
    CHECK ((ended_at IS NULL) = (end_reason IS NULL) AND (ended_at IS NOT NULL OR ended_by IS NULL));

-- A 1.0.0 aceitava condições sobrepostas (aplicava a maior vigente). Elas precisam ser ajustadas antes
-- desta migration (docs/RUNBOOKS.md, verificação prévia); a migration não escolhe qual manter.
DO $$
DECLARE
  conflict record;
BEGIN
  SELECT a.organization_id, a.customer_id, count(*) OVER () AS total INTO conflict
    FROM customer_price_agreements a
    JOIN customer_price_agreements b
      ON b.organization_id = a.organization_id AND b.customer_id = a.customer_id
     AND b.product_id IS NOT DISTINCT FROM a.product_id AND b.id > a.id
     AND price_agreement_window(a.valid_from, a.valid_until, a.ended_at) && price_agreement_window(b.valid_from, b.valid_until, b.ended_at)
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'migração 0015: % par(es) de condições negociadas com vigências sobrepostas (organização %, cliente %); ajuste as vigências conforme docs/RUNBOOKS.md antes de migrar',
      conflict.total, conflict.organization_id, conflict.customer_id;
  END IF;
END;
$$;

ALTER TABLE customer_price_agreements ADD CONSTRAINT customer_price_agreements_no_overlap EXCLUDE USING gist (
  organization_id WITH =,
  customer_id WITH =,
  (COALESCE(product_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
  price_agreement_window(valid_from, valid_until, ended_at) WITH &&
);
ALTER TABLE customer_price_agreements FORCE ROW LEVEL SECURITY;
REVOKE UPDATE, DELETE ON customer_price_agreements FROM locentra_app, locentra_worker;
GRANT UPDATE (ended_at, ended_by, end_reason) ON customer_price_agreements TO locentra_app;

CREATE FUNCTION customer_price_agreements_end_once() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.ended_at IS NOT NULL THEN
    RAISE EXCEPTION 'condição negociada já encerrada' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.ended_at IS NULL THEN
    RAISE EXCEPTION 'o encerramento exige data e motivo' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER customer_price_agreements_end_once BEFORE UPDATE ON customer_price_agreements
  FOR EACH ROW EXECUTE FUNCTION customer_price_agreements_end_once();

-- Catálogo de tarifas adicionais ----------------------------------------------------------------------------
CREATE TABLE additional_fees (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{1,29}$'),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 120),
  description text CHECK (description IS NULL OR length(description) BETWEEN 1 AND 500),
  default_amount_cents bigint NOT NULL CHECK (default_amount_cents > 0 AND default_amount_cents <= 999999999999),
  active boolean NOT NULL DEFAULT true,
  lock_version integer NOT NULL DEFAULT 1 CHECK (lock_version > 0),
  created_by uuid,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  deactivated_at timestamptz,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code)
);
CREATE INDEX additional_fees_org_active_idx ON additional_fees (organization_id, active, lower(name));
REVOKE UPDATE, DELETE ON additional_fees FROM locentra_app, locentra_worker;
GRANT UPDATE (name, description, default_amount_cents, active, lock_version, updated_at, deactivated_at) ON additional_fees TO locentra_app;

-- Snapshots de preço imutáveis ---------------------------------------------------------------------------
CREATE FUNCTION app_forbid_pricing_update() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF NEW.pricing IS DISTINCT FROM OLD.pricing THEN
    RAISE EXCEPTION 'o snapshot de preços não pode ser alterado' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER reservations_pricing_immutable BEFORE UPDATE OF pricing ON reservations
  FOR EACH ROW EXECUTE FUNCTION app_forbid_pricing_update();
CREATE TRIGGER reservation_items_pricing_immutable BEFORE UPDATE OF pricing ON reservation_items
  FOR EACH ROW EXECUTE FUNCTION app_forbid_pricing_update();

SELECT app_enable_tenant_rls('coupon_redemptions');
SELECT app_enable_tenant_rls('additional_fees');
