# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Retiradas e devoluções. Os acumulados de devolução das linhas são gravados sob lock de linha e
      # o CHECK do banco impede acumulado acima do entregue; devoluções são somente inserção.
      class FulfillmentRepository
        F = Domain::Fulfillment
        PICKUP_COLUMNS = "id, organization_id, reservation_id, branch_id, status, picker_kind, contact_id, picker_name, picker_document, " \
                         "notes, started_at, delivered_at, cancelled_at, version"
        LINE_COLUMNS = "id, pickup_id, reservation_id, reservation_item_id, product_id, asset_allocation_id, stock_allocation_id, asset_id, " \
                       "stock_pool_id, expected_quantity, checked_quantity, delivered_quantity, returned_quantity, missing_quantity, status"
        PICKUP_FILTERS = {
          id: "id = $2", open: "reservation_id = $2 AND status = 'picking'", delivered: "reservation_id = $2 AND status = 'delivered'"
        }.freeze

        def insert_pickup(tx, pickup, actor_id)
          tx.execute(<<~SQL, [pickup.id, tx.tenant_id!, pickup.reservation_id, pickup.branch_id, pickup.status, actor_id, pickup.started_at])
            INSERT INTO pickups (id, organization_id, reservation_id, branch_id, status, started_by, started_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
          SQL
        end

        def find_pickup(tx, id) = pickup_where(tx, :id, id)
        def lock_pickup(tx, id) = pickup_where(tx, :id, id, lock: true)
        def open_pickup_for(tx, reservation_id) = pickup_where(tx, :open, reservation_id)
        def delivered_pickup_for(tx, reservation_id) = pickup_where(tx, :delivered, reservation_id)

        def pickups_for(tx, reservation_id)
          tx.query("SELECT #{PICKUP_COLUMNS} FROM pickups WHERE organization_id = $1 AND reservation_id = $2 ORDER BY started_at DESC",
                   [tx.tenant_id!, reservation_id]).map { |row| map_pickup(row) }
        end

        # Atualização com controle otimista de versão, além do lock de linha.
        def update_pickup(tx, pickup, actor_id)
          picker = pickup.picker
          delivered_by = pickup.delivered? ? actor_id : nil
          count = tx.execute(<<~SQL, [tx.tenant_id!, pickup.id, pickup.status, picker&.kind, picker&.contact_id, picker&.name, picker&.document, pickup.notes, delivered_by, pickup.delivered_at, pickup.cancelled_at, pickup.version])
            UPDATE pickups SET status = $3, picker_kind = $4, contact_id = $5, picker_name = $6, picker_document = $7, notes = $8,
                               delivered_by = $9, delivered_at = $10, cancelled_at = $11, version = $12
             WHERE organization_id = $1 AND id = $2 AND version = $12 - 1
          SQL
          raise Domain::Conflict.new("retirada alterada por outra operação", code: "stale_pickup") unless count == 1
        end

        def insert_pickup_line(tx, line)
          tx.execute(<<~SQL, [line.id, tx.tenant_id!, line.pickup_id, line.reservation_id, line.reservation_item_id, line.product_id, line.asset_allocation_id, line.stock_allocation_id, line.asset_id, line.stock_pool_id, line.expected_quantity])
            INSERT INTO pickup_lines (id, organization_id, pickup_id, reservation_id, reservation_item_id, product_id, asset_allocation_id,
                                      stock_allocation_id, asset_id, stock_pool_id, expected_quantity)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          SQL
        end

        def pickup_lines(tx, pickup_id, lock: false)
          sql = "SELECT #{LINE_COLUMNS} FROM pickup_lines WHERE organization_id = $1 AND pickup_id = $2 ORDER BY id"
          tx.query(lock ? "#{sql} FOR UPDATE" : sql, [tx.tenant_id!, pickup_id]).map { |row| map_line(row) }
        end

        def update_pickup_line(tx, line, checked_by: nil, checked_at: nil, release_reason: nil)
          tx.execute(<<~SQL, [tx.tenant_id!, line.id, line.status, line.asset_id, line.checked_quantity, line.delivered_quantity, checked_by, checked_at, release_reason])
            UPDATE pickup_lines SET status = $3, asset_id = $4, checked_quantity = $5, delivered_quantity = $6,
                   checked_by = COALESCE($7, checked_by), checked_at = COALESCE($8, checked_at), release_reason = COALESCE($9, release_reason)
             WHERE organization_id = $1 AND id = $2
          SQL
        end

        def update_line_counters(tx, line)
          tx.execute("UPDATE pickup_lines SET returned_quantity = $3, missing_quantity = $4 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, line.id, line.returned_quantity, line.missing_quantity])
        end

        # Linhas com dados de exibição: produto, patrimônio da linha e patrimônio atualmente alocado.
        def line_details(tx, pickup_id)
          tx.query(<<~SQL, [tx.tenant_id!, pickup_id])
            SELECT l.id, l.status, l.product_id, l.asset_id, l.stock_pool_id, l.expected_quantity, l.checked_quantity, l.delivered_quantity,
                   l.returned_quantity, l.missing_quantity, l.release_reason, l.reservation_item_id, p.name AS product_name, p.sku,
                   a.tag, a.status AS asset_status, aa.asset_id AS allocated_asset_id, aa.active AS allocation_active, x.tag AS allocated_tag
              FROM pickup_lines l
              JOIN products p ON p.organization_id = l.organization_id AND p.id = l.product_id
              LEFT JOIN assets a ON a.organization_id = l.organization_id AND a.id = l.asset_id
              LEFT JOIN asset_allocations aa ON aa.organization_id = l.organization_id AND aa.id = l.asset_allocation_id
              LEFT JOIN assets x ON x.organization_id = aa.organization_id AND x.id = aa.asset_id
             WHERE l.organization_id = $1 AND l.pickup_id = $2
             ORDER BY p.name, a.tag NULLS LAST, l.id
          SQL
        end

        def insert_return(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("reservation_id", "pickup_id", "branch_id", "returned_at", "received_by", "late_fee_cents", "completes_reservation", "notes", "created_at")])
            INSERT INTO returns (id, organization_id, reservation_id, pickup_id, branch_id, returned_at, received_by, late_fee_cents,
                                 completes_reservation, notes, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          SQL
        end

        def insert_return_line(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("return_id", "pickup_line_id", "reservation_item_id", "product_id", "asset_id", "stock_pool_id", "outcome", "quantity", "requires_inspection", "notes", "created_at")])
            INSERT INTO return_lines (id, organization_id, return_id, pickup_line_id, reservation_item_id, product_id, asset_id, stock_pool_id,
                                      outcome, quantity, requires_inspection, notes, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
          SQL
        end

        def find_return(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT t.id, t.reservation_id, t.pickup_id, t.returned_at, t.late_fee_cents, t.completes_reservation, t.notes, r.code AS reservation_code,
                   u.name AS received_by_name
              FROM returns t JOIN reservations r ON r.organization_id = t.organization_id AND r.id = t.reservation_id
              LEFT JOIN users u ON u.id = t.received_by
             WHERE t.organization_id = $1 AND t.id = $2
          SQL
        end

        def return_lines(tx, return_id)
          tx.query(<<~SQL, [tx.tenant_id!, return_id])
            SELECT l.id, l.pickup_line_id, l.outcome, l.quantity, l.requires_inspection, l.notes, l.asset_id, l.stock_pool_id,
                   p.name AS product_name, p.sku, a.tag, d.id AS damage_report_id, d.code AS damage_report_code
              FROM return_lines l
              JOIN products p ON p.organization_id = l.organization_id AND p.id = l.product_id
              LEFT JOIN assets a ON a.organization_id = l.organization_id AND a.id = l.asset_id
              LEFT JOIN damage_reports d ON d.organization_id = l.organization_id AND d.return_line_id = l.id AND d.status <> 'dismissed'
             WHERE l.organization_id = $1 AND l.return_id = $2
             ORDER BY p.name, a.tag NULLS LAST, l.id
          SQL
        end

        def returns_for(tx, reservation_id)
          tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT t.id, t.returned_at, t.late_fee_cents, t.completes_reservation,
                   (SELECT count(*) FROM return_lines l WHERE l.organization_id = t.organization_id AND l.return_id = t.id) AS lines
              FROM returns t WHERE t.organization_id = $1 AND t.reservation_id = $2 ORDER BY t.returned_at, t.id
          SQL
        end

        def find_return_line(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT l.id, l.return_id, l.pickup_line_id, l.reservation_item_id, l.product_id, l.asset_id, l.stock_pool_id, l.outcome, l.quantity,
                   t.reservation_id
              FROM return_lines l JOIN returns t ON t.organization_id = l.organization_id AND t.id = l.return_id
             WHERE l.organization_id = $1 AND l.id = $2
          SQL
        end

        private

        def pickup_where(tx, filter, value, lock: false)
          sql = "SELECT #{PICKUP_COLUMNS} FROM pickups WHERE organization_id = $1 AND #{PICKUP_FILTERS.fetch(filter)}"
          row = tx.query_one(lock ? "#{sql} FOR UPDATE" : sql, [tx.tenant_id!, value])
          row && map_pickup(row)
        end

        def map_pickup(row)
          picker = if row["picker_kind"]
                     F::Picker.new(kind: row["picker_kind"], contact_id: row["contact_id"], name: row["picker_name"],
                                   document: row["picker_document"])
                   end
          F::Pickup.new(id: row["id"], organization_id: row["organization_id"], reservation_id: row["reservation_id"], branch_id: row["branch_id"],
                        status: row["status"], picker: picker, notes: row["notes"], started_at: row["started_at"]&.utc,
                        delivered_at: row["delivered_at"]&.utc, cancelled_at: row["cancelled_at"]&.utc, version: row["version"])
        end

        def map_line(row)
          F::PickupLine.new(**row.transform_keys(&:to_sym))
        end
      end

      # Ajustes de alocação feitos pela operação: liberação na devolução, redução de quantidade,
      # bloqueios de estoque em aberto ([início, ∞)) para inspeção e manutenção, e consultas de
      # ocupação futura com a reserva de origem.
      class OperationalAllocationRepository
        LIVE = "(r.id IS NULL OR r.status <> 'held' OR r.hold_expires_at > $%<now>d)"

        def lock_asset_allocation(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT id, asset_id, product_id, reservation_id, active, lower(period) AS starts_at, upper(period) AS ends_at
              FROM asset_allocations WHERE organization_id = $1 AND id = $2 FOR UPDATE
          SQL
        end

        def lock_stock_allocation(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT id, stock_pool_id, product_id, reservation_id, quantity, active, reason, lower(period) AS starts_at, upper(period) AS ends_at
              FROM stock_allocations WHERE organization_id = $1 AND id = $2 FOR UPDATE
          SQL
        end

        def release_asset_allocation(tx, id, now)
          tx.execute("UPDATE asset_allocations SET active = false, released_at = $3 WHERE organization_id = $1 AND id = $2 AND active",
                     [tx.tenant_id!, id, now])
        end

        def release_stock_allocation(tx, id, now)
          tx.execute("UPDATE stock_allocations SET active = false, released_at = $3 WHERE organization_id = $1 AND id = $2 AND active",
                     [tx.tenant_id!, id, now])
        end

        def set_stock_quantity(tx, id, quantity)
          tx.execute("UPDATE stock_allocations SET quantity = $3 WHERE organization_id = $1 AND id = $2 AND active", [tx.tenant_id!, id, quantity])
        end

        # Retirada antes da janela alocada: a alocação passa a começar no instante da entrega.
        def advance_asset_allocation(tx, id, starts_at)
          tx.execute(<<~SQL, [tx.tenant_id!, id, starts_at])
            UPDATE asset_allocations SET period = tstzrange($3::timestamptz, upper(period), '[)')
             WHERE organization_id = $1 AND id = $2 AND active AND lower(period) > $3::timestamptz
          SQL
        end

        def advance_stock_allocation(tx, id, starts_at)
          tx.execute(<<~SQL, [tx.tenant_id!, id, starts_at])
            UPDATE stock_allocations SET period = tstzrange($3::timestamptz, upper(period), '[)')
             WHERE organization_id = $1 AND id = $2 AND active AND lower(period) > $3::timestamptz
          SQL
        end

        # Bloqueio de estoque sem fim definido, encerrado somente na liberação.
        def insert_open_stock_block(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("stock_pool_id", "product_id", "reason", "quantity", "starts_at", "created_by", "created_at")])
            INSERT INTO stock_allocations (id, organization_id, stock_pool_id, product_id, kind, reason, quantity, period, created_by, created_at)
            VALUES ($1, $2, $3, $4, 'block', $5, $6, tstzrange($7::timestamptz, NULL, '[)'), $8, $9)
          SQL
        end

        # Encerra o bloqueio ajustando o fim do período para o instante da liberação.
        def end_stock_block(tx, id, now)
          tx.execute(<<~SQL, [tx.tenant_id!, id, now])
            UPDATE stock_allocations
               SET period = tstzrange(lower(period), GREATEST($3::timestamptz, lower(period) + interval '1 second'), '[)'),
                   active = false, released_at = $3
             WHERE organization_id = $1 AND id = $2 AND kind = 'block' AND active
          SQL
        end

        def rename_block(tx, id, reason)
          tx.execute("UPDATE stock_allocations SET reason = $3 WHERE organization_id = $1 AND id = $2 AND kind = 'block'",
                     [tx.tenant_id!, id, reason])
        end

        # Ocupações de um estoque recortadas à janela, com a reserva de origem e sua situação.
        def pool_occupancies(tx, pool_id, window, now)
          tx.query(<<~SQL, [tx.tenant_id!, pool_id, window, now]).map { |row| occupancy(row) }
            SELECT s.reservation_id, r.status AS reservation_status, lower(s.period * $3::tstzrange) AS starts_at,
                   upper(s.period * $3::tstzrange) AS ends_at, s.quantity
              FROM stock_allocations s LEFT JOIN reservations r ON r.organization_id = s.organization_id AND r.id = s.reservation_id
             WHERE s.organization_id = $1 AND s.stock_pool_id = $2 AND s.active AND s.period && $3::tstzrange
               AND #{format(LIVE, now: 4)}
          SQL
        end

        # Alocações ativas de reservas ainda não retiradas que usam o ativo após `now`.
        def future_reservations_for_asset(tx, asset_id, now, exclude_reservation_id: nil)
          tx.query(<<~SQL, [tx.tenant_id!, asset_id, now, exclude_reservation_id])
            SELECT a.id, a.reservation_id, r.code AS reservation_code, lower(a.period) AS starts_at, upper(a.period) AS ends_at
              FROM asset_allocations a JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND a.asset_id = $2 AND a.active AND upper(a.period) > $3
               AND (r.status = 'confirmed' OR (r.status = 'held' AND r.hold_expires_at > $3))
               AND ($4::uuid IS NULL OR r.id <> $4::uuid)
             ORDER BY lower(a.period)
          SQL
        end

        # Qualquer alocação ativa (reserva ou bloqueio) do ativo que termina após `now`.
        def active_future_allocations(tx, asset_id, now)
          tx.query(<<~SQL, [tx.tenant_id!, asset_id, now])
            SELECT a.id, a.kind, COALESCE(r.code, 'bloqueio') AS label, lower(a.period) AS starts_at
              FROM asset_allocations a LEFT JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND a.asset_id = $2 AND a.active AND upper(a.period) > $3
               AND #{format(LIVE, now: 3)}
             ORDER BY lower(a.period)
          SQL
        end

        # Lock de vários estoques em ordem de id, a mesma do motor de disponibilidade (sem deadlock com
        # criação ou extensão de reservas que disputem os mesmos estoques).
        def lock_pools_in_order(tx, pool_ids)
          return {} if pool_ids.empty?

          tx.query(<<~SQL, [tx.tenant_id!, pool_ids.uniq]).to_h { |row| [row["id"], Domain::Catalog::StockPool.new(**row.transform_keys(&:to_sym))] }
            SELECT id, organization_id, product_id, branch_id, total_quantity FROM stock_pools
             WHERE organization_id = $1 AND id = ANY($2::uuid[]) ORDER BY id FOR UPDATE
          SQL
        end

        def lock_pool(tx, pool_id)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, pool_id])
            SELECT id, organization_id, product_id, branch_id, total_quantity FROM stock_pools WHERE organization_id = $1 AND id = $2 FOR UPDATE
          SQL
          row && Domain::Catalog::StockPool.new(**row.transform_keys(&:to_sym))
        end

        def find_pool(tx, product_id, branch_id)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, product_id, branch_id])
            SELECT id, organization_id, product_id, branch_id, total_quantity FROM stock_pools
             WHERE organization_id = $1 AND product_id = $2 AND branch_id = $3
          SQL
          row && Domain::Catalog::StockPool.new(**row.transform_keys(&:to_sym))
        end

        private

        def occupancy(row)
          { reservation_id: row["reservation_id"], reservation_status: row["reservation_status"], quantity: row["quantity"],
            period: Domain::Period.new(row["starts_at"], row["ends_at"]) }
        end
      end
    end
  end
end
