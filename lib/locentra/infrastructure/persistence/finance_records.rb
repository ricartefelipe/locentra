# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Diário contábil (somente inserção; balanceamento verificado no COMMIT por constraint trigger).
      class LedgerRepository
        def insert(tx, rows)
          rows.each do |row|
            tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("transaction_id", "position", "account", "debit_cents", "credit_cents", "source_type", "source_id", "memo", "occurred_at")])
              INSERT INTO financial_entries (id, organization_id, transaction_id, position, account, debit_cents, credit_cents, source_type, source_id, memo,
                                             occurred_at)
              VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            SQL
          end
        end

        # Saldo por conta (débitos − créditos).
        def trial_balance(tx)
          rows = tx.query(<<~SQL, [tx.tenant_id!])
            SELECT account, (COALESCE(sum(debit_cents), 0) - COALESCE(sum(credit_cents), 0))::bigint AS net_cents
              FROM financial_entries WHERE organization_id = $1 GROUP BY account
          SQL
          totals = Domain::Finance::ACCOUNTS.keys.to_h { |account| [account, Domain::Money.zero] }
          rows.each { |row| totals[row["account"]] = Domain::Money.new(row["net_cents"]) }
          totals
        end

        def for_source(tx, source_type, source_id)
          tx.query(<<~SQL, [tx.tenant_id!, source_type, source_id])
            SELECT e.transaction_id, e.position, e.account, e.debit_cents, e.credit_cents, e.memo, e.occurred_at
              FROM financial_entries e
             WHERE e.organization_id = $1 AND e.transaction_id IN (
                     SELECT transaction_id FROM financial_entries WHERE organization_id = $1 AND source_type = $2 AND source_id = $3)
             ORDER BY e.occurred_at, e.transaction_id, e.position
          SQL
        end

        def unbalanced_transactions(tx)
          tx.query(<<~SQL, [tx.tenant_id!]).map { |row| row["transaction_id"] }
            SELECT transaction_id FROM financial_entries WHERE organization_id = $1
             GROUP BY transaction_id HAVING sum(debit_cents) <> sum(credit_cents)
          SQL
        end
      end

      class FinanceAlertRepository
        COLUMNS = "a.id, a.kind, a.status, a.reservation_id, a.payment_id, a.message, a.resolution, a.resolution_notes, a.resolved_at, a.created_at"

        # Retorna true quando o alerta foi criado (chave de deduplicação nova).
        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("kind", "reservation_id", "payment_id", "message", "dedupe_key", "created_at")]) == 1
            INSERT INTO finance_alerts (id, organization_id, kind, reservation_id, payment_id, message, dedupe_key, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (organization_id, dedupe_key) DO NOTHING
          SQL
        end

        def open(tx, limit) = listing(tx, "a.status = 'open'", [], limit)
        def for_reservation(tx, reservation_id) = listing(tx, "a.reservation_id = $2", [reservation_id], 50)
        def for_payment(tx, payment_id) = listing(tx, "a.payment_id = $2", [payment_id], 50)

        def lock(tx, id)
          tx.query_one("SELECT #{COLUMNS} FROM finance_alerts a WHERE a.organization_id = $1 AND a.id = $2 FOR UPDATE", [tx.tenant_id!, id])
        end

        def resolve(tx, id, resolution, notes, by, now)
          tx.execute(<<~SQL, [tx.tenant_id!, id, resolution, notes, by, now])
            UPDATE finance_alerts SET status = 'resolved', resolution = $3, resolution_notes = $4, resolved_by = $5, resolved_at = $6
             WHERE organization_id = $1 AND id = $2 AND status = 'open'
          SQL
        end

        private

        def listing(tx, condition, params, limit)
          tx.query(<<~SQL, [tx.tenant_id!, *params, limit])
            SELECT #{COLUMNS}, r.code AS reservation_code
              FROM finance_alerts a LEFT JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND #{condition} ORDER BY a.created_at DESC, a.id LIMIT $#{params.size + 2}
          SQL
        end
      end

      # Faturas comerciais (não fiscais), imutáveis.
      class InvoiceRepository
        COLUMNS = "i.id, i.number, i.reservation_id, i.customer_id, i.total_cents, i.settled_cents, i.outstanding_cents, i.lines, i.notes, i.issued_at"

        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("number", "reservation_id", "customer_id", "total_cents", "settled_cents", "outstanding_cents", "lines", "notes", "created_by", "issued_at")])
            INSERT INTO invoices (id, organization_id, number, reservation_id, customer_id, total_cents, settled_cents, outstanding_cents, lines, notes,
                                  created_by, issued_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
        end

        def find(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT #{COLUMNS}, c.name AS customer_name, c.document AS customer_document, r.code AS reservation_code, o.name AS organization_name
              FROM invoices i
              JOIN customers c ON c.organization_id = i.organization_id AND c.id = i.customer_id
              JOIN reservations r ON r.organization_id = i.organization_id AND r.id = i.reservation_id
              JOIN organizations o ON o.id = i.organization_id
             WHERE i.organization_id = $1 AND i.id = $2
          SQL
        end

        def for_reservation(tx, reservation_id)
          tx.query("SELECT #{COLUMNS} FROM invoices i WHERE i.organization_id = $1 AND i.reservation_id = $2 ORDER BY i.issued_at DESC",
                   [tx.tenant_id!, reservation_id])
        end
      end
    end
  end
end
