# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class TransferRepository
        T = Domain::Transfers
        COLUMNS = "id, organization_id, code, product_id, asset_id, quantity, from_branch_id, to_branch_id, from_pool_id, to_pool_id, status, " \
                  "notes, requested_at, dispatched_at, received_at, cancelled_at, cancellation_reason, version"
        FILTERS = { "active" => "t.status IN ('requested', 'in_transit')", "closed" => "t.status IN ('received', 'cancelled')", "all" => "TRUE" }.freeze

        def insert(tx, transfer, actor_id)
          tx.execute(<<~SQL, [transfer.id, tx.tenant_id!, transfer.code, transfer.product_id, transfer.asset_id, transfer.quantity, transfer.from_branch_id, transfer.to_branch_id, transfer.from_pool_id, transfer.notes, actor_id, transfer.requested_at])
            INSERT INTO transfers (id, organization_id, code, product_id, asset_id, quantity, from_branch_id, to_branch_id, from_pool_id, notes,
                                   requested_by, requested_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
        rescue Domain::Conflict => e
          raise unless e.code.include?("transfers_active_asset_key")

          raise Domain::Conflict.new("o ativo já possui transferência em andamento", code: "transfer_in_progress")
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM transfers WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM transfers WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && map(row)
        end

        def update(tx, transfer, actor_id)
          count = tx.execute(<<~SQL, [tx.tenant_id!, transfer.id, transfer.status, transfer.to_pool_id, transfer.dispatched_at, transfer.received_at, transfer.cancelled_at, transfer.cancellation_reason, actor_id, transfer.version])
            UPDATE transfers
               SET status = $3, to_pool_id = $4, dispatched_at = $5, received_at = $6, cancelled_at = $7, cancellation_reason = $8,
                   dispatched_by = CASE WHEN $3 = 'in_transit' THEN $9::uuid ELSE dispatched_by END,
                   received_by = CASE WHEN $3 = 'received' THEN $9::uuid ELSE received_by END,
                   cancelled_by = CASE WHEN $3 = 'cancelled' THEN $9::uuid ELSE cancelled_by END,
                   version = $10
             WHERE organization_id = $1 AND id = $2 AND version = $10 - 1
          SQL
          raise Domain::Conflict.new("transferência alterada por outra operação", code: "stale_transfer") unless count == 1
        end

        def list(tx, filter: "active", limit: 100)
          tx.query(<<~SQL, [tx.tenant_id!, limit])
            SELECT t.id, t.code, t.status, t.quantity, t.asset_id, t.notes, t.requested_at, t.dispatched_at, t.received_at, t.cancelled_at,
                   t.cancellation_reason, p.name AS product_name, p.sku, a.tag, fb.code AS from_code, fb.name AS from_name,
                   tb.code AS to_code, tb.name AS to_name
              FROM transfers t
              JOIN products p ON p.organization_id = t.organization_id AND p.id = t.product_id
              JOIN branches fb ON fb.organization_id = t.organization_id AND fb.id = t.from_branch_id
              JOIN branches tb ON tb.organization_id = t.organization_id AND tb.id = t.to_branch_id
              LEFT JOIN assets a ON a.organization_id = t.organization_id AND a.id = t.asset_id
             WHERE t.organization_id = $1 AND #{FILTERS.fetch(filter)}
             ORDER BY t.requested_at DESC, t.id LIMIT $2
          SQL
        end

        private

        def map(row)
          T::Transfer.new(**row.transform_keys(&:to_sym), requested_at: row["requested_at"].utc)
        end
      end
    end
  end
end
