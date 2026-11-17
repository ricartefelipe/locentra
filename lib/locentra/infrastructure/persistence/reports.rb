# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class ReportsRepository
        def reservation_counts(tx)
          tx.query("SELECT status, count(*) AS total FROM reservations WHERE organization_id = $1 GROUP BY status", [tx.tenant_id!])
            .to_h { |row| [row["status"], row["total"]] }
        end

        def upcoming_pickups(tx, from, to)
          list(tx, "r.status = 'confirmed' AND r.starts_at >= $2 AND r.starts_at < $3", [from, to], "r.starts_at")
        end

        def returns_due(tx, from, to)
          list(tx, "r.status = 'in_progress' AND r.ends_at >= $2 AND r.ends_at < $3", [from, to], "r.ends_at")
        end

        def overdue(tx, now)
          list(tx, "r.status = 'in_progress' AND r.ends_at < $2", [now], "r.ends_at")
        end

        def expiring_holds(tx, from, to)
          list(tx, "r.status = 'held' AND r.hold_expires_at > $2 AND r.hold_expires_at <= $3", [from, to], "r.hold_expires_at")
        end

        def asset_counts(tx)
          tx.query("SELECT status, count(*) AS total FROM assets WHERE organization_id = $1 GROUP BY status", [tx.tenant_id!])
            .to_h { |row| [row["status"], row["total"]] }
        end

        # Agregados da fila gravados pelo worker (sem identificadores nos rótulos).
        def queue_stats(tx, _now)
          tx.query("SELECT queue, status, size, oldest_age_seconds AS oldest_age FROM queue_stats")
        end

        # Executado pelo worker (papel com visão de todas as filas).
        def refresh_queue_stats(tx, now)
          tx.execute("DELETE FROM queue_stats")
          tx.execute(<<~SQL, [now])
            INSERT INTO queue_stats (queue, status, size, oldest_age_seconds, updated_at)
            SELECT queue, status, count(*), COALESCE(EXTRACT(EPOCH FROM ($1::timestamptz - min(run_at))), 0), $1
              FROM jobs WHERE status IN ('pending', 'running', 'dead') GROUP BY queue, status
          SQL
        end

        private

        def list(tx, condition, params, order)
          tx.query(<<~SQL, [tx.tenant_id!, *params])
            SELECT r.id, r.code, r.status, r.starts_at, r.ends_at, r.hold_expires_at, c.name AS customer_name
              FROM reservations r JOIN customers c ON c.organization_id = r.organization_id AND c.id = r.customer_id
             WHERE r.organization_id = $1 AND #{condition}
             ORDER BY #{order} LIMIT 10
          SQL
        end
      end
    end
  end
end
