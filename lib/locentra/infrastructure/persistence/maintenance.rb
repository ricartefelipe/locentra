# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class InspectionRepository
        M = Domain::Maintenance
        COLUMNS = "id, organization_id, product_id, branch_id, asset_id, stock_pool_id, quantity, block_allocation_id, reservation_id, " \
                  "return_line_id, source_maintenance_order_id, status, reason, decision_notes, maintenance_order_id, created_at, decided_at"
        STATUSES = { "pending" => "i.status = 'pending'", "decided" => "i.status <> 'pending'" }.freeze

        def insert(tx, inspection)
          tx.execute(<<~SQL, [inspection.id, tx.tenant_id!, inspection.product_id, inspection.branch_id, inspection.asset_id, inspection.stock_pool_id, inspection.quantity, inspection.block_allocation_id, inspection.reservation_id, inspection.return_line_id, inspection.source_maintenance_order_id, inspection.reason, inspection.created_at])
            INSERT INTO inspections (id, organization_id, product_id, branch_id, asset_id, stock_pool_id, quantity, block_allocation_id, reservation_id,
                                     return_line_id, source_maintenance_order_id, reason, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
          SQL
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM inspections WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM inspections WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && map(row)
        end

        def update(tx, inspection, actor_id)
          count = tx.execute(<<~SQL, [tx.tenant_id!, inspection.id, inspection.status, inspection.decision_notes, inspection.maintenance_order_id, actor_id, inspection.decided_at])
            UPDATE inspections SET status = $3, decision_notes = $4, maintenance_order_id = $5, decided_by = $6, decided_at = $7
             WHERE organization_id = $1 AND id = $2 AND status = 'pending'
          SQL
          raise Domain::Conflict.new("inspeção já decidida por outra operação", code: "stale_inspection") unless count == 1
        end

        def list(tx, status: "pending", limit: 100, offset: 0)
          tx.query(<<~SQL, [tx.tenant_id!, limit, offset])
            SELECT i.id, i.status, i.reason, i.quantity, i.created_at, i.decided_at, i.decision_notes, i.asset_id, i.stock_pool_id,
                   i.return_line_id, i.maintenance_order_id, i.reservation_id, i.product_id, i.branch_id, p.name AS product_name, p.sku, a.tag,
                   b.code AS branch_code, r.code AS reservation_code, m.code AS maintenance_code
              FROM inspections i
              JOIN products p ON p.organization_id = i.organization_id AND p.id = i.product_id
              JOIN branches b ON b.organization_id = i.organization_id AND b.id = i.branch_id
              LEFT JOIN assets a ON a.organization_id = i.organization_id AND a.id = i.asset_id
              LEFT JOIN reservations r ON r.organization_id = i.organization_id AND r.id = i.reservation_id
              LEFT JOIN maintenance_orders m ON m.organization_id = i.organization_id AND m.id = i.maintenance_order_id
             WHERE i.organization_id = $1 AND #{STATUSES.fetch(status)}
             ORDER BY COALESCE(i.decided_at, i.created_at) DESC, i.id LIMIT $2 OFFSET $3
          SQL
        end

        def count(tx, status:)
          tx.query_value("SELECT count(*) FROM inspections i WHERE i.organization_id = $1 AND #{STATUSES.fetch(status)}", [tx.tenant_id!])
        end

        private

        def map(row)
          M::Inspection.new(**row.transform_keys(&:to_sym), created_at: row["created_at"].utc, decided_at: row["decided_at"]&.utc)
        end
      end

      class MaintenanceOrderRepository
        M = Domain::Maintenance
        COLUMNS = "id, organization_id, code, product_id, branch_id, asset_id, stock_pool_id, quantity, block_allocation_id, inspection_id, " \
                  "previous_status, status, description, cost_cents, requires_inspection, resolution_notes, opened_at, started_at, " \
                  "completed_at, cancelled_at, cancellation_reason, version"
        FILTERS = { "active" => "m.status IN ('open', 'in_progress')", "closed" => "m.status IN ('completed', 'cancelled')", "all" => "TRUE" }.freeze

        def insert(tx, order, actor_id)
          tx.execute(<<~SQL, [order.id, tx.tenant_id!, order.code, order.product_id, order.branch_id, order.asset_id, order.stock_pool_id, order.quantity, order.block_allocation_id, order.inspection_id, order.previous_status, order.description, actor_id, order.opened_at])
            INSERT INTO maintenance_orders (id, organization_id, code, product_id, branch_id, asset_id, stock_pool_id, quantity, block_allocation_id,
                                            inspection_id, previous_status, description, opened_by, opened_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
          SQL
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM maintenance_orders WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM maintenance_orders WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && map(row)
        end

        def update(tx, order, actor_id)
          closing = %w[completed cancelled].include?(order.status) ? actor_id : nil
          count = tx.execute(<<~SQL, [tx.tenant_id!, order.id, order.status, order.cost&.cents, order.requires_inspection, order.resolution_notes, order.started_at, order.completed_at, order.cancelled_at, order.cancellation_reason, closing, order.version])
            UPDATE maintenance_orders
               SET status = $3, cost_cents = $4, requires_inspection = $5, resolution_notes = $6, started_at = $7, completed_at = $8,
                   cancelled_at = $9, cancellation_reason = $10, closed_by = COALESCE($11, closed_by), version = $12
             WHERE organization_id = $1 AND id = $2 AND version = $12 - 1
          SQL
          raise Domain::Conflict.new("ordem de manutenção alterada por outra operação", code: "stale_maintenance_order") unless count == 1
        end

        def list(tx, filter: "active", limit: 100)
          tx.query(<<~SQL, [tx.tenant_id!, limit])
            SELECT m.id, m.code, m.status, m.description, m.quantity, m.cost_cents, m.opened_at, m.started_at, m.completed_at, m.cancelled_at,
                   m.asset_id, m.stock_pool_id, p.name AS product_name, p.sku, a.tag, b.code AS branch_code
              FROM maintenance_orders m
              JOIN products p ON p.organization_id = m.organization_id AND p.id = m.product_id
              JOIN branches b ON b.organization_id = m.organization_id AND b.id = m.branch_id
              LEFT JOIN assets a ON a.organization_id = m.organization_id AND a.id = m.asset_id
             WHERE m.organization_id = $1 AND #{FILTERS.fetch(filter)}
             ORDER BY m.opened_at DESC, m.id LIMIT $2
          SQL
        end

        def labels(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT p.name AS product_name, p.sku, a.tag, b.name AS branch_name, b.code AS branch_code, i.id AS inspection_id
              FROM maintenance_orders m
              JOIN products p ON p.organization_id = m.organization_id AND p.id = m.product_id
              JOIN branches b ON b.organization_id = m.organization_id AND b.id = m.branch_id
              LEFT JOIN assets a ON a.organization_id = m.organization_id AND a.id = m.asset_id
              LEFT JOIN inspections i ON i.organization_id = m.organization_id AND i.source_maintenance_order_id = m.id AND i.status = 'pending'
             WHERE m.organization_id = $1 AND m.id = $2
          SQL
        end

        private

        def map(row)
          attrs = row.except("cost_cents").transform_keys(&:to_sym)
          M::Order.new(**attrs, cost: row["cost_cents"] && Domain::Money.new(row["cost_cents"]), opened_at: row["opened_at"].utc)
        end
      end

      class DamageReportRepository
        M = Domain::Maintenance
        COLUMNS = "id, organization_id, code, reservation_id, reservation_item_id, return_line_id, product_id, asset_id, stock_pool_id, quantity, " \
                  "kind, severity, description, estimated_cost_cents, status, charged_cents, adjustment_id, decision_notes, version"
        FILTERS = { "open" => "d.status = 'open'", "decided" => "d.status <> 'open'", "all" => "TRUE" }.freeze

        def insert(tx, report, actor_id, now)
          tx.execute(<<~SQL, [report.id, tx.tenant_id!, report.code, report.reservation_id, report.reservation_item_id, report.return_line_id, report.product_id, report.asset_id, report.stock_pool_id, report.quantity, report.kind, report.severity, report.description, report.estimated_cost.cents, actor_id, now])
            INSERT INTO damage_reports (id, organization_id, code, reservation_id, reservation_item_id, return_line_id, product_id, asset_id,
                                        stock_pool_id, quantity, kind, severity, description, estimated_cost_cents, created_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $16)
          SQL
        rescue Domain::Conflict => e
          raise unless e.code.include?("damage_reports_return_line_key")

          raise Domain::Conflict.new("já existe registro de avaria ou falta para este item", code: "duplicate_damage_report")
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM damage_reports WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM damage_reports WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && map(row)
        end

        def update(tx, report, actor_id, now)
          decided = report.open? ? nil : now
          count = tx.execute(<<~SQL, [tx.tenant_id!, report.id, report.status, report.severity, report.description, report.estimated_cost.cents, report.charged&.cents, report.adjustment_id, report.decision_notes, decided && actor_id, decided, now, report.version])
            UPDATE damage_reports
               SET status = $3, severity = $4, description = $5, estimated_cost_cents = $6, charged_cents = $7, adjustment_id = $8,
                   decision_notes = $9, decided_by = $10, decided_at = $11, updated_at = $12, version = $13
             WHERE organization_id = $1 AND id = $2 AND version = $13 - 1
          SQL
          raise Domain::Conflict.new("registro de avaria alterado por outra operação", code: "stale_damage_report") unless count == 1
        end

        # Evidências vivas contadas sob FOR SHARE: uma remoção que ainda não terminou é aguardada e
        # deixa de ser contada; nenhuma remoção é gravada até o fim da decisão.
        def lock_evidence_count(tx, id)
          tx.query(<<~SQL, [tx.tenant_id!, id]).size
            SELECT id FROM attachments WHERE organization_id = $1 AND owner_type = 'damage_report' AND owner_id = $2 AND deleted_at IS NULL
               FOR SHARE
          SQL
        end

        def list(tx, filter: "open", limit: 100, reservation_id: nil)
          tx.query(<<~SQL, [tx.tenant_id!, limit, reservation_id])
            SELECT d.id, d.code, d.kind, d.severity, d.status, d.quantity, d.estimated_cost_cents, d.charged_cents, d.created_at, d.decided_at,
                   d.reservation_id, r.code AS reservation_code, p.name AS product_name, p.sku, a.tag
              FROM damage_reports d
              JOIN reservations r ON r.organization_id = d.organization_id AND r.id = d.reservation_id
              JOIN products p ON p.organization_id = d.organization_id AND p.id = d.product_id
              LEFT JOIN assets a ON a.organization_id = d.organization_id AND a.id = d.asset_id
             WHERE d.organization_id = $1 AND #{FILTERS.fetch(filter)} AND ($3::uuid IS NULL OR d.reservation_id = $3::uuid)
             ORDER BY d.created_at DESC, d.id LIMIT $2
          SQL
        end

        def labels(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT r.code AS reservation_code, p.name AS product_name, p.sku, p.replacement_cost_cents, a.tag, t.returned_at, l.return_id,
                   u.name AS decided_by_name, d.decided_at
              FROM damage_reports d
              JOIN reservations r ON r.organization_id = d.organization_id AND r.id = d.reservation_id
              JOIN products p ON p.organization_id = d.organization_id AND p.id = d.product_id
              JOIN return_lines l ON l.organization_id = d.organization_id AND l.id = d.return_line_id
              JOIN returns t ON t.organization_id = l.organization_id AND t.id = l.return_id
              LEFT JOIN assets a ON a.organization_id = d.organization_id AND a.id = d.asset_id
              LEFT JOIN users u ON u.id = d.decided_by
             WHERE d.organization_id = $1 AND d.id = $2
          SQL
        end

        private

        def map(row)
          M::DamageReport.new(**row.except("estimated_cost_cents", "charged_cents").transform_keys(&:to_sym),
                              estimated_cost: Domain::Money.new(row["estimated_cost_cents"]),
                              charged: row["charged_cents"] && Domain::Money.new(row["charged_cents"]))
        end
      end
    end
  end
end
