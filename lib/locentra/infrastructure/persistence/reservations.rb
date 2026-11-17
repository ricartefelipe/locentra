# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class ReservationRepository
        R = Domain::Reservations
        COLUMNS = "id, organization_id, branch_id, customer_id, code, status, source, starts_at, ends_at, hold_expires_at, quote_id, " \
                  "notes, total_cents, deposit_cents, version"
        SORTS = {
          "starts_at" => "r.starts_at ASC, r.id", "-starts_at" => "r.starts_at DESC, r.id",
          "created_at" => "r.created_at ASC, r.id", "-created_at" => "r.created_at DESC, r.id", "code" => "r.code ASC"
        }.freeze
        STATUS_COLUMNS = %w[confirmed_at cancelled_at cancellation_reason expired_at].freeze

        def insert(tx, reservation, pricing, created_by, now)
          tx.execute(<<~SQL, [reservation.id, reservation.organization_id, reservation.branch_id, reservation.customer_id, reservation.code, reservation.status, reservation.source, reservation.period.starts_at, reservation.period.ends_at, reservation.hold_expires_at, reservation.quote_id, reservation.notes, pricing, reservation.total.cents, reservation.deposit.cents, created_by, now, reservation.status == "confirmed" ? now : nil])
            INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, source, starts_at, ends_at, hold_expires_at, quote_id,
                                      notes, pricing, total_cents, deposit_cents, created_by, created_at, updated_at, confirmed_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $17, $18)
          SQL
        end

        def insert_item(tx, reservation_id, item, now)
          tx.execute(<<~SQL, [item[:id], tx.tenant_id!, reservation_id, item[:product_id], item[:quantity], item[:position], item[:pricing], item[:pricing].fetch("total_cents", 0), now])
            INSERT INTO reservation_items (id, organization_id, reservation_id, product_id, quantity, position, pricing, total_cents, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          SQL
        end

        def assign_code(tx, id, code)
          tx.execute("UPDATE reservations SET code = $3 WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id, code])
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM reservations WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def find_by_code(tx, code)
          row = tx.query_one("SELECT #{COLUMNS} FROM reservations WHERE organization_id = $1 AND code = $2",
                             [tx.tenant_id!, code.to_s.upcase])
          row && self.class.map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM reservations WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def items(tx, reservation_id)
          tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT i.id, i.product_id, i.quantity, i.position, i.pricing, i.total_cents, p.sku, p.name, p.tracking
              FROM reservation_items i JOIN products p ON p.organization_id = i.organization_id AND p.id = i.product_id
             WHERE i.organization_id = $1 AND i.reservation_id = $2 ORDER BY i.position
          SQL
        end

        def update_status(tx, reservation, now, extra = {})
          unknown = extra.keys - STATUS_COLUMNS
          raise ArgumentError, "colunas não permitidas: #{unknown}" unless unknown.empty?

          sets = ["status = $3", "version = $4", "updated_at = $5"]
          params = [tx.tenant_id!, reservation.id, reservation.status, reservation.version, now]
          extra.each do |column, value|
            params << value
            sets << "#{column} = $#{params.size}"
          end
          count = tx.execute("UPDATE reservations SET #{sets.join(", ")} WHERE organization_id = $1 AND id = $2 AND version = $4 - 1",
                             params)
          raise Domain::Conflict.new("reserva alterada por outra operação", code: "stale_reservation") unless count == 1
        end

        def update_period(tx, reservation, now, extension_cents: 0)
          count = tx.execute(<<~SQL, [tx.tenant_id!, reservation.id, reservation.period.starts_at, reservation.period.ends_at, reservation.version, now])
            UPDATE reservations SET starts_at = $3, ends_at = $4, version = $5, updated_at = $6
             WHERE organization_id = $1 AND id = $2 AND version = $5 - 1
          SQL
          raise Domain::Conflict.new("reserva alterada por outra operação", code: "stale_reservation") unless count == 1

          extension_cents
        end

        def release_allocations(tx, reservation_id, now)
          %w[asset_allocations stock_allocations].sum do |table|
            tx.execute("UPDATE #{table} SET active = false, released_at = $3 WHERE organization_id = $1 AND reservation_id = $2 AND active",
                       [tx.tenant_id!, reservation_id, now])
          end
        end

        def allocated_asset_ids(tx, reservation_id)
          tx.query("SELECT asset_id FROM asset_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active",
                   [tx.tenant_id!, reservation_id]).map { |r| r["asset_id"] }
        end

        def allocated_product_ids(tx, reservation_id)
          tx.query(<<~SQL, [tx.tenant_id!, reservation_id]).map { |r| r["product_id"] }
            SELECT product_id FROM asset_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active
            UNION
            SELECT product_id FROM stock_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active
          SQL
        end

        def active_allocation_rows(tx, reservation_id)
          tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT id, asset_id, NULL::uuid AS stock_pool_id, product_id, 1 AS quantity, reservation_item_id
              FROM asset_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active
            UNION ALL
            SELECT id, NULL::uuid, stock_pool_id, product_id, quantity, reservation_item_id
              FROM stock_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active
            ORDER BY id
          SQL
        end

        def insert_adjustment(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("reservation_id", "reservation_item_id", "kind", "amount_cents", "details", "created_by", "created_at")])
            INSERT INTO reservation_adjustments (id, organization_id, reservation_id, reservation_item_id, kind, amount_cents, details, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          SQL
        end

        def adjustments(tx, reservation_id)
          tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT id, reservation_item_id, kind, amount_cents, details, created_at FROM reservation_adjustments
             WHERE organization_id = $1 AND reservation_id = $2 ORDER BY created_at
          SQL
        end

        # Bloqueios temporários vencidos. SKIP LOCKED ignora reservas em uso por outra transação.
        def lock_expired_holds(tx, now, limit)
          tx.query(<<~SQL, [tx.tenant_id!, now, limit]).map { |row| self.class.map(row) }
            SELECT #{COLUMNS} FROM reservations
             WHERE organization_id = $1 AND status = 'held' AND hold_expires_at <= $2
             ORDER BY hold_expires_at LIMIT $3
               FOR UPDATE SKIP LOCKED
          SQL
        end

        def search(tx, status:, customer_id:, search:, from:, to:, sort:, limit:, offset:)
          params = [tx.tenant_id!]
          conditions = ["r.organization_id = $1"]
          { "r.status = $%d" => status, "r.customer_id = $%d" => customer_id, "r.ends_at > $%d" => from,
            "r.starts_at < $%d" => to }.each do |fragment, value|
            next if value.nil?

            params << value
            conditions << format(fragment, params.size)
          end
          unless search.to_s.empty?
            params << "%#{search.upcase.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
            conditions << "(r.code LIKE $#{params.size} ESCAPE '\\' OR upper(c.name) LIKE $#{params.size} ESCAPE '\\')"
          end
          where = conditions.join(" AND ")
          from_sql = "FROM reservations r JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id"
          total = tx.query_value("SELECT count(*) #{from_sql} WHERE #{where}", params)
          rows = tx.query(<<~SQL, params + [limit, offset])
            SELECT r.id, r.organization_id, r.branch_id, r.customer_id, r.code, r.status, r.source, r.starts_at, r.ends_at, r.hold_expires_at,
                   r.quote_id, r.notes, r.total_cents, r.deposit_cents, r.version, c.name AS customer_name
              #{from_sql} WHERE #{where} ORDER BY #{SORTS.fetch(sort)} LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}
          SQL
          [rows.map { |row| { reservation: self.class.map(row), customer_name: row["customer_name"] } }, total]
        end

        def allocation_details(tx, reservation_id)
          assets = tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT a.id, a.asset_id, a.product_id, a.reservation_item_id, a.active, lower(a.period) AS starts_at, upper(a.period) AS ends_at,
                   s.tag, s.serial_number, s.status AS asset_status
              FROM asset_allocations a JOIN assets s ON s.organization_id = a.organization_id AND s.id = a.asset_id
             WHERE a.organization_id = $1 AND a.reservation_id = $2 ORDER BY a.active DESC, s.tag
          SQL
          stock = tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT s.id, s.stock_pool_id, s.product_id, s.reservation_item_id, s.quantity, s.active, lower(s.period) AS starts_at, upper(s.period) AS ends_at
              FROM stock_allocations s WHERE s.organization_id = $1 AND s.reservation_id = $2 ORDER BY s.active DESC, s.id
          SQL
          { assets: assets, stock: stock }
        end

        def pricing(tx, reservation_id)
          summary = tx.query_value("SELECT pricing FROM reservations WHERE organization_id = $1 AND id = $2",
                                   [tx.tenant_id!, reservation_id])
          { summary: summary || {}, adjustments: adjustments(tx, reservation_id) }
        end

        def self.map(row)
          R::Reservation.new(
            id: row["id"], organization_id: row["organization_id"], branch_id: row["branch_id"], customer_id: row["customer_id"], code: row["code"],
            status: row["status"], source: row["source"], period: Domain::Period.new(row["starts_at"], row["ends_at"]),
            hold_expires_at: row["hold_expires_at"]&.utc, quote_id: row["quote_id"], notes: row["notes"],
            total: Domain::Money.new(row["total_cents"]), deposit: Domain::Money.new(row["deposit_cents"]), version: row["version"]
          )
        end
      end
    end
  end
end
