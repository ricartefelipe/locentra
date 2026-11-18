# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Consultas e escritas do motor de disponibilidade.
      #
      # Alocações de bloqueios temporários vencidos (status 'held' com hold_expires_at <= agora) não
      # ocupam disponibilidade nas consultas, mesmo antes de a varredura marcá-las como expiradas.
      # Antes de inserir, `release_stale_holds` as libera na própria transação para que a exclusion
      # constraint não as considere.
      class AvailabilityRepository
        AV = Domain::Availability
        LIVE = "(r.id IS NULL OR r.status <> 'held' OR r.hold_expires_at > $%<now>d)"

        def product_specs(tx, ids)
          return {} if ids.empty?

          products = load_products(tx, ids)
          kit_ids = products.values.select(&:kit?).map(&:id)
          components = kit_ids.empty? ? [] : tx.query(<<~SQL, [tx.tenant_id!, kit_ids])
            SELECT kit_id, component_id, quantity FROM kit_components WHERE organization_id = $1 AND kit_id = ANY($2::uuid[]) ORDER BY component_id
          SQL
          missing = components.map { |c| c["component_id"] } - products.keys
          products.merge!(load_products(tx, missing)) unless missing.empty?
          by_kit = components.group_by { |c| c["kit_id"] }
          products.transform_values do |product|
            parts = by_kit.fetch(product.id, []).map { |c| { product_id: c["component_id"], quantity: c["quantity"] } }
            { product: product, spec: AV::ProductSpec.new(id: product.id, tracking: product.tracking, components: parts) }
          end
        end

        def active_product_ids(tx)
          tx.query("SELECT id FROM products WHERE organization_id = $1 AND active ORDER BY lower(name) LIMIT 200",
                   [tx.tenant_id!]).map do |r|
            r["id"]
          end
        end

        # SKU (normalizado em maiúsculas) => id, somente para SKUs existentes na organização.
        def product_ids_by_sku(tx, skus)
          tx.query("SELECT sku, id FROM products WHERE organization_id = $1 AND sku = ANY($2::text[])", [tx.tenant_id!, skus])
            .to_h { |row| [row["sku"], row["id"]] }
        end

        # Lock dos estoques quantitativos em ordem de id: evita deadlock entre transações concorrentes.
        def lock_pools(tx, branch_id, product_ids)
          return {} if product_ids.empty?

          tx.query(<<~SQL, [tx.tenant_id!, branch_id, product_ids]).to_h { |row| [row["product_id"], row] }
            SELECT id, product_id, total_quantity FROM stock_pools
             WHERE organization_id = $1 AND branch_id = $2 AND product_id = ANY($3::uuid[])
             ORDER BY id FOR UPDATE
          SQL
        end

        def pools(tx, branch_id, product_ids)
          return {} if product_ids.empty?

          tx.query(<<~SQL, [tx.tenant_id!, branch_id, product_ids]).to_h { |row| [row["product_id"], row] }
            SELECT id, product_id, total_quantity FROM stock_pools
             WHERE organization_id = $1 AND branch_id = $2 AND product_id = ANY($3::uuid[])
          SQL
        end

        def lock_pool_by_id(tx, id)
          tx.query_one("SELECT id, product_id, total_quantity FROM stock_pools WHERE organization_id = $1 AND id = $2 FOR UPDATE",
                       [tx.tenant_id!, id])
        end

        def pool_capacity(tx, pool_id)
          tx.query_value("SELECT total_quantity FROM stock_pools WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, pool_id])
        end

        # Expira, na transação corrente, bloqueios vencidos que ainda ocupam os produtos informados.
        def release_stale_holds(tx, product_ids, now)
          return [] if product_ids.empty?

          ids = tx.query(<<~SQL, [tx.tenant_id!, now, product_ids]).map { |row| row["id"] }
            UPDATE reservations r SET status = 'expired', expired_at = $2, version = version + 1, updated_at = $2
             WHERE r.organization_id = $1 AND r.status = 'held' AND r.hold_expires_at <= $2
               AND (EXISTS (SELECT 1 FROM asset_allocations a WHERE a.organization_id = $1 AND a.reservation_id = r.id AND a.active AND a.product_id = ANY($3::uuid[]))
                 OR EXISTS (SELECT 1 FROM stock_allocations s WHERE s.organization_id = $1 AND s.reservation_id = r.id AND s.active AND s.product_id = ANY($3::uuid[])))
            RETURNING r.id
          SQL
          deactivate(tx, ids, now) unless ids.empty?
          ids
        end

        def deactivate(tx, reservation_ids, now)
          %w[asset_allocations stock_allocations].each do |table|
            tx.execute(<<~SQL, [tx.tenant_id!, reservation_ids, now])
              UPDATE #{table} SET active = false, released_at = $3 WHERE organization_id = $1 AND reservation_id = ANY($2::uuid[]) AND active
            SQL
          end
        end

        # Ocupações recortadas à janela consultada: bloqueios sem fim definido ([início, ∞), usados em
        # inspeções e manutenções de estoque) entram com o fim da janela.
        def stock_occupancies(tx, pool_id, window, now)
          tx.query(<<~SQL, [tx.tenant_id!, pool_id, window, now]).map { |row| occupancy(row) }
            SELECT lower(s.period * $3::tstzrange) AS starts_at, upper(s.period * $3::tstzrange) AS ends_at, s.quantity
              FROM stock_allocations s LEFT JOIN reservations r ON r.organization_id = s.organization_id AND r.id = s.reservation_id
             WHERE s.organization_id = $1 AND s.stock_pool_id = $2 AND s.active AND s.period && $3::tstzrange
               AND #{format(LIVE, now: 4)}
          SQL
        end

        def asset_schedules(tx, product_id, branch_id, window, now)
          assets = tx.query(<<~SQL, [tx.tenant_id!, product_id, branch_id])
            SELECT id, status, unavailable_until FROM assets WHERE organization_id = $1 AND product_id = $2 AND branch_id = $3 ORDER BY id
          SQL
          return [] if assets.empty?

          busy = tx.query(<<~SQL, [tx.tenant_id!, assets.map { |a| a["id"] }, window, now]).group_by { |row| row["asset_id"] }
            SELECT a.asset_id, lower(a.period) AS starts_at, upper(a.period) AS ends_at
              FROM asset_allocations a LEFT JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND a.asset_id = ANY($2::uuid[]) AND a.active AND a.period && $3::tstzrange
               AND #{format(LIVE, now: 4)}
          SQL
          assets.map do |asset|
            periods = busy.fetch(asset["id"], []).map { |row| Domain::Period.new(row["starts_at"], row["ends_at"]) }
            AV::AssetSchedule.new(asset_id: asset["id"], busy: periods,
                                  allocatable: !Domain::Catalog::NOT_ALLOCATABLE.include?(asset["status"]),
                                  operationally_blocked: Domain::Catalog::OPERATIONALLY_BLOCKED.include?(asset["status"]),
                                  unavailable_until: asset["unavailable_until"]&.utc)
          end
        end

        def asset_allocatable?(tx, asset_id, window)
          row = tx.query_one("SELECT status, unavailable_until FROM assets WHERE organization_id = $1 AND id = $2",
                             [tx.tenant_id!, asset_id])
          return false unless row

          AV::AssetSchedule.new(asset_id: asset_id, allocatable: !Domain::Catalog::NOT_ALLOCATABLE.include?(row["status"]),
                                operationally_blocked: Domain::Catalog::OPERATIONALLY_BLOCKED.include?(row["status"]),
                                unavailable_until: row["unavailable_until"]&.utc).free?(window)
        end

        def insert_asset_allocation(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "asset_id", "product_id", "reservation_id", "reservation_item_id", "kind", "reason", "period", "created_by", "created_at"))
            INSERT INTO asset_allocations (id, organization_id, asset_id, product_id, reservation_id, reservation_item_id, kind, reason, period, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::tstzrange, $10, $11)
          SQL
        end

        def insert_stock_allocation(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "stock_pool_id", "product_id", "reservation_id", "reservation_item_id", "kind", "reason", "quantity", "period", "created_by", "created_at"))
            INSERT INTO stock_allocations (id, organization_id, stock_pool_id, product_id, reservation_id, reservation_item_id, kind, reason,
                                           quantity, period, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::tstzrange, $11, $12)
          SQL
        end

        def active_allocations(tx, reservation_id)
          assets = tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT id, asset_id, product_id, reservation_item_id, lower(period) AS starts_at, upper(period) AS ends_at
              FROM asset_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active ORDER BY id
          SQL
          stock = tx.query(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT id, stock_pool_id, product_id, reservation_item_id, quantity, lower(period) AS starts_at, upper(period) AS ends_at
              FROM stock_allocations WHERE organization_id = $1 AND reservation_id = $2 AND active ORDER BY id
          SQL
          { assets: assets, stock: stock }
        end

        def reassign_asset_allocation(tx, allocation_id, asset_id)
          tx.execute("UPDATE asset_allocations SET asset_id = $3 WHERE organization_id = $1 AND id = $2 AND active",
                     [tx.tenant_id!, allocation_id, asset_id])
        end

        # Extensão: o fim passa a ser o da nova janela e o início nunca é adiado, para manter o trecho
        # antecipado por uma retirada antes do início da reserva.
        def extend_asset_allocation(tx, allocation_id, window)
          tx.execute(<<~SQL, [tx.tenant_id!, allocation_id, window])
            UPDATE asset_allocations SET period = tstzrange(LEAST(lower(period), lower($3::tstzrange)), upper($3::tstzrange), '[)')
             WHERE organization_id = $1 AND id = $2 AND active
          SQL
        end

        def extend_stock_allocation(tx, allocation_id, window)
          tx.execute(<<~SQL, [tx.tenant_id!, allocation_id, window])
            UPDATE stock_allocations SET period = tstzrange(LEAST(lower(period), lower($3::tstzrange)), upper($3::tstzrange), '[)')
             WHERE organization_id = $1 AND id = $2 AND active
          SQL
        end

        def conflicting_reservation_code(tx, asset_id, window, exclude_reservation_id)
          tx.query_value(<<~SQL, [tx.tenant_id!, asset_id, window, exclude_reservation_id])
            SELECT COALESCE(r.code, 'bloqueio') FROM asset_allocations a LEFT JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND a.asset_id = $2 AND a.active AND a.period && $3::tstzrange
               AND (a.reservation_id IS NULL OR a.reservation_id <> $4) LIMIT 1
          SQL
        end

        # Alocações de reservas ainda não retiradas que podem ser realocadas para outra unidade.
        # Bloqueios temporários vencidos não ocupam disponibilidade e são ignorados.
        def future_reservation_allocations(tx, asset_id, now)
          tx.query(<<~SQL, [tx.tenant_id!, asset_id, now])
            SELECT a.id, a.asset_id, a.product_id, lower(a.period) AS starts_at, upper(a.period) AS ends_at, r.id AS reservation_id,
                   r.code AS reservation_code, r.starts_at AS rental_starts_at, r.ends_at AS rental_ends_at
              FROM asset_allocations a JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND a.asset_id = $2 AND a.active AND upper(a.period) > $3
               AND (r.status = 'confirmed' OR (r.status = 'held' AND r.hold_expires_at > $3))
             ORDER BY lower(a.period)
          SQL
        end

        def asset_allocations(tx, asset_id, limit: 50)
          tx.query(<<~SQL, [tx.tenant_id!, asset_id, limit])
            SELECT a.id, a.kind, a.reason, a.active, lower(a.period) AS starts_at, upper(a.period) AS ends_at, r.id AS reservation_id,
                   r.code AS reservation_code, r.status AS reservation_status
              FROM asset_allocations a LEFT JOIN reservations r ON r.organization_id = a.organization_id AND r.id = a.reservation_id
             WHERE a.organization_id = $1 AND a.asset_id = $2 ORDER BY lower(a.period) DESC LIMIT $3
          SQL
        end

        private

        def load_products(tx, ids)
          tx.query("SELECT #{CatalogRepository::PRODUCT_COLUMNS} FROM products WHERE organization_id = $1 AND id = ANY($2::uuid[])",
                   [tx.tenant_id!, ids])
            .to_h do |row|
            [row["id"], CatalogRepository.map_product(row)]
          end
        end

        def occupancy(row)
          AV::Occupancy.new(period: Domain::Period.new(row["starts_at"], row["ends_at"]), quantity: row["quantity"])
        end
      end
    end
  end
end
