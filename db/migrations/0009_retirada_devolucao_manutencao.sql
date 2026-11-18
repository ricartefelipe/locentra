-- Retirada, devolução, inspeção, avarias, manutenção, transferências entre filiais e alertas de atraso.
--
-- Garantias no banco:
-- * Retirada única: no máximo uma retirada não cancelada por reserva e uma linha não cancelada por
--   alocação (índices únicos parciais). A aplicação também bloqueia a reserva e verifica o estado.
-- * Devolução: cada linha entregue acumula devolvido + faltante <= entregue (CHECK avaliado sob o lock
--   da linha); um ativo é devolvido uma única vez por entrega (índice único parcial em return_lines).
-- * Devoluções são somente inserção. Retiradas entregues, inspeções decididas, ordens de manutenção
--   encerradas, avarias decididas, transferências encerradas e alertas resolvidos não podem ser
--   alterados (gatilhos). Nenhuma linha destas tabelas é removida pela aplicação.
-- * Bloqueios de estoque por inspeção usam alocação kind 'block' com período [início, ∞).

-- Impede alteração de registros que atingiram um estado final (estados recebidos como argumentos).
CREATE FUNCTION app_guard_final_state() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status = ANY (TG_ARGV) THEN
    RAISE EXCEPTION 'registro encerrado em % não pode ser alterado', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Retirada: separação, conferência e entrega.
-- ---------------------------------------------------------------------------
CREATE TABLE pickups (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  reservation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'picking' CHECK (status IN ('picking', 'delivered', 'cancelled')),
  picker_kind text CHECK (picker_kind IN ('customer', 'contact')),
  contact_id uuid,
  picker_name text,
  picker_document text CHECK (picker_document IS NULL OR picker_document ~ '^[0-9]{11}$'),
  notes text,
  started_by uuid,
  started_at timestamptz NOT NULL,
  delivered_by uuid,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  version integer NOT NULL DEFAULT 1,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, contact_id) REFERENCES customer_contacts (organization_id, id),
  CHECK ((status = 'delivered') = (delivered_at IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  CHECK (status <> 'delivered' OR (picker_kind IS NOT NULL AND picker_name IS NOT NULL AND picker_document IS NOT NULL)),
  CHECK (picker_kind IS DISTINCT FROM 'contact' OR contact_id IS NOT NULL)
);
CREATE UNIQUE INDEX pickups_reservation_key ON pickups (organization_id, reservation_id) WHERE status <> 'cancelled';
CREATE INDEX pickups_status_idx ON pickups (organization_id, status, started_at DESC);

CREATE TABLE pickup_lines (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  pickup_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  reservation_item_id uuid NOT NULL,
  product_id uuid NOT NULL,
  asset_allocation_id uuid,
  stock_allocation_id uuid,
  asset_id uuid,
  stock_pool_id uuid,
  expected_quantity integer NOT NULL CHECK (expected_quantity > 0),
  checked_quantity integer NOT NULL DEFAULT 0,
  delivered_quantity integer NOT NULL DEFAULT 0,
  returned_quantity integer NOT NULL DEFAULT 0 CHECK (returned_quantity >= 0),
  missing_quantity integer NOT NULL DEFAULT 0 CHECK (missing_quantity >= 0),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'checked', 'delivered', 'partial', 'not_delivered', 'cancelled')),
  checked_by uuid,
  checked_at timestamptz,
  release_reason text,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, pickup_id) REFERENCES pickups (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_item_id) REFERENCES reservation_items (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, asset_allocation_id) REFERENCES asset_allocations (organization_id, id),
  FOREIGN KEY (organization_id, stock_allocation_id) REFERENCES stock_allocations (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  CHECK ((asset_allocation_id IS NULL) <> (stock_allocation_id IS NULL)),
  CHECK ((asset_allocation_id IS NULL) = (asset_id IS NULL)),
  CHECK ((stock_allocation_id IS NULL) = (stock_pool_id IS NULL)),
  CHECK (asset_id IS NULL OR expected_quantity = 1),
  CHECK (checked_quantity BETWEEN 0 AND expected_quantity),
  CHECK (delivered_quantity BETWEEN 0 AND expected_quantity),
  CHECK (returned_quantity + missing_quantity <= delivered_quantity)
);
-- Uma alocação só pode constar de uma retirada não cancelada (impede retirada duplicada).
CREATE UNIQUE INDEX pickup_lines_asset_allocation_key ON pickup_lines (organization_id, asset_allocation_id)
  WHERE asset_allocation_id IS NOT NULL AND status <> 'cancelled';
CREATE UNIQUE INDEX pickup_lines_stock_allocation_key ON pickup_lines (organization_id, stock_allocation_id)
  WHERE stock_allocation_id IS NOT NULL AND status <> 'cancelled';
CREATE INDEX pickup_lines_pickup_idx ON pickup_lines (organization_id, pickup_id);
CREATE INDEX pickup_lines_outstanding_idx ON pickup_lines (organization_id, reservation_id)
  WHERE status IN ('delivered', 'partial');

-- Após a entrega, somente os acumulados de devolução e falta podem mudar, e apenas para mais.
CREATE FUNCTION pickup_lines_guard() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF OLD.status IN ('delivered', 'partial', 'not_delivered', 'cancelled') AND
     (NEW.status, NEW.asset_id, NEW.stock_pool_id, NEW.asset_allocation_id, NEW.stock_allocation_id, NEW.checked_quantity,
      NEW.delivered_quantity, NEW.expected_quantity)
       IS DISTINCT FROM
     (OLD.status, OLD.asset_id, OLD.stock_pool_id, OLD.asset_allocation_id, OLD.stock_allocation_id, OLD.checked_quantity,
      OLD.delivered_quantity, OLD.expected_quantity) THEN
    RAISE EXCEPTION 'linha de retirada encerrada não pode ser alterada' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.returned_quantity < OLD.returned_quantity OR NEW.missing_quantity < OLD.missing_quantity THEN
    RAISE EXCEPTION 'acumulados de devolução não podem diminuir' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER pickup_lines_guard BEFORE UPDATE ON pickup_lines FOR EACH ROW EXECUTE FUNCTION pickup_lines_guard();
CREATE TRIGGER pickups_final_guard BEFORE UPDATE ON pickups FOR EACH ROW EXECUTE FUNCTION app_guard_final_state('delivered', 'cancelled');

-- ---------------------------------------------------------------------------
-- Devolução total ou parcial (registro histórico, somente inserção).
-- ---------------------------------------------------------------------------
CREATE TABLE returns (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  reservation_id uuid NOT NULL,
  pickup_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  returned_at timestamptz NOT NULL,
  received_by uuid,
  late_fee_cents bigint NOT NULL DEFAULT 0 CHECK (late_fee_cents >= 0),
  completes_reservation boolean NOT NULL DEFAULT false,
  notes text,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, pickup_id) REFERENCES pickups (organization_id, id),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id)
);
CREATE INDEX returns_reservation_idx ON returns (organization_id, reservation_id, returned_at);
-- Somente uma devolução conclui a reserva.
CREATE UNIQUE INDEX returns_completion_key ON returns (organization_id, reservation_id) WHERE completes_reservation;

CREATE TABLE return_lines (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  return_id uuid NOT NULL,
  pickup_line_id uuid NOT NULL,
  reservation_item_id uuid NOT NULL,
  product_id uuid NOT NULL,
  asset_id uuid,
  stock_pool_id uuid,
  outcome text NOT NULL CHECK (outcome IN ('ok', 'damaged', 'missing')),
  quantity integer NOT NULL CHECK (quantity > 0),
  requires_inspection boolean NOT NULL DEFAULT false,
  notes text,
  created_at timestamptz NOT NULL,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, return_id) REFERENCES returns (organization_id, id),
  FOREIGN KEY (organization_id, pickup_line_id) REFERENCES pickup_lines (organization_id, id),
  FOREIGN KEY (organization_id, reservation_item_id) REFERENCES reservation_items (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  CHECK ((asset_id IS NULL) <> (stock_pool_id IS NULL)),
  CHECK (asset_id IS NULL OR quantity = 1),
  CHECK (outcome <> 'damaged' OR requires_inspection),
  CHECK (outcome <> 'missing' OR NOT requires_inspection)
);
-- Um ativo entregue é devolvido (ou registrado como faltante) uma única vez.
CREATE UNIQUE INDEX return_lines_asset_once_key ON return_lines (organization_id, pickup_line_id) WHERE asset_id IS NOT NULL;
CREATE INDEX return_lines_return_idx ON return_lines (organization_id, return_id);

-- ---------------------------------------------------------------------------
-- Manutenção e inspeção.
-- ---------------------------------------------------------------------------
CREATE TABLE maintenance_orders (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL,
  product_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  asset_id uuid,
  stock_pool_id uuid,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  block_allocation_id uuid,
  inspection_id uuid,
  previous_status text,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'completed', 'cancelled')),
  description text NOT NULL CHECK (length(description) BETWEEN 3 AND 2000),
  cost_cents bigint CHECK (cost_cents IS NULL OR cost_cents >= 0),
  requires_inspection boolean,
  resolution_notes text,
  opened_by uuid,
  opened_at timestamptz NOT NULL,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  closed_by uuid,
  version integer NOT NULL DEFAULT 1,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  FOREIGN KEY (organization_id, block_allocation_id) REFERENCES stock_allocations (organization_id, id),
  CHECK ((asset_id IS NULL) <> (stock_pool_id IS NULL)),
  CHECK (asset_id IS NULL OR quantity = 1),
  CHECK (stock_pool_id IS NULL OR block_allocation_id IS NOT NULL),
  CHECK (status <> 'in_progress' OR started_at IS NOT NULL),
  CHECK (status <> 'completed' OR (completed_at IS NOT NULL AND cost_cents IS NOT NULL AND requires_inspection IS NOT NULL)),
  CHECK (status <> 'cancelled' OR (cancelled_at IS NOT NULL AND cancellation_reason IS NOT NULL))
);
-- No máximo uma ordem ativa por ativo.
CREATE UNIQUE INDEX maintenance_orders_active_asset_key ON maintenance_orders (organization_id, asset_id)
  WHERE asset_id IS NOT NULL AND status IN ('open', 'in_progress');
CREATE INDEX maintenance_orders_status_idx ON maintenance_orders (organization_id, status, opened_at DESC);
CREATE TRIGGER maintenance_orders_final_guard BEFORE UPDATE ON maintenance_orders
  FOR EACH ROW EXECUTE FUNCTION app_guard_final_state('completed', 'cancelled');

CREATE TABLE inspections (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  product_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  asset_id uuid,
  stock_pool_id uuid,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  block_allocation_id uuid,
  reservation_id uuid,
  return_line_id uuid,
  source_maintenance_order_id uuid,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  reason text NOT NULL,
  decision_notes text,
  maintenance_order_id uuid,
  created_at timestamptz NOT NULL,
  decided_by uuid,
  decided_at timestamptz,
  UNIQUE (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  FOREIGN KEY (organization_id, block_allocation_id) REFERENCES stock_allocations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, return_line_id) REFERENCES return_lines (organization_id, id),
  FOREIGN KEY (organization_id, source_maintenance_order_id) REFERENCES maintenance_orders (organization_id, id),
  FOREIGN KEY (organization_id, maintenance_order_id) REFERENCES maintenance_orders (organization_id, id),
  CHECK ((asset_id IS NULL) <> (stock_pool_id IS NULL)),
  CHECK (asset_id IS NULL OR quantity = 1),
  CHECK (stock_pool_id IS NULL OR block_allocation_id IS NOT NULL),
  CHECK ((status = 'pending') = (decided_at IS NULL)),
  CHECK (status <> 'rejected' OR maintenance_order_id IS NOT NULL)
);
-- No máximo uma inspeção pendente por ativo.
CREATE UNIQUE INDEX inspections_pending_asset_key ON inspections (organization_id, asset_id) WHERE asset_id IS NOT NULL AND status = 'pending';
CREATE INDEX inspections_status_idx ON inspections (organization_id, status, created_at);
CREATE TRIGGER inspections_final_guard BEFORE UPDATE ON inspections
  FOR EACH ROW EXECUTE FUNCTION app_guard_final_state('approved', 'rejected');

ALTER TABLE maintenance_orders
  ADD FOREIGN KEY (organization_id, inspection_id) REFERENCES inspections (organization_id, id);

-- ---------------------------------------------------------------------------
-- Avarias e faltas: cobrança somente após aprovação, com evidência anexada.
-- ---------------------------------------------------------------------------
CREATE TABLE damage_reports (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL,
  reservation_id uuid NOT NULL,
  reservation_item_id uuid NOT NULL,
  return_line_id uuid NOT NULL,
  product_id uuid NOT NULL,
  asset_id uuid,
  stock_pool_id uuid,
  quantity integer NOT NULL CHECK (quantity > 0),
  kind text NOT NULL CHECK (kind IN ('damage', 'missing')),
  severity text NOT NULL CHECK (severity IN ('minor', 'moderate', 'severe', 'total_loss')),
  description text NOT NULL CHECK (length(description) BETWEEN 3 AND 2000),
  estimated_cost_cents bigint NOT NULL DEFAULT 0 CHECK (estimated_cost_cents >= 0),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'dismissed')),
  charged_cents bigint CHECK (charged_cents IS NULL OR charged_cents > 0),
  adjustment_id uuid,
  decision_notes text,
  decided_by uuid,
  decided_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version integer NOT NULL DEFAULT 1,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, reservation_item_id) REFERENCES reservation_items (organization_id, id),
  FOREIGN KEY (organization_id, return_line_id) REFERENCES return_lines (organization_id, id),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  FOREIGN KEY (organization_id, adjustment_id) REFERENCES reservation_adjustments (organization_id, id),
  CHECK ((asset_id IS NULL) <> (stock_pool_id IS NULL)),
  CHECK ((status = 'approved') = (adjustment_id IS NOT NULL AND charged_cents IS NOT NULL)),
  CHECK ((status = 'open') = (decided_at IS NULL))
);
-- Uma cobrança ativa por item devolvido: impede cobrança duplicada da mesma avaria ou falta.
CREATE UNIQUE INDEX damage_reports_return_line_key ON damage_reports (organization_id, return_line_id) WHERE status <> 'dismissed';
CREATE INDEX damage_reports_status_idx ON damage_reports (organization_id, status, created_at DESC);
CREATE TRIGGER damage_reports_final_guard BEFORE UPDATE ON damage_reports
  FOR EACH ROW EXECUTE FUNCTION app_guard_final_state('approved', 'dismissed');

-- ---------------------------------------------------------------------------
-- Transferências entre filiais: requested -> in_transit -> received (cancelável antes da saída).
-- ---------------------------------------------------------------------------
CREATE TABLE transfers (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  code text NOT NULL,
  product_id uuid NOT NULL,
  asset_id uuid,
  quantity integer NOT NULL CHECK (quantity > 0),
  from_branch_id uuid NOT NULL,
  to_branch_id uuid NOT NULL,
  from_pool_id uuid,
  to_pool_id uuid,
  status text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'in_transit', 'received', 'cancelled')),
  notes text,
  requested_by uuid,
  requested_at timestamptz NOT NULL,
  dispatched_by uuid,
  dispatched_at timestamptz,
  received_by uuid,
  received_at timestamptz,
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancellation_reason text,
  version integer NOT NULL DEFAULT 1,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, code),
  FOREIGN KEY (organization_id, product_id) REFERENCES products (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, from_branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, to_branch_id) REFERENCES branches (organization_id, id),
  FOREIGN KEY (organization_id, from_pool_id) REFERENCES stock_pools (organization_id, id),
  FOREIGN KEY (organization_id, to_pool_id) REFERENCES stock_pools (organization_id, id),
  CHECK (from_branch_id <> to_branch_id),
  CHECK (asset_id IS NULL OR quantity = 1),
  CHECK ((asset_id IS NULL) = (from_pool_id IS NOT NULL)),
  CHECK (status NOT IN ('in_transit', 'received') OR dispatched_at IS NOT NULL),
  CHECK ((status = 'received') = (received_at IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL))
);
-- Um ativo participa de no máximo uma transferência ativa (sem duplicidade entre filiais).
CREATE UNIQUE INDEX transfers_active_asset_key ON transfers (organization_id, asset_id)
  WHERE asset_id IS NOT NULL AND status IN ('requested', 'in_transit');
CREATE INDEX transfers_status_idx ON transfers (organization_id, status, requested_at DESC);
CREATE TRIGGER transfers_final_guard BEFORE UPDATE ON transfers
  FOR EACH ROW EXECUTE FUNCTION app_guard_final_state('received', 'cancelled');

-- ---------------------------------------------------------------------------
-- Alertas operacionais: atraso, reserva futura afetada e item indisponível.
-- ---------------------------------------------------------------------------
CREATE TABLE reservation_alerts (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  reservation_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('overdue', 'affected_by_overdue', 'asset_unavailable')),
  related_reservation_id uuid,
  asset_id uuid,
  stock_pool_id uuid,
  dedup_key text NOT NULL CHECK (length(dedup_key) BETWEEN 3 AND 300),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  details jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution text,
  UNIQUE (organization_id, id),
  UNIQUE (organization_id, dedup_key),
  FOREIGN KEY (organization_id, reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, related_reservation_id) REFERENCES reservations (organization_id, id),
  FOREIGN KEY (organization_id, asset_id) REFERENCES assets (organization_id, id),
  FOREIGN KEY (organization_id, stock_pool_id) REFERENCES stock_pools (organization_id, id),
  CHECK (kind <> 'affected_by_overdue' OR related_reservation_id IS NOT NULL),
  CHECK ((status = 'resolved') = (resolved_at IS NOT NULL AND resolution IS NOT NULL))
);
CREATE INDEX reservation_alerts_open_idx ON reservation_alerts (organization_id, created_at DESC) WHERE status = 'open';
CREATE INDEX reservation_alerts_reservation_idx ON reservation_alerts (organization_id, reservation_id);
CREATE INDEX reservation_alerts_related_idx ON reservation_alerts (organization_id, related_reservation_id) WHERE related_reservation_id IS NOT NULL;
CREATE TRIGGER reservation_alerts_final_guard BEFORE UPDATE ON reservation_alerts
  FOR EACH ROW EXECUTE FUNCTION app_guard_final_state('resolved');

-- ---------------------------------------------------------------------------
-- Alocação de ativo × mudança de situação.
-- ---------------------------------------------------------------------------
-- O motor de disponibilidade escolhe a unidade lendo a situação do ativo sem lock. Ao gravar uma
-- alocação de reserva (inclusão ou troca de unidade), este gatilho relê o ativo com FOR SHARE, que
-- conflita com o FOR UPDATE de quem muda a situação (saída de transferência, manutenção, falta na
-- devolução, mudança manual): a gravação espera o commit e recusa o ativo que ficou indisponível no
-- período. Na ordem inversa, quem muda a situação espera a alocação e passa a enxergá-la. A regra
-- espelha Domain::Availability::AssetSchedule#free?. O código exclusion_violation faz a aplicação
-- tratar a recusa como unidade ocupada e tentar o próximo candidato.
CREATE FUNCTION asset_allocations_status_guard() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
DECLARE
  current_status text;
  blocked_until timestamptz;
BEGIN
  SELECT status, unavailable_until INTO current_status, blocked_until
    FROM assets WHERE organization_id = NEW.organization_id AND id = NEW.asset_id
     FOR SHARE;
  IF current_status IN ('lost', 'retired')
     OR (current_status IN ('in_inspection', 'in_maintenance', 'in_transit')
         AND (blocked_until IS NULL OR lower(NEW.period) < blocked_until)) THEN
    RAISE EXCEPTION 'ativo indisponível para alocação (%)', current_status USING ERRCODE = 'exclusion_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER asset_allocations_status_guard BEFORE INSERT OR UPDATE OF asset_id ON asset_allocations
  FOR EACH ROW WHEN (NEW.active AND NEW.kind = 'reservation') EXECUTE FUNCTION asset_allocations_status_guard();

-- ---------------------------------------------------------------------------
-- Privilégios e Row-Level Security.
-- ---------------------------------------------------------------------------
REVOKE UPDATE, DELETE ON returns, return_lines FROM locentra_app, locentra_worker;
REVOKE DELETE ON pickups, pickup_lines, maintenance_orders, inspections, damage_reports, transfers, reservation_alerts
  FROM locentra_app, locentra_worker;

SELECT app_enable_tenant_rls('pickups');
SELECT app_enable_tenant_rls('pickup_lines');
SELECT app_enable_tenant_rls('returns');
SELECT app_enable_tenant_rls('return_lines');
SELECT app_enable_tenant_rls('maintenance_orders');
SELECT app_enable_tenant_rls('inspections');
SELECT app_enable_tenant_rls('damage_reports');
SELECT app_enable_tenant_rls('transfers');
SELECT app_enable_tenant_rls('reservation_alerts');
