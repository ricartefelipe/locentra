# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Pagamentos e reembolsos. Atualizações exigem a situação anterior esperada (controle otimista
      # sobre o lock FOR UPDATE); o banco recusa alterações de registros concluídos (trigger).
      class PaymentRepository
        F = Domain::Finance
        COLUMNS = "p.id, p.organization_id, p.purpose, p.receivable_id, p.deposit_id, p.reservation_id, p.customer_id, p.method, p.provider, " \
                  "p.provider_account_id, p.status, p.amount_cents, p.external_reference, p.provider_payment_id, p.invoice_url, p.due_on, " \
                  "p.simulator_scenario, p.requires_review, p.review_reason, p.failure_reason, p.submission_attempts, " \
                  "p.submission_started_at, p.notes, p.paid_at, p.confirmed_at, p.created_at"
        REFUND_COLUMNS = "f.id, f.organization_id, f.payment_id, f.amount_cents, f.reason, f.status, f.provider_reference, f.failure_reason, " \
                         "f.confirmed_at, f.submission_attempts, f.submission_started_at, f.created_at"
        LISTING_FROM = "FROM payments p JOIN customers c ON c.organization_id = p.organization_id AND c.id = p.customer_id " \
                       "JOIN reservations r ON r.organization_id = p.organization_id AND r.id = p.reservation_id"

        def insert(tx, payment, created_by, now)
          tx.execute(<<~SQL, [payment.id, tx.tenant_id!, payment.purpose, payment.receivable_id, payment.deposit_id, payment.reservation_id, payment.customer_id, payment.payment_method, payment.provider, payment.provider_account_id, payment.status, payment.amount.cents, payment.external_reference, payment.due_on, payment.simulator_scenario, payment.requires_review, payment.review_reason, payment.notes, payment.paid_at, payment.confirmed_at, created_by, now])
            INSERT INTO payments (id, organization_id, purpose, receivable_id, deposit_id, reservation_id, customer_id, method, provider, provider_account_id,
                                  status, amount_cents, external_reference, due_on, simulator_scenario, requires_review, review_reason, notes, paid_at,
                                  confirmed_at, created_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $22)
          SQL
        end

        def find(tx, id) = one(tx, "p.id = $2", id)
        def lock(tx, id) = one(tx, "p.id = $2", id, lock: true)

        def lock_by_provider_id(tx, account_id, provider_payment_id)
          row = tx.query_one("SELECT #{COLUMNS} FROM payments p WHERE p.organization_id = $1 AND p.provider_account_id = $2 AND p.provider_payment_id = $3 " \
                             "FOR UPDATE", [tx.tenant_id!, account_id, provider_payment_id.to_s])
          row && self.class.map(row)
        end

        def update(tx, payment, from:, now:)
          count = tx.execute(<<~SQL, [tx.tenant_id!, payment.id, payment.status, payment.provider_payment_id, payment.invoice_url, payment.requires_review, payment.review_reason, payment.failure_reason, payment.submission_attempts, payment.submission_started_at, payment.paid_at, payment.confirmed_at, now, from])
            UPDATE payments SET status = $3, provider_payment_id = $4, invoice_url = $5, requires_review = $6, review_reason = $7, failure_reason = $8,
                                submission_attempts = $9, submission_started_at = $10, paid_at = $11, confirmed_at = $12, updated_at = $13
             WHERE organization_id = $1 AND id = $2 AND status = $14
          SQL
          raise Domain::Conflict.new("pagamento alterado por outra operação", code: "stale_payment") unless count == 1

          payment
        end

        def for_receivable(tx, receivable_id) = listing(tx, "p.receivable_id = $2", [receivable_id], 100)
        def for_deposit(tx, deposit_id) = listing(tx, "p.deposit_id = $2", [deposit_id], 100)
        def for_reservation(tx, reservation_id) = listing(tx, "p.reservation_id = $2", [reservation_id], 100)
        def recent(tx, limit) = listing(tx, "TRUE", [], limit)

        def for_reconciliation(tx, account_id, since)
          tx.query("SELECT #{COLUMNS} FROM payments p WHERE p.organization_id = $1 AND p.provider_account_id = $2 AND p.created_at >= $3 " \
                   "ORDER BY p.created_at, p.id", [tx.tenant_id!, account_id, since]).map { |row| self.class.map(row) }
        end

        # Pagamentos em aberto no provedor de contas desativadas (substituídas), para consulta individual.
        def open_from_inactive_accounts(tx, since, limit)
          tx.query(<<~SQL, [tx.tenant_id!, since, limit]).map { |row| self.class.map(row) }
            SELECT #{COLUMNS} FROM payments p
              JOIN payment_provider_accounts a ON a.organization_id = p.organization_id AND a.id = p.provider_account_id
             WHERE p.organization_id = $1 AND NOT a.active AND p.status IN ('submission_unknown', 'pending') AND p.created_at >= $2
             ORDER BY p.created_at, p.id LIMIT $3
          SQL
        end

        # Referências externas, entre as informadas, que pertencem a algum pagamento da organização.
        def existing_references(tx, references)
          return [] if references.empty?

          tx.query("SELECT external_reference FROM payments WHERE organization_id = $1 AND external_reference = ANY($2::text[])",
                   [tx.tenant_id!, references]).map { |row| row["external_reference"] }
        end

        # Reembolsos pendentes e confirmados por pagamento.
        def committed_refunds_by_payment(tx, payment_ids)
          return {} if payment_ids.empty?

          tx.query(<<~SQL, [tx.tenant_id!, payment_ids]).to_h { |row| [row["payment_id"], Domain::Money.new(row["cents"])] }
            SELECT payment_id, sum(amount_cents)::bigint AS cents FROM refunds
             WHERE organization_id = $1 AND payment_id = ANY($2::uuid[]) AND status IN ('pending', 'confirmed') GROUP BY payment_id
          SQL
        end

        # Reembolsos que comprometem o valor do pagamento (pendentes e confirmados).
        def committed_refunds(tx, payment_id)
          Domain::Money.new(tx.query_value(<<~SQL, [tx.tenant_id!, payment_id]))
            SELECT COALESCE(sum(amount_cents), 0)::bigint FROM refunds
             WHERE organization_id = $1 AND payment_id = $2 AND status IN ('pending', 'confirmed')
          SQL
        end

        def refunds(tx, payment_id)
          tx.query(<<~SQL, [tx.tenant_id!, payment_id]).map { |row| { refund: self.class.map_refund(row), created_at: row["created_at"], created_by_name: row["created_by_name"] } }
            SELECT #{REFUND_COLUMNS}, u.name AS created_by_name FROM refunds f LEFT JOIN users u ON u.id = f.created_by
             WHERE f.organization_id = $1 AND f.payment_id = $2 ORDER BY f.created_at, f.id
          SQL
        end

        def insert_refund(tx, refund, created_by, now)
          tx.execute(<<~SQL, [refund.id, tx.tenant_id!, refund.payment_id, refund.amount.cents, refund.reason, refund.status, refund.provider_reference, refund.confirmed_at, created_by, now])
            INSERT INTO refunds (id, organization_id, payment_id, amount_cents, reason, status, provider_reference, confirmed_at, created_by, created_at,
                                 updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10)
          SQL
        end

        def find_refund(tx, id) = refund_row(tx, id, "")
        def lock_refund(tx, id) = refund_row(tx, id, "FOR UPDATE")

        def update_refund(tx, refund, from:, now:)
          count = tx.execute(<<~SQL, [tx.tenant_id!, refund.id, refund.status, refund.provider_reference, refund.failure_reason, refund.confirmed_at, refund.status == "failed" ? now : nil, now, from, refund.submission_attempts, refund.submission_started_at])
            UPDATE refunds SET status = $3, provider_reference = $4, failure_reason = $5, confirmed_at = $6, failed_at = $7, updated_at = $8,
                               submission_attempts = $10, submission_started_at = $11
             WHERE organization_id = $1 AND id = $2 AND status = $9
          SQL
          raise Domain::Conflict.new("reembolso alterado por outra operação", code: "stale_refund") unless count == 1

          refund
        end

        def self.map(row)
          F::Payment.new(
            id: row["id"], organization_id: row["organization_id"], purpose: row["purpose"], receivable_id: row["receivable_id"],
            deposit_id: row["deposit_id"], reservation_id: row["reservation_id"], customer_id: row["customer_id"], payment_method: row["method"],
            provider: row["provider"], provider_account_id: row["provider_account_id"], status: row["status"], amount: Domain::Money.new(row["amount_cents"]),
            external_reference: row["external_reference"], provider_payment_id: row["provider_payment_id"], invoice_url: row["invoice_url"],
            due_on: row["due_on"], simulator_scenario: row["simulator_scenario"], requires_review: row["requires_review"],
            review_reason: row["review_reason"], failure_reason: row["failure_reason"], submission_attempts: row["submission_attempts"],
            submission_started_at: row["submission_started_at"], notes: row["notes"], paid_at: row["paid_at"], confirmed_at: row["confirmed_at"]
          )
        end

        def self.map_refund(row)
          F::Refund.new(id: row["id"], organization_id: row["organization_id"], payment_id: row["payment_id"], amount: Domain::Money.new(row["amount_cents"]),
                        reason: row["reason"], status: row["status"], provider_reference: row["provider_reference"], failure_reason: row["failure_reason"],
                        confirmed_at: row["confirmed_at"], submission_attempts: row["submission_attempts"].to_i,
                        submission_started_at: row["submission_started_at"])
        end

        private

        def one(tx, condition, value, lock: false)
          row = tx.query_one("SELECT #{COLUMNS} FROM payments p WHERE p.organization_id = $1 AND #{condition} #{"FOR UPDATE" if lock}",
                             [tx.tenant_id!, value])
          row && self.class.map(row)
        end

        def listing(tx, condition, params, limit)
          tx.query(<<~SQL, [tx.tenant_id!, *params, limit]).map { |row| { payment: self.class.map(row), created_at: row["created_at"], customer_name: row["customer_name"], reservation_code: row["reservation_code"] } }
            SELECT #{COLUMNS}, c.name AS customer_name, r.code AS reservation_code #{LISTING_FROM}
             WHERE p.organization_id = $1 AND #{condition} ORDER BY p.created_at DESC, p.id DESC LIMIT $#{params.size + 2}
          SQL
        end

        def refund_row(tx, id, suffix)
          row = tx.query_one("SELECT #{REFUND_COLUMNS} FROM refunds f WHERE f.organization_id = $1 AND f.id = $2 #{suffix}", [tx.tenant_id!, id])
          row && self.class.map_refund(row)
        end
      end
    end
  end
end
