# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Trilha de auditoria: somente inserção (UPDATE/DELETE revogados no banco).
      class AuditRepository
        FILTERS = { "action" => "e.action = $%d", "resource_type" => "e.resource_type = $%d", "actor_id" => "e.actor_id = $%d" }.freeze

        def insert(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "actor_type", "actor_id", "action", "resource_type", "resource_id", "request_id", "ip", "details", "occurred_at"))
            INSERT INTO audit_events (id, organization_id, actor_type, actor_id, action, resource_type, resource_id, request_id, ip, details, occurred_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          SQL
        end

        def search(tx, filters:, limit:, offset:)
          params = [tx.tenant_id!]
          conditions = ["e.organization_id = $1"]
          filters.each do |key, value|
            fragment = FILTERS[key.to_s]
            next if fragment.nil? || value.to_s.empty?

            params << value.to_s
            conditions << format(fragment, params.size)
          end
          where = conditions.join(" AND ")
          total = tx.query_value("SELECT count(*) FROM audit_events e WHERE #{where}", params)
          rows = tx.query(<<~SQL, params + [limit, offset])
            SELECT e.id, e.actor_type, e.actor_id, e.action, e.resource_type, e.resource_id, e.request_id, e.ip, e.details, e.occurred_at,
                   u.name AS actor_name
              FROM audit_events e LEFT JOIN users u ON u.id = e.actor_id
             WHERE #{where}
             ORDER BY e.occurred_at DESC, e.id DESC LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}
          SQL
          [rows, total]
        end

        def for_resource(tx, resource_type, resource_id, limit: 50)
          tx.query(<<~SQL, [tx.tenant_id!, resource_type, resource_id, limit])
            SELECT e.action, e.actor_type, e.details, e.occurred_at, u.name AS actor_name
              FROM audit_events e LEFT JOIN users u ON u.id = e.actor_id
             WHERE e.organization_id = $1 AND e.resource_type = $2 AND e.resource_id = $3
             ORDER BY e.occurred_at DESC LIMIT $4
          SQL
        end
      end
    end
  end
end
