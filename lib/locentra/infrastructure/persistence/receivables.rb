# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Contas a receber com saldo derivado (nenhum saldo é armazenado). sum(bigint) devolve numeric
      # no PostgreSQL; os agregados são convertidos explicitamente para bigint.
      class ReceivableRepository
        F = Domain::Finance
        COLUMNS = "r.id, r.organization_id, r.reservation_id, r.customer_id, r.kind, r.source_type, r.source_id, r.description, " \
                  "r.amount_cents, r.due_on, r.created_at"
        BALANCE = <<~SQL
          COALESCE((SELECT sum(x.amount_cents) FROM receivable_cancellations x
                     WHERE x.organization_id = r.organization_id AND x.receivable_id = r.id), 0)::bigint AS cancelled_cents,
          COALESCE((SELECT sum(p.amount_cents) FROM payments p
                     WHERE p.organization_id = r.organization_id AND p.receivable_id = r.id AND p.status = 'confirmed'), 0)::bigint AS paid_cents,
          COALESCE((SELECT sum(f.amount_cents) FROM refunds f
                      JOIN payments p ON p.organization_id = f.organization_id AND p.id = f.payment_id
                     WHERE f.organization_id = r.organization_id AND p.receivable_id = r.id AND f.status IN ('pending', 'confirmed')), 0)::bigint
            AS refunded_cents,
          COALESCE((SELECT sum(e.amount_cents) FROM deposit_entries e
                     WHERE e.organization_id = r.organization_id AND e.receivable_id = r.id AND e.kind = 'apply'), 0)::bigint AS applied_cents
        SQL
        # Mesma regra de Domain::Finance::Balance#status, usada para filtrar e paginar no banco.
        LISTING = <<~SQL.freeze
          WITH base AS (
            SELECT #{COLUMNS}, c.name AS customer_name, res.code AS reservation_code, #{BALANCE}
              FROM receivables r
              JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id
              JOIN reservations res ON res.organization_id = r.organization_id AND res.id = r.reservation_id
             WHERE r.organization_id = $1
          ), figures AS (
            SELECT base.*, amount_cents - cancelled_cents - paid_cents + refunded_cents - applied_cents AS outstanding_cents,
                   paid_cents - refunded_cents + applied_cents AS settled_cents
              FROM base
          ), listing AS (
            SELECT figures.*,
                   CASE WHEN cancelled_cents > 0 THEN 'cancelled' WHEN outstanding_cents < 0 THEN 'credit' WHEN outstanding_cents = 0 THEN 'paid'
                        WHEN settled_cents > 0 THEN 'partial' ELSE 'open' END AS status
              FROM figures
          )
        SQL

        def insert_if_absent(tx, receivable, created_by, now)
          tx.execute(<<~SQL, [receivable.id, tx.tenant_id!, receivable.reservation_id, receivable.customer_id, receivable.kind, receivable.source_type, receivable.source_id, receivable.description, receivable.amount.cents, receivable.due_on, created_by, now]) == 1
            INSERT INTO receivables (id, organization_id, reservation_id, customer_id, kind, source_type, source_id, description, amount_cents, due_on,
                                     created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            ON CONFLICT (organization_id, source_type, source_id) DO NOTHING
          SQL
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM receivables r WHERE r.organization_id = $1 AND r.id = $2", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM receivables r WHERE r.organization_id = $1 AND r.id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def balance(tx, id)
          row = tx.query_one("SELECT r.amount_cents, #{BALANCE} FROM receivables r WHERE r.organization_id = $1 AND r.id = $2", [tx.tenant_id!, id])
          row && self.class.balance(row)
        end

        def cancellation(tx, receivable_id)
          tx.query_one(<<~SQL, [tx.tenant_id!, receivable_id])
            SELECT x.id, x.amount_cents, x.reason, x.created_at, u.name AS created_by_name
              FROM receivable_cancellations x LEFT JOIN users u ON u.id = x.created_by
             WHERE x.organization_id = $1 AND x.receivable_id = $2
          SQL
        end

        def insert_cancellation(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("receivable_id", "amount_cents", "reason", "created_by", "created_at")])
            INSERT INTO receivable_cancellations (id, organization_id, receivable_id, amount_cents, reason, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
          SQL
        end

        def for_reservation(tx, reservation_id)
          tx.query("#{LISTING} SELECT * FROM listing WHERE reservation_id = $2 ORDER BY created_at, id", [tx.tenant_id!, reservation_id])
            .map { |row| self.class.listed(row) }
        end

        # Há cobrança em aberto na reserva (desconsiderados os tipos em `except_kinds`).
        def open_for_reservation?(tx, reservation_id, except_kinds: [])
          !tx.query_one(<<~SQL, [tx.tenant_id!, reservation_id, except_kinds]).nil?
            #{LISTING} SELECT 1 FROM listing WHERE reservation_id = $2 AND status IN ('open', 'partial') AND kind <> ALL($3::text[]) LIMIT 1
          SQL
        end

        # Listagem paginada com filtro de situação por allowlist (o valor é parâmetro, nunca SQL).
        def search(tx, status:, limit:, offset:)
          raise ArgumentError, "situação inválida" if status && !F::RECEIVABLE_STATUSES.key?(status)

          filter = "($2::text IS NULL OR status = $2)"
          total = tx.query_value("#{LISTING} SELECT count(*) FROM listing WHERE #{filter}", [tx.tenant_id!, status])
          rows = tx.query("#{LISTING} SELECT * FROM listing WHERE #{filter} ORDER BY due_on, created_at, id LIMIT $3 OFFSET $4",
                          [tx.tenant_id!, status, limit, offset])
          [rows.map { |row| self.class.listed(row) }, total]
        end

        def totals(tx)
          row = tx.query_one(<<~SQL, [tx.tenant_id!])
            #{LISTING}
            SELECT COALESCE(sum(outstanding_cents) FILTER (WHERE status IN ('open', 'partial')), 0)::bigint AS open_cents,
                   COALESCE(-sum(outstanding_cents) FILTER (WHERE outstanding_cents < 0), 0)::bigint AS credit_cents,
                   count(*) FILTER (WHERE status IN ('open', 'partial')) AS open_count
              FROM listing
          SQL
          { open: Domain::Money.new(row["open_cents"]), credit: Domain::Money.new(row["credit_cents"]), open_count: row["open_count"] }
        end

        def self.map(row)
          F::Receivable.new(id: row["id"], organization_id: row["organization_id"], reservation_id: row["reservation_id"], customer_id: row["customer_id"],
                            kind: row["kind"], source_type: row["source_type"], source_id: row["source_id"], description: row["description"],
                            amount: Domain::Money.new(row["amount_cents"]), due_on: row["due_on"])
        end

        def self.balance(row)
          m = ->(key) { Domain::Money.new(row[key]) }
          F::Balance.new(amount: m.call("amount_cents"), cancelled: m.call("cancelled_cents"), paid: m.call("paid_cents"),
                         refunded: m.call("refunded_cents"), applied: m.call("applied_cents"))
        end

        def self.listed(row)
          { receivable: map(row), balance: balance(row), customer_name: row["customer_name"], reservation_code: row["reservation_code"],
            created_at: row["created_at"] }
        end
      end
    end
  end
end
