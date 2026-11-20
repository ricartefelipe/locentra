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

      # Métricas derivadas do banco, atualizadas no momento da coleta pelo processo web:
      #
      # - tamanho e idade da fila por fila e situação (`queue_stats`, gravado pelo worker), e há
      #   quanto tempo esses agregados foram atualizados (worker parado aparece como idade crescente);
      # - totais de retentativas e de falhas permanentes somados por todos os workers
      #   (`job_outcome_totals`), publicados como contadores.
      #
      # Nenhum rótulo carrega organização ou identificador: somente fila, situação e tipo de tarefa.
      #
      # Falha na coleta não derruba o /metrics: a série `metrics_collect_success` vai a 0 e o motivo é
      # registrado no log (`metrics.collect_failed`); as séries derivadas mantêm o último valor coletado.
      class CollectMetrics
        OUTCOME_COUNTERS = { "retry" => "jobs_retries_total", "dead" => "jobs_dead_total" }.freeze

        def initialize(transactor:, reports:, metrics:, clock:, logger: nil)
          @transactor = transactor
          @reports = reports
          @metrics = metrics
          @clock = clock
          @logger = logger
        end

        def call
          now = @clock.now
          stats, totals = @transactor.call { |tx| [@reports.queue_stats(tx, now), @reports.job_outcome_totals(tx)] }
          publish_queue(stats, now)
          totals.each do |row|
            name = OUTCOME_COUNTERS[row["outcome"]]
            @metrics.set_counter(name, row["total"].to_i, queue: row["queue"], kind: row["kind"]) if name
          end
          @metrics.gauge("metrics_collect_success", 1)
          true
        rescue StandardError => e
          @metrics.gauge("metrics_collect_success", 0)
          @logger&.warn(event: "metrics.collect_failed", error: e.class.name, message: e.message)
          false
        end

        private

        def publish_queue(stats, now)
          labels = ->(row) { { queue: row["queue"], status: row["status"] } }
          @metrics.replace_gauges("jobs_queue_size", stats.map { |row| [row["size"].to_i, labels.call(row)] })
          @metrics.replace_gauges("jobs_oldest_age_seconds", stats.map { |row| [row["oldest_age"].to_f.round(1), labels.call(row)] })
          updated = stats.filter_map { |row| row["updated_at"] }.max
          series = updated ? [[[now - updated, 0].max.round(1), {}]] : []
          @metrics.replace_gauges("jobs_queue_stats_age_seconds", series)
        end
      end
    end
  end
end
