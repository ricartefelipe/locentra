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

        # Agregados da fila gravados pelo worker (sem identificadores nem dados de tenant).
        def queue_stats(tx, _now)
          tx.query("SELECT queue, status, size, oldest_age_seconds AS oldest_age, updated_at FROM queue_stats ORDER BY queue, status")
        end

        # Totais de retentativas e de falhas permanentes somados por todos os workers.
        def job_outcome_totals(tx)
          tx.query("SELECT queue, kind, outcome, total FROM job_outcome_totals ORDER BY queue, kind, outcome")
        end

        # Totais por desfecho de webhooks, pausas de endpoints e retenção, somados por todos os workers.
        def worker_outcome_totals(tx)
          tx.query("SELECT family, outcome, total FROM worker_outcome_totals ORDER BY family, outcome")
        end

        # Executado pelo worker (papel com visão de todas as filas). Cada fila com tarefas em aberto,
        # e sempre a fila padrão, recebe as três situações (zero quando vazias), de modo que uma fila
        # esvaziada aparece com tamanho zero em vez de sumir. A idade considera somente tarefas já
        # liberadas para execução (run_at no passado): retentativas agendadas não inflam a espera.
        def refresh_queue_stats(tx, now)
          tx.execute("DELETE FROM queue_stats")
          tx.execute(<<~SQL, [now])
            INSERT INTO queue_stats (queue, status, size, oldest_age_seconds, updated_at)
            SELECT q.queue, s.status, count(j.id),
                   COALESCE(GREATEST(EXTRACT(EPOCH FROM ($1::timestamptz - min(j.run_at) FILTER (WHERE j.run_at <= $1::timestamptz))), 0), 0), $1
              FROM (SELECT DISTINCT queue FROM jobs WHERE status IN ('pending', 'running', 'dead') UNION SELECT 'default') q
             CROSS JOIN (VALUES ('pending'), ('running'), ('dead')) AS s (status)
              LEFT JOIN jobs j ON j.queue = q.queue AND j.status = s.status
             GROUP BY q.queue, s.status
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
