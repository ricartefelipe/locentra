# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Alertas de reservas. A chave de deduplicação garante um único alerta por situação, mesmo com
      # execuções repetidas ou concorrentes do detector.
      class AlertRepository
        AL = Domain::Alerts
        COLUMNS = "id, reservation_id, kind, related_reservation_id, asset_id, stock_pool_id, status, details, created_at, resolved_at, resolution"

        # Retorna verdadeiro somente quando o alerta é novo.
        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("reservation_id", "kind", "related_reservation_id", "asset_id", "stock_pool_id", "dedup_key", "details", "created_at")]) == 1
            INSERT INTO reservation_alerts (id, organization_id, reservation_id, kind, related_reservation_id, asset_id, stock_pool_id, dedup_key,
                                            details, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (organization_id, dedup_key) DO NOTHING
          SQL
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM reservation_alerts WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && map(row)
        end

        def resolve(tx, alert, actor_id)
          count = tx.execute(<<~SQL, [tx.tenant_id!, alert.id, alert.resolution, alert.resolved_at, actor_id])
            UPDATE reservation_alerts SET status = 'resolved', resolution = $3, resolved_at = $4, resolved_by = $5
             WHERE organization_id = $1 AND id = $2 AND status = 'open'
          SQL
          raise Domain::Conflict.new("alerta já resolvido", code: "alert_resolved") unless count == 1
        end

        # Resolução automática registrada pelo sistema (devolução concluída, prazo estendido).
        def resolve_open(tx, reservation_id:, kinds:, resolution:, now:, related: false)
          column = related ? "related_reservation_id" : "reservation_id"
          tx.execute(<<~SQL, [tx.tenant_id!, reservation_id, kinds, resolution, now])
            UPDATE reservation_alerts SET status = 'resolved', resolution = $4, resolved_at = $5
             WHERE organization_id = $1 AND #{column} = $2 AND kind = ANY($3::text[]) AND status = 'open'
          SQL
        end

        # Alertas abertos da reserva com outra chave (por exemplo, atraso de um fim previsto anterior).
        def resolve_superseded(tx, reservation_id:, kind:, keep_key:, resolution:, now:)
          tx.execute(<<~SQL, [tx.tenant_id!, reservation_id, kind, keep_key, resolution, now])
            UPDATE reservation_alerts SET status = 'resolved', resolution = $5, resolved_at = $6
             WHERE organization_id = $1 AND reservation_id = $2 AND kind = $3 AND status = 'open' AND dedup_key <> $4
          SQL
        end

        def list(tx, status: "open", limit: 100, reservation_id: nil)
          tx.query(<<~SQL, [tx.tenant_id!, status, limit, reservation_id])
            SELECT al.id, al.kind, al.status, al.details, al.created_at, al.resolved_at, al.resolution, al.reservation_id, al.related_reservation_id,
                   r.code AS reservation_code, r.starts_at, rel.code AS related_code, a.tag, c.name AS customer_name, u.name AS resolved_by_name
              FROM reservation_alerts al
              JOIN reservations r ON r.organization_id = al.organization_id AND r.id = al.reservation_id
              JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id
              LEFT JOIN reservations rel ON rel.organization_id = al.organization_id AND rel.id = al.related_reservation_id
              LEFT JOIN assets a ON a.organization_id = al.organization_id AND a.id = al.asset_id
              LEFT JOIN users u ON u.id = al.resolved_by
             WHERE al.organization_id = $1 AND al.status = $2
               AND ($4::uuid IS NULL OR al.reservation_id = $4::uuid OR al.related_reservation_id = $4::uuid)
             ORDER BY al.created_at DESC, al.id LIMIT $3
          SQL
        end

        # Lista paginada da API: situação, tipo opcional e reserva opcional (a própria ou a relacionada),
        # com o total do filtro. Atendida pelos índices reservation_alerts_open_idx, _reservation_idx e
        # _related_idx.
        def search(tx, status:, kind:, reservation_id:, limit:, offset:)
          params = [tx.tenant_id!, status, kind, reservation_id]
          where = <<~SQL
            organization_id = $1 AND status = $2 AND ($3::text IS NULL OR kind = $3)
              AND ($4::uuid IS NULL OR reservation_id = $4::uuid OR related_reservation_id = $4::uuid)
          SQL
          total = tx.query_value("SELECT count(*) FROM reservation_alerts WHERE #{where}", params)
          rows = tx.query(<<~SQL, params + [limit, offset])
            SELECT #{COLUMNS} FROM reservation_alerts WHERE #{where}
             ORDER BY created_at DESC, id LIMIT $5 OFFSET $6
          SQL
          [rows.map { |row| map(row) }, total]
        end

        private

        def map(row)
          AL::Alert.new(**row.transform_keys(&:to_sym))
        end
      end

      # Consultas do painel de operação e do detector de atrasos.
      class OperationsRepository
        RES = ReservationRepository::COLUMNS.split(", ").map { |c| "r.#{c}" }.join(", ")

        # Reservas em andamento vencidas com itens pendentes, em lotes paginados por (fim previsto, id):
        # `after` é o par da última reserva do lote anterior. SKIP LOCKED ignora reservas em devolução.
        def lock_overdue(tx, now, limit, after: nil)
          params = [tx.tenant_id!, now, limit, after&.first, after&.last]
          tx.query(<<~SQL, params).map { |row| [ReservationRepository.map(row), row["overdue_since"]] }
            SELECT #{RES}, r.overdue_since FROM reservations r
             WHERE r.organization_id = $1 AND r.status = 'in_progress' AND r.ends_at <= $2
               AND ($4::timestamptz IS NULL OR (r.ends_at, r.id) > ($4::timestamptz, $5::uuid))
               AND EXISTS (SELECT 1 FROM pickup_lines l
                            WHERE l.organization_id = r.organization_id AND l.reservation_id = r.id AND l.status IN ('delivered', 'partial')
                              AND l.returned_quantity + l.missing_quantity < l.delivered_quantity)
             ORDER BY r.ends_at, r.id LIMIT $3
               FOR UPDATE OF r SKIP LOCKED
          SQL
        end

        # Reservas marcadas como atrasadas cujo prazo foi estendido para o futuro.
        def lock_extended(tx, now)
          tx.query(<<~SQL, [tx.tenant_id!, now]).map { |row| row["id"] }
            SELECT id FROM reservations
             WHERE organization_id = $1 AND status = 'in_progress' AND overdue_since IS NOT NULL AND ends_at > $2
               FOR UPDATE SKIP LOCKED
          SQL
        end

        # Marca (ou atualiza, quando o prazo mudou para uma data ainda vencida) o início do atraso.
        def mark_overdue(tx, reservation_id, since)
          tx.execute("UPDATE reservations SET overdue_since = $3 WHERE organization_id = $1 AND id = $2 AND overdue_since IS DISTINCT FROM $3",
                     [tx.tenant_id!, reservation_id, since])
        end

        def clear_overdue(tx, reservation_id)
          tx.execute("UPDATE reservations SET overdue_since = NULL WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, reservation_id])
        end

        def overdue_since(tx, reservation_id)
          tx.query_value("SELECT overdue_since FROM reservations WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, reservation_id])
        end

        # Ativos e quantidades ainda com o cliente nas reservas informadas.
        def outstanding(tx, reservation_ids)
          return [] if reservation_ids.empty?

          tx.query(<<~SQL, [tx.tenant_id!, reservation_ids])
            SELECT l.reservation_id, l.asset_id, l.stock_pool_id, l.delivered_quantity - l.returned_quantity - l.missing_quantity AS quantity
              FROM pickup_lines l
             WHERE l.organization_id = $1 AND l.reservation_id = ANY($2::uuid[]) AND l.status IN ('delivered', 'partial')
               AND l.returned_quantity + l.missing_quantity < l.delivered_quantity
             ORDER BY l.reservation_id, l.id
          SQL
        end

        def pickups_due(tx, until_time, limit: 50)
          tx.query(<<~SQL, [tx.tenant_id!, until_time, limit])
            SELECT r.id, r.code, r.starts_at, r.ends_at, c.name AS customer_name, p.id AS pickup_id
              FROM reservations r JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id
              LEFT JOIN pickups p ON p.organization_id = r.organization_id AND p.reservation_id = r.id AND p.status = 'picking'
             WHERE r.organization_id = $1 AND r.status = 'confirmed' AND r.starts_at < $2
             ORDER BY r.starts_at LIMIT $3
          SQL
        end

        def in_progress(tx, condition, params, limit: 50)
          sql = { due: "r.ends_at >= $2 AND r.ends_at < $3", overdue: "r.ends_at < $2" }.fetch(condition)
          tx.query(<<~SQL, [tx.tenant_id!, *params, limit])
            SELECT r.id, r.code, r.starts_at, r.ends_at, r.overdue_since, c.name AS customer_name
              FROM reservations r JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id
             WHERE r.organization_id = $1 AND r.status = 'in_progress' AND #{sql}
             ORDER BY r.ends_at LIMIT $#{params.size + 2}
          SQL
        end

        def contact_email(tx, reservation_id)
          tx.query_one(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT c.name, c.email FROM reservations r JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id
             WHERE r.organization_id = $1 AND r.id = $2
          SQL
        end
      end
    end
  end
end
