# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Cadastro de cupons e consulta do livro de usos. Toda consulta filtra explicitamente pela
      # organização do contexto, além da RLS; ordenações por allowlist.
      class CouponRepository
        COLUMNS = PricingRepository::COUPON_COLUMNS
        SORTS = { "code" => "c.code ASC, c.id", "-created_at" => "c.created_at DESC, c.id",
                  "valid_until" => "c.valid_until ASC NULLS LAST, c.code" }.freeze
        # Mesma precedência de Domain::Pricing::Coupon#status; usos ativos = contador legado + usos ativos do livro.
        STATUS_SQL = <<~SQL
          CASE WHEN NOT c.active THEN 'inactive'
               WHEN c.valid_until IS NOT NULL AND c.valid_until <= $%<now>d THEN 'expired'
               WHEN c.valid_from IS NOT NULL AND c.valid_from > $%<now>d THEN 'scheduled'
               WHEN c.max_redemptions IS NOT NULL AND c.redemptions + (%<active>s) >= c.max_redemptions THEN 'exhausted'
               ELSE 'active' END
        SQL
        # Usos ativos e totais do cupom `c` no instante $n, em subconsulta lateral.
        USES_SQL = <<~SQL
          SELECT count(*) FILTER (WHERE %<active>s) AS active_uses, count(*) AS total_uses
            FROM coupon_redemptions r JOIN reservations v ON v.organization_id = r.organization_id AND v.id = r.reservation_id
           WHERE r.organization_id = c.organization_id AND r.coupon_id = c.id
        SQL

        def insert(tx, coupon)
          tx.execute(<<~SQL, [coupon.id, tx.tenant_id!, coupon.code, coupon.kind, coupon.value, coupon.description, coupon.valid_from, coupon.valid_until, coupon.max_redemptions, coupon.min_subtotal_cents, coupon.created_by, coupon.created_at])
            INSERT INTO coupons (id, organization_id, code, kind, value, description, valid_from, valid_until, max_redemptions, min_subtotal_cents,
                                 created_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)
            ON CONFLICT (organization_id, code) DO NOTHING
          SQL
        end

        # Controle otimista: grava somente se a versão lida ainda é a atual.
        def update(tx, coupon, expected_lock_version)
          tx.execute(<<~SQL, [tx.tenant_id!, coupon.id, coupon.description, coupon.valid_from, coupon.valid_until, coupon.max_redemptions, coupon.min_subtotal_cents, coupon.active, coupon.deactivated_at, coupon.updated_at, coupon.lock_version, expected_lock_version])
            UPDATE coupons SET description = $3, valid_from = $4, valid_until = $5, max_redemptions = $6, min_subtotal_cents = $7, active = $8,
                               deactivated_at = $9, updated_at = $10, lock_version = $11
             WHERE organization_id = $1 AND id = $2 AND lock_version = $12
          SQL
        end

        def find(tx, id, now:) = load(tx, "id = $2", id, now, lock: false)
        def find_by_code(tx, code, now:) = load(tx, "code = $2", code, now, lock: false)
        def lock(tx, id, now:) = load(tx, "id = $2", id, now, lock: true)
        def lock_by_code(tx, code, now:) = load(tx, "code = $2", code, now, lock: true)

        def ever_redeemed?(tx, coupon_id)
          !tx.query_one("SELECT 1 FROM coupon_redemptions WHERE organization_id = $1 AND coupon_id = $2 LIMIT 1", [tx.tenant_id!, coupon_id]).nil?
        end

        def delete(tx, coupon_id)
          tx.execute("DELETE FROM coupons WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, coupon_id])
        end

        # Busca por trecho do código (prefixo, em maiúsculas) ou da descrição, com filtro de situação
        # calculado no instante informado. Devolve [[[Coupon, situação]], total].
        def search(tx, status:, search:, sort:, limit:, offset:, now:)
          order = SORTS.fetch(sort) { raise Domain::ValidationError.field("ordenacao", "inválida") }
          params = [tx.tenant_id!, now]
          conditions = ["c.organization_id = $1"]
          unless search.to_s.empty?
            params << "#{escape_like(search.upcase)}%" << "%#{escape_like(search.downcase)}%"
            conditions << "(c.code LIKE $#{params.size - 1} ESCAPE '\\' OR lower(COALESCE(c.description, '')) LIKE $#{params.size} ESCAPE '\\')"
          end
          listed = "SELECT * FROM (#{listing_sql(conditions.join(" AND "))}) c"
          if status
            params << status
            listed += " WHERE c.status = $#{params.size}"
          end
          total = tx.query_value("SELECT count(*) FROM (#{listed}) s", params)
          rows = tx.query("#{listed} ORDER BY #{order} LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}", params + [limit, offset])
          [rows.map { |row| [map(row), row["status"]] }, total]
        end

        # Usos do cupom, mais recentes primeiro. O código da reserva exige `reservation_refs` e o nome do
        # cliente, `customer_names` (escopos do ator); sem eles, as colunas vêm nulas.
        def redemptions(tx, coupon_id, limit:, offset:, now:, customer_names:, reservation_refs:)
          total = tx.query_value("SELECT count(*) FROM coupon_redemptions WHERE organization_id = $1 AND coupon_id = $2", [tx.tenant_id!, coupon_id])
          rows = tx.query(<<~SQL, [tx.tenant_id!, coupon_id, limit, offset, customer_names, reservation_refs, now])
            SELECT r.id, r.reservation_id, r.subtotal_cents, r.discount_cents, r.redeemed_by, r.redeemed_at,
                   CASE WHEN $6 THEN v.code END AS reservation_code, v.status AS reservation_status, v.hold_expires_at, v.cancelled_at,
                   v.expired_at, CASE WHEN $5 THEN c.name END AS customer_name, #{format(PricingRepository::ACTIVE_USE_SQL, now: 7)} AS active
              FROM coupon_redemptions r
              JOIN reservations v ON v.organization_id = r.organization_id AND v.id = r.reservation_id
              JOIN customers c ON c.organization_id = v.organization_id AND c.id = v.customer_id
             WHERE r.organization_id = $1 AND r.coupon_id = $2
             ORDER BY r.redeemed_at DESC, r.id LIMIT $3 OFFSET $4
          SQL
          [rows, total]
        end

        include ActorNames

        def map(row)
          PricingRepository.map_coupon(row, active_uses: row["active_uses"], total_uses: row["total_uses"])
        end

        private

        def listing_sql(where)
          active = format(PricingRepository::ACTIVE_USE_SQL, now: 2)
          <<~SQL
            SELECT #{COLUMNS.split(", ").map { |column| "c.#{column}" }.join(", ")}, u.active_uses, u.total_uses,
                   #{format(STATUS_SQL, now: 2, active: "u.active_uses")} AS status
              FROM coupons c CROSS JOIN LATERAL (#{format(USES_SQL, active: active)}) u
             WHERE #{where}
          SQL
        end

        def load(tx, condition, value, now, lock:)
          row = tx.query_one("SELECT #{COLUMNS} FROM coupons WHERE organization_id = $1 AND #{condition} #{"FOR UPDATE" if lock}",
                             [tx.tenant_id!, value])
          return nil unless row

          uses = tx.query_one(<<~SQL, [tx.tenant_id!, row["id"], now])
            SELECT count(*) FILTER (WHERE #{format(PricingRepository::ACTIVE_USE_SQL, now: 3)}) AS active_uses, count(*) AS total_uses
              FROM coupon_redemptions r JOIN reservations v ON v.organization_id = r.organization_id AND v.id = r.reservation_id
             WHERE r.organization_id = $1 AND r.coupon_id = $2
          SQL
          PricingRepository.map_coupon(row, active_uses: uses["active_uses"], total_uses: uses["total_uses"])
        end

        def escape_like(text)
          text.gsub(/[\\%_]/) { |char| "\\#{char}" }
        end
      end
    end
  end
end
