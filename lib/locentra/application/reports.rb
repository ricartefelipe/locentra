# frozen_string_literal: true

module Locentra
  module Application
    module Reports
      # Indicadores do painel da organização (dados reais, consultados na transação do tenant).
      class Dashboard
        def initialize(uow:, reports:, clock:)
          @uow = uow
          @reports = reports
          @clock = clock
        end

        def call(actor)
          @uow.run(actor, "reservations.read") do |tx, _|
            now = @clock.now
            {
              now: now,
              reservations: @reports.reservation_counts(tx),
              upcoming: @reports.upcoming_pickups(tx, now, now + (2 * 86_400)),
              returns_due: @reports.returns_due(tx, now, now + 86_400),
              overdue: @reports.overdue(tx, now),
              expiring_holds: @reports.expiring_holds(tx, now, now + 3600),
              assets: @reports.asset_counts(tx)
            }
          end
        end
      end

      class ListAudit
        def initialize(uow:, audit:)
          @uow = uow
          @audit = audit
        end

        def call(actor, filters: {}, limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset, default: 50)
          @uow.run(actor, "audit.read") do |tx, _|
            items, total = @audit.search(tx, filters: filters, limit: lim, offset: off)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end
      end

      # Métricas derivadas do banco (fila), atualizadas no momento da coleta.
      class CollectMetrics
        def initialize(transactor:, reports:, metrics:, clock:)
          @transactor = transactor
          @reports = reports
          @metrics = metrics
          @clock = clock
        end

        def call
          stats = @transactor.call { |tx| @reports.queue_stats(tx, @clock.now) }
          stats.each do |row|
            @metrics.gauge("jobs_queue_size", row["size"], queue: row["queue"], kind: row["status"])
            @metrics.gauge("jobs_oldest_age_seconds", row["oldest_age"].to_f.round(1), queue: row["queue"], kind: row["status"])
          end
          true
        rescue StandardError
          false
        end
      end
    end
  end
end
