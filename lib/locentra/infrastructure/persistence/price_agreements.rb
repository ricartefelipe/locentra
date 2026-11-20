# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Condições negociadas por cliente. Somente o encerramento é gravado depois da criação (privilégio
      # de coluna e gatilho de encerramento único no banco); a exclusion constraint impede vigências
      # sobrepostas do mesmo cliente e escopo.
      class PriceAgreementRepository
        COLUMNS = PricingRepository::AGREEMENT_COLUMNS
        # Janela efetiva calculada pela mesma função da exclusion constraint.
        WINDOW_SQL = "price_agreement_window(valid_from, valid_until, ended_at)"

        def self.map(row)
          Domain::Pricing::Agreement.new(
            id: row["id"], organization_id: row["organization_id"], customer_id: row["customer_id"], product_id: row["product_id"],
            discount_bps: row["discount_bps"], valid_from: row["valid_from"]&.getutc, valid_until: row["valid_until"]&.getutc,
            notes: row["notes"], created_by: row["created_by"], created_at: row["created_at"]&.getutc, ended_at: row["ended_at"]&.getutc,
            ended_by: row["ended_by"], end_reason: row["end_reason"]
          )
        end

        def insert(tx, agreement)
          tx.execute(<<~SQL, [agreement.id, tx.tenant_id!, agreement.customer_id, agreement.product_id, agreement.discount_bps, agreement.valid_from, agreement.valid_until, agreement.notes, agreement.created_by, agreement.created_at])
            INSERT INTO customer_price_agreements (id, organization_id, customer_id, product_id, discount_bps, valid_from, valid_until, notes,
                                                   created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end

        def find(tx, id) = load(tx, id, lock: false)
        def lock(tx, id) = load(tx, id, lock: true)

        # Encerramento único: a condição já encerrada por outra transação não é regravada.
        def end_agreement(tx, agreement)
          count = tx.execute(<<~SQL, [tx.tenant_id!, agreement.id, agreement.ended_at, agreement.ended_by, agreement.end_reason])
            UPDATE customer_price_agreements SET ended_at = $3, ended_by = $4, end_reason = $5
             WHERE organization_id = $1 AND id = $2 AND ended_at IS NULL
          SQL
          raise Domain::InvalidTransition.new("condição negociada", "ended", "ended") unless count == 1
        end

        # Pré-verificação de sobreposição (a garantia final é a exclusion constraint).
        def overlapping?(tx, agreement)
          !tx.query_one(<<~SQL, [tx.tenant_id!, agreement.customer_id, agreement.product_id, agreement.valid_from, agreement.valid_until]).nil?
            SELECT 1 FROM customer_price_agreements
             WHERE organization_id = $1 AND customer_id = $2 AND product_id IS NOT DISTINCT FROM $3::uuid
               AND #{WINDOW_SQL} && price_agreement_window($4, $5, NULL)
             LIMIT 1
          SQL
        end

        # Condições do cliente: as que não estão encerradas primeiro, depois as mais recentes. SKU e
        # nome do produto somente com `products` (escopo de catálogo do ator). Devolve
        # [[{ agreement:, product_sku:, product_name:, created_by_name:, ended_by_name: }], total].
        def for_customer(tx, customer_id, limit:, offset:, products:, now:)
          total = tx.query_value("SELECT count(*) FROM customer_price_agreements WHERE organization_id = $1 AND customer_id = $2",
                                 [tx.tenant_id!, customer_id])
          rows = tx.query(<<~SQL, [tx.tenant_id!, customer_id, limit, offset, now, products])
            SELECT #{COLUMNS.split(", ").map { |column| "a.#{column}" }.join(", ")},
                   CASE WHEN $6 THEN p.sku END AS product_sku, CASE WHEN $6 THEN p.name END AS product_name,
                   COALESCE(cu.name, cc.name) AS created_by_name, COALESCE(eu.name, ec.name) AS ended_by_name
              FROM customer_price_agreements a
              LEFT JOIN products p ON p.organization_id = a.organization_id AND p.id = a.product_id
              LEFT JOIN users cu ON cu.id = a.created_by
              LEFT JOIN api_credentials cc ON cc.organization_id = a.organization_id AND cc.id = a.created_by
              LEFT JOIN users eu ON eu.id = a.ended_by
              LEFT JOIN api_credentials ec ON ec.organization_id = a.organization_id AND ec.id = a.ended_by
             WHERE a.organization_id = $1 AND a.customer_id = $2
             ORDER BY (a.ended_at IS NOT NULL AND a.ended_at <= $5), a.valid_from DESC, a.id
             LIMIT $3 OFFSET $4
          SQL
          items = rows.map do |row|
            { agreement: self.class.map(row), product_sku: row["product_sku"], product_name: row["product_name"],
              created_by_name: row["created_by_name"], ended_by_name: row["ended_by_name"] }
          end
          [items, total]
        end

        private

        def load(tx, id, lock:)
          row = tx.query_one("SELECT #{COLUMNS} FROM customer_price_agreements WHERE organization_id = $1 AND id = $2 #{"FOR UPDATE" if lock}",
                             [tx.tenant_id!, id])
          row && self.class.map(row)
        end
      end
    end
  end
end
