# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Cauções e seus movimentos (somente inserção). O saldo é derivado dos movimentos.
      class DepositRepository
        F = Domain::Finance
        COLUMNS = "d.id, d.organization_id, d.reservation_id, d.customer_id, d.kind, d.expected_cents, d.notes, d.created_at"
        SUMS = <<~SQL
          COALESCE(sum(e.amount_cents) FILTER (WHERE e.kind = 'receive'), 0)::bigint AS received_cents,
          COALESCE(sum(e.amount_cents) FILTER (WHERE e.kind = 'apply'), 0)::bigint AS applied_cents,
          COALESCE(sum(e.amount_cents) FILTER (WHERE e.kind = 'return'), 0)::bigint AS returned_cents
        SQL

        def insert(tx, deposit, created_by, now)
          tx.execute(<<~SQL, [deposit.id, tx.tenant_id!, deposit.reservation_id, deposit.customer_id, deposit.kind, deposit.expected.cents, deposit.notes, created_by, now])
            INSERT INTO deposits (id, organization_id, reservation_id, customer_id, kind, expected_cents, notes, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          SQL
        end

        def find(tx, id) = one(tx, "d.id = $2", id)
        def lock(tx, id) = one(tx, "d.id = $2", id, lock: true)
        def for_reservation(tx, reservation_id) = one(tx, "d.reservation_id = $2", reservation_id)

        def ledger(tx, deposit_id)
          row = tx.query_one("SELECT #{SUMS} FROM deposit_entries e WHERE e.organization_id = $1 AND e.deposit_id = $2", [tx.tenant_id!, deposit_id])
          self.class.ledger(row)
        end

        def entries(tx, deposit_id)
          tx.query(<<~SQL, [tx.tenant_id!, deposit_id])
            SELECT e.id, e.kind, e.amount_cents, e.payment_id, e.receivable_id, e.method, e.notes, e.created_at, u.name AS created_by_name,
                   r.description AS receivable_description
              FROM deposit_entries e
              LEFT JOIN users u ON u.id = e.created_by
              LEFT JOIN receivables r ON r.organization_id = e.organization_id AND r.id = e.receivable_id
             WHERE e.organization_id = $1 AND e.deposit_id = $2 ORDER BY e.created_at, e.id
          SQL
        end

        def insert_entry(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("deposit_id", "kind", "amount_cents", "payment_id", "receivable_id", "method", "notes", "created_by", "created_at")])
            INSERT INTO deposit_entries (id, organization_id, deposit_id, kind, amount_cents, payment_id, receivable_id, method, notes, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          SQL
        end

        # Cauções com saldo retido (passivo com clientes).
        def held(tx, limit)
          tx.query(<<~SQL, [tx.tenant_id!, limit]).map { |row| { deposit: self.class.map(row), ledger: self.class.ledger(row), reservation_code: row["reservation_code"], customer_name: row["customer_name"] } }
            SELECT #{COLUMNS}, r.code AS reservation_code, c.name AS customer_name, #{SUMS}
              FROM deposits d
              JOIN reservations r ON r.organization_id = d.organization_id AND r.id = d.reservation_id
              JOIN customers c ON c.organization_id = d.organization_id AND c.id = d.customer_id
              LEFT JOIN deposit_entries e ON e.organization_id = d.organization_id AND e.deposit_id = d.id
             WHERE d.organization_id = $1
             GROUP BY d.id, r.code, c.name
            HAVING COALESCE(sum(CASE WHEN e.kind = 'receive' THEN e.amount_cents ELSE -e.amount_cents END), 0) > 0
             ORDER BY d.created_at DESC LIMIT $2
          SQL
        end

        def self.map(row)
          F::Deposit.new(id: row["id"], organization_id: row["organization_id"], reservation_id: row["reservation_id"], customer_id: row["customer_id"],
                         kind: row["kind"], expected: Domain::Money.new(row["expected_cents"]), notes: row["notes"])
        end

        def self.ledger(row)
          F::DepositLedger.new(received: Domain::Money.new(row["received_cents"]), applied: Domain::Money.new(row["applied_cents"]),
                               returned: Domain::Money.new(row["returned_cents"]))
        end

        private

        def one(tx, condition, value, lock: false)
          row = tx.query_one("SELECT #{COLUMNS} FROM deposits d WHERE d.organization_id = $1 AND #{condition} #{"FOR UPDATE" if lock}",
                             [tx.tenant_id!, value])
          row && self.class.map(row)
        end
      end
    end
  end
end
