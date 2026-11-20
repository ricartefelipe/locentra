# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Nome de quem criou um registro: usuário ou credencial de integração da organização.
      module ActorNames
        def actor_name(tx, actor_id)
          return nil if actor_id.nil?

          tx.query_value(<<~SQL, [tx.tenant_id!, actor_id])
            SELECT COALESCE((SELECT name FROM users WHERE id = $2), (SELECT name FROM api_credentials WHERE organization_id = $1 AND id = $2))
          SQL
        end
      end

      # Leituras e gravações usadas pela precificação de reservas e orçamentos: cupom com usos ativos,
      # livro de usos, condição negociada aplicável e tarifas do catálogo.
      class PricingRepository
        COUPON_COLUMNS = "id, organization_id, code, kind, value, valid_from, valid_until, max_redemptions, redemptions, min_subtotal_cents, " \
                         "active, description, created_by, created_at, updated_at, deactivated_at, lock_version"
        # Fragmento único de "uso ativo" (`v` é a reserva do uso; $n é o instante de referência). Mesma
        # regra de Domain::Pricing::Redemptions.active? e do gatilho coupon_redemptions_enforce_limit.
        ACTIVE_USE_SQL = "(v.status IN ('requested', 'confirmed', 'in_progress', 'completed') " \
                         "OR (v.status = 'held' AND v.hold_expires_at > $%<now>d))"
        AGREEMENT_COLUMNS = "id, organization_id, customer_id, product_id, discount_bps, valid_from, valid_until, notes, created_by, created_at, " \
                            "ended_at, ended_by, end_reason"

        # `redemptions` = contador legado (congelado na 1.0.0) + usos ativos do livro.
        def self.map_coupon(row, active_uses: 0, total_uses: nil)
          legacy = row["redemptions"]
          Domain::Pricing::Coupon.new(
            id: row["id"], organization_id: row["organization_id"], code: row["code"], kind: row["kind"], value: row["value"],
            valid_from: row["valid_from"]&.getutc, valid_until: row["valid_until"]&.getutc, max_redemptions: row["max_redemptions"],
            redemptions: legacy + active_uses, legacy_redemptions: legacy, total_redemptions: total_uses && (legacy + total_uses),
            min_subtotal_cents: row["min_subtotal_cents"], active: row["active"], description: row["description"],
            created_by: row["created_by"], created_at: row["created_at"]&.getutc, updated_at: row["updated_at"]&.getutc,
            deactivated_at: row["deactivated_at"]&.getutc, lock_version: row["lock_version"]
          )
        end

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

        # Maior desconto negociado vigente: específico do produto ou geral do cliente.
        def negotiated_discount_bps(tx, customer_id, product_id, now)
          tx.query_value(<<~SQL, [tx.tenant_id!, customer_id, product_id, now]).to_i
            SELECT COALESCE(max(discount_bps), 0) FROM customer_price_agreements
             WHERE organization_id = $1 AND customer_id = $2 AND (product_id IS NULL OR product_id = $3)
               AND valid_from <= $4 AND (valid_until IS NULL OR valid_until > $4) AND (ended_at IS NULL OR ended_at > $4)
          SQL
        end

        def active_redemptions(tx, coupon_id, now)
          tx.query_value(<<~SQL, [tx.tenant_id!, coupon_id, now])
            SELECT count(*) FROM coupon_redemptions r
              JOIN reservations v ON v.organization_id = r.organization_id AND v.id = r.reservation_id
             WHERE r.organization_id = $1 AND r.coupon_id = $2 AND #{format(ACTIVE_USE_SQL, now: 3)}
          SQL
        end

        def insert_redemption(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("coupon_id", "reservation_id", "subtotal_cents", "discount_cents", "redeemed_by", "redeemed_at")])
            INSERT INTO coupon_redemptions (id, organization_id, coupon_id, reservation_id, subtotal_cents, discount_cents, redeemed_by, redeemed_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          SQL
        end

        # Condição vigente de maior desconto para o produto: específica do produto ou geral do cliente;
        # em empate, a do produto.
        def applicable_agreement(tx, customer_id, product_id, now)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, customer_id, product_id, now])
            SELECT #{AGREEMENT_COLUMNS}
              FROM customer_price_agreements
             WHERE organization_id = $1 AND customer_id = $2 AND (product_id IS NULL OR product_id = $3)
               AND valid_from <= $4 AND (valid_until IS NULL OR valid_until > $4) AND (ended_at IS NULL OR ended_at > $4)
             ORDER BY discount_bps DESC, (product_id IS NOT NULL) DESC, id
             LIMIT 1
          SQL
          row && PriceAgreementRepository.map(row)
        end

        def fees_by_ids(tx, ids)
          return {} if ids.empty?

          tx.query("SELECT #{FeeRepository::COLUMNS} FROM additional_fees WHERE organization_id = $1 AND id = ANY($2::uuid[])",
                   [tx.tenant_id!, ids.uniq]).to_h { |row| [row["id"], FeeRepository.map(row)] }
        end

        # Inserção direta de cupom (testes e ferramentas); o cadastro usa CouponRepository#insert.
        def insert_coupon(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("code", "kind", "value", "valid_from", "valid_until", "max_redemptions", "min_subtotal_cents", "created_at", "description", "created_by")])
            INSERT INTO coupons (id, organization_id, code, kind, value, valid_from, valid_until, max_redemptions, min_subtotal_cents, created_at,
                                 updated_at, description, created_by)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9, 0), $10, $10, $11, $12)
          SQL
        end

        # Inserção direta de condição (testes e ferramentas); o início padrão é o instante de criação.
        def insert_agreement(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("customer_id", "product_id", "discount_bps", "valid_until", "notes", "created_by", "created_at"), row["valid_from"] || row["created_at"]])
            INSERT INTO customer_price_agreements (id, organization_id, customer_id, product_id, discount_bps, valid_until, notes, created_by,
                                                   created_at, valid_from)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end
      end
    end
  end
end
