# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class CatalogRepository
        K = Domain::Catalog
        PRODUCT_COLUMNS = "id, organization_id, sku, name, description, category, tracking, buffer_before_minutes, buffer_after_minutes, " \
                          "deposit_cents, replacement_cost_cents, pricing, active"
        ASSET_COLUMNS = "id, organization_id, product_id, branch_id, tag, serial_number, condition, status, unavailable_until, " \
                        "acquisition_cost_cents, acquired_on, notes, version"

        def insert_product(tx, product, now)
          tx.execute(<<~SQL, [product.id, product.organization_id, product.sku, product.name, product.description, product.category, product.tracking, product.buffer_before_minutes, product.buffer_after_minutes, product.deposit.cents, product.replacement_cost.cents, product.pricing, now])
            INSERT INTO products (id, organization_id, sku, name, description, category, tracking, buffer_before_minutes, buffer_after_minutes,
                                  deposit_cents, replacement_cost_cents, pricing, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13)
          SQL
        end

        def sku_taken?(tx, sku)
          !tx.query_one("SELECT 1 FROM products WHERE organization_id = $1 AND sku = $2", [tx.tenant_id!, sku]).nil?
        end

        def find_product(tx, id)
          row = tx.query_one("SELECT #{PRODUCT_COLUMNS} FROM products WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && self.class.map_product(row)
        end

        def find_product_by_sku(tx, sku)
          row = tx.query_one("SELECT #{PRODUCT_COLUMNS} FROM products WHERE organization_id = $1 AND sku = $2", [tx.tenant_id!, sku])
          row && self.class.map_product(row)
        end

        def lock_product(tx, id)
          row = tx.query_one("SELECT #{PRODUCT_COLUMNS} FROM products WHERE organization_id = $1 AND id = $2 FOR UPDATE",
                             [tx.tenant_id!, id])
          row && self.class.map_product(row)
        end

        def update_product_pricing(tx, product, now)
          tx.execute("UPDATE products SET pricing = $3, deposit_cents = $4, updated_at = $5 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, product.id, product.pricing, product.deposit.cents, now])
        end

        def specs_by_id(tx, ids)
          return {} if ids.empty?

          tx.query("SELECT id, tracking FROM products WHERE organization_id = $1 AND id = ANY($2::uuid[])", [tx.tenant_id!, ids])
            .to_h { |row| [row["id"], Domain::Availability::ProductSpec.new(id: row["id"], tracking: row["tracking"])] }
        end

        def replace_kit_components(tx, kit_id, components)
          tx.execute("DELETE FROM kit_components WHERE organization_id = $1 AND kit_id = $2", [tx.tenant_id!, kit_id])
          components.each do |component|
            tx.execute(<<~SQL, [tx.tenant_id!, kit_id, component[:product_id], component[:tracking], component[:quantity]])
              INSERT INTO kit_components (organization_id, kit_id, component_id, component_tracking, quantity) VALUES ($1, $2, $3, $4, $5)
            SQL
          end
        end

        def kit_components(tx, kit_id)
          tx.query(<<~SQL, [tx.tenant_id!, kit_id])
            SELECT k.component_id AS product_id, k.quantity, p.sku, p.name, p.tracking
              FROM kit_components k JOIN products p ON p.organization_id = k.organization_id AND p.id = k.component_id
             WHERE k.organization_id = $1 AND k.kit_id = $2 ORDER BY p.name
          SQL
        end

        def search_products(tx, search:, tracking:, limit:, offset:)
          conditions = ["organization_id = $1"]
          params = [tx.tenant_id!]
          unless search.empty?
            params << "%#{search.downcase.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
            conditions << "(lower(name) LIKE $#{params.size} ESCAPE '\\' OR lower(sku) LIKE $#{params.size} ESCAPE '\\')"
          end
          if tracking
            raise Domain::ValidationError.field("rastreamento", "inválido") unless K::TRACKING.key?(tracking)

            params << tracking
            conditions << "tracking = $#{params.size}"
          end
          where = conditions.join(" AND ")
          total = tx.query_value("SELECT count(*) FROM products WHERE #{where}", params)
          sql = "SELECT #{PRODUCT_COLUMNS} FROM products WHERE #{where} ORDER BY lower(name), id " \
                "LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}"
          rows = tx.query(sql, params + [limit, offset])
          [rows.map { |row| self.class.map_product(row) }, total]
        end

        def branch_exists?(tx, id)
          !tx.query_one("SELECT 1 FROM branches WHERE organization_id = $1 AND id = $2 AND active", [tx.tenant_id!, id]).nil?
        end

        def insert_asset(tx, asset, now)
          tx.execute(<<~SQL, [asset.id, asset.organization_id, asset.product_id, asset.branch_id, asset.tag, asset.serial_number, asset.condition, asset.status, asset.acquisition_cost.cents, asset.acquired_on, asset.notes, now])
            INSERT INTO assets (id, organization_id, product_id, branch_id, tag, serial_number, condition, status, acquisition_cost_cents,
                                acquired_on, notes, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)
          SQL
        end

        def tag_taken?(tx, tag)
          !tx.query_one("SELECT 1 FROM assets WHERE organization_id = $1 AND tag = $2", [tx.tenant_id!, tag]).nil?
        end

        def find_asset(tx, id)
          row = tx.query_one("SELECT #{ASSET_COLUMNS} FROM assets WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && self.class.map_asset(row)
        end

        def find_asset_by_tag(tx, tag)
          row = tx.query_one("SELECT #{ASSET_COLUMNS} FROM assets WHERE organization_id = $1 AND tag = $2",
                             [tx.tenant_id!, tag.to_s.upcase])
          row && self.class.map_asset(row)
        end

        def lock_asset(tx, id)
          row = tx.query_one("SELECT #{ASSET_COLUMNS} FROM assets WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && self.class.map_asset(row)
        end

        # Atualização com controle otimista de versão (além do lock de linha).
        def update_asset_status(tx, asset, now)
          count = tx.execute(<<~SQL, [tx.tenant_id!, asset.id, asset.status, asset.unavailable_until, asset.condition, asset.version, asset.branch_id, now])
            UPDATE assets SET status = $3, unavailable_until = $4, condition = $5, version = $6, branch_id = $7, updated_at = $8
             WHERE organization_id = $1 AND id = $2 AND version = $6 - 1
          SQL
          raise Domain::Conflict.new("ativo alterado por outra operação", code: "stale_asset") unless count == 1
        end

        def insert_asset_event(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("asset_id", "kind", "from_status", "to_status", "from_branch_id", "to_branch_id", "actor_id", "reference_type", "reference_id", "notes", "occurred_at")])
            INSERT INTO asset_events (id, organization_id, asset_id, kind, from_status, to_status, from_branch_id, to_branch_id, actor_id,
                                      reference_type, reference_id, notes, occurred_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
          SQL
        end

        # Inspeção pendente ou ordem de manutenção ativa que controla a situação do ativo.
        def operational_hold(tx, asset_id)
          tx.query_value(<<~SQL, [tx.tenant_id!, asset_id])
            SELECT CASE
                     WHEN EXISTS (SELECT 1 FROM inspections WHERE organization_id = $1 AND asset_id = $2 AND status = 'pending') THEN 'inspection'
                     WHEN EXISTS (SELECT 1 FROM maintenance_orders WHERE organization_id = $1 AND asset_id = $2 AND status IN ('open', 'in_progress'))
                       THEN 'maintenance'
                   END
          SQL
        end

        def asset_events(tx, asset_id, limit: 100)
          tx.query(<<~SQL, [tx.tenant_id!, asset_id, limit])
            SELECT kind, from_status, to_status, from_branch_id, to_branch_id, actor_id, reference_type, reference_id, notes, occurred_at
              FROM asset_events WHERE organization_id = $1 AND asset_id = $2 ORDER BY occurred_at DESC, id DESC LIMIT $3
          SQL
        end

        def assets_for_product(tx, product_id)
          tx.query(<<~SQL, [tx.tenant_id!, product_id]).map { |row| self.class.map_asset(row) }
            SELECT #{ASSET_COLUMNS} FROM assets WHERE organization_id = $1 AND product_id = $2 ORDER BY tag
          SQL
        end

        def search_assets(tx, branch_id: nil, status: nil, limit: 100)
          params = [tx.tenant_id!]
          conditions = ["a.organization_id = $1"]
          if branch_id
            params << branch_id
            conditions << "a.branch_id = $#{params.size}"
          end
          if status
            raise Domain::ValidationError.field("situacao", "inválida") unless K::ASSET_STATUSES.key?(status)

            params << status
            conditions << "a.status = $#{params.size}"
          end
          params << limit
          tx.query(<<~SQL, params)
            SELECT a.id, a.tag, a.serial_number, a.status, a.condition, a.branch_id, a.unavailable_until, p.name AS product_name, p.sku, b.code AS branch_code
              FROM assets a
              JOIN products p ON p.organization_id = a.organization_id AND p.id = a.product_id
              JOIN branches b ON b.organization_id = a.organization_id AND b.id = a.branch_id
             WHERE #{conditions.join(" AND ")}
             ORDER BY a.tag LIMIT $#{params.size}
          SQL
        end

        def lock_or_create_pool(tx, new_id, product_id, branch_id, now)
          tx.execute(<<~SQL, [new_id, tx.tenant_id!, product_id, branch_id, now])
            INSERT INTO stock_pools (id, organization_id, product_id, branch_id, total_quantity, created_at, updated_at)
            VALUES ($1, $2, $3, $4, 0, $5, $5) ON CONFLICT (organization_id, product_id, branch_id) DO NOTHING
          SQL
          row = tx.query_one(<<~SQL, [tx.tenant_id!, product_id, branch_id])
            SELECT id, organization_id, product_id, branch_id, total_quantity FROM stock_pools
             WHERE organization_id = $1 AND product_id = $2 AND branch_id = $3 FOR UPDATE
          SQL
          K::StockPool.new(**row.transform_keys(&:to_sym))
        end

        def update_pool_total(tx, pool, now)
          tx.execute("UPDATE stock_pools SET total_quantity = $3, updated_at = $4 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, pool.id, pool.total_quantity, now])
        end

        def insert_stock_movement(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("stock_pool_id", "kind", "quantity_delta", "reason", "actor_id", "reference_type", "reference_id", "occurred_at")])
            INSERT INTO stock_movements (id, organization_id, stock_pool_id, kind, quantity_delta, reason, actor_id, reference_type, reference_id, occurred_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end

        def pools_for_product(tx, product_id)
          tx.query(<<~SQL, [tx.tenant_id!, product_id])
            SELECT s.id, s.branch_id, s.total_quantity, b.code AS branch_code, b.name AS branch_name
              FROM stock_pools s JOIN branches b ON b.organization_id = s.organization_id AND b.id = s.branch_id
             WHERE s.organization_id = $1 AND s.product_id = $2 ORDER BY b.code
          SQL
        end

        def stock_movements(tx, pool_id, limit: 50)
          tx.query(<<~SQL, [tx.tenant_id!, pool_id, limit])
            SELECT kind, quantity_delta, reason, actor_id, reference_type, reference_id, occurred_at FROM stock_movements
             WHERE organization_id = $1 AND stock_pool_id = $2 ORDER BY occurred_at DESC LIMIT $3
          SQL
        end

        def self.map_product(row)
          K::Product.new(id: row["id"], organization_id: row["organization_id"], sku: row["sku"], name: row["name"], description: row["description"],
                         category: row["category"], tracking: row["tracking"], buffer_before_minutes: row["buffer_before_minutes"],
                         buffer_after_minutes: row["buffer_after_minutes"], deposit: Domain::Money.new(row["deposit_cents"]),
                         replacement_cost: Domain::Money.new(row["replacement_cost_cents"]), pricing: row["pricing"] || {}, active: row["active"])
        end

        def self.map_asset(row)
          K::Asset.new(id: row["id"], organization_id: row["organization_id"], product_id: row["product_id"], branch_id: row["branch_id"],
                       tag: row["tag"], serial_number: row["serial_number"], condition: row["condition"], status: row["status"],
                       unavailable_until: row["unavailable_until"]&.utc, acquisition_cost: Domain::Money.new(row["acquisition_cost_cents"]),
                       acquired_on: row["acquired_on"], notes: row["notes"], version: row["version"])
        end
      end
    end
  end
end
