# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class PricingRepository
        def find_coupon(tx, code, lock: false)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, code])
            SELECT code, kind, value, valid_from, valid_until, max_redemptions, redemptions, min_subtotal_cents, active
              FROM coupons WHERE organization_id = $1 AND code = $2 #{"FOR UPDATE" if lock}
          SQL
          return nil unless row

          Domain::Pricing::Coupon.new(code: row["code"], kind: row["kind"], value: row["value"], valid_from: row["valid_from"],
                                      valid_until: row["valid_until"], max_redemptions: row["max_redemptions"], redemptions: row["redemptions"],
                                      min_subtotal_cents: row["min_subtotal_cents"], active: row["active"])
        end

        # Consome uma utilização do cupom; a CHECK constraint impede exceder o máximo sob concorrência.
        def redeem_coupon(tx, code)
          count = tx.execute(<<~SQL, [tx.tenant_id!, code])
            UPDATE coupons SET redemptions = redemptions + 1
             WHERE organization_id = $1 AND code = $2 AND (max_redemptions IS NULL OR redemptions < max_redemptions)
          SQL
          raise Domain::ValidationError.field("cupom", "cupom esgotado") unless count == 1
        end

        def insert_coupon(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("code", "kind", "value", "valid_from", "valid_until", "max_redemptions", "min_subtotal_cents", "created_at")])
            INSERT INTO coupons (id, organization_id, code, kind, value, valid_from, valid_until, max_redemptions, min_subtotal_cents, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end

        def coupons(tx)
          tx.query("SELECT * FROM coupons WHERE organization_id = $1 ORDER BY created_at DESC", [tx.tenant_id!])
        end

        # Maior desconto negociado vigente: específico do produto ou geral do cliente.
        def negotiated_discount_bps(tx, customer_id, product_id, now)
          tx.query_value(<<~SQL, [tx.tenant_id!, customer_id, product_id, now]).to_i
            SELECT COALESCE(max(discount_bps), 0) FROM customer_price_agreements
             WHERE organization_id = $1 AND customer_id = $2 AND (product_id IS NULL OR product_id = $3)
               AND (valid_until IS NULL OR valid_until > $4)
          SQL
        end

        def insert_agreement(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("customer_id", "product_id", "discount_bps", "valid_until", "notes", "created_by", "created_at")])
            INSERT INTO customer_price_agreements (id, organization_id, customer_id, product_id, discount_bps, valid_until, notes, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          SQL
        end

        def agreements(tx, customer_id)
          tx.query(<<~SQL, [tx.tenant_id!, customer_id])
            SELECT a.id, a.product_id, a.discount_bps, a.valid_until, a.notes, p.name AS product_name
              FROM customer_price_agreements a LEFT JOIN products p ON p.organization_id = a.organization_id AND p.id = a.product_id
             WHERE a.organization_id = $1 AND a.customer_id = $2 ORDER BY a.created_at DESC
          SQL
        end
      end
    end
  end
end
