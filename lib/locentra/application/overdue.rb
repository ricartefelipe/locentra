# frozen_string_literal: true

module Locentra
  module Application
    # Atrasos de devolução, reservas futuras afetadas e painel de operação.
    module Overdue
      Keys = Domain::Alerts::Keys

      # Executado pelo worker a cada rotina da organização (`organization.tick`). Idempotente: alertas
      # são deduplicados pela chave e o e-mail de atraso é enfileirado uma única vez por reserva.
      # Nenhuma reserva é cancelada automaticamente.
      #
      # Todas as reservas vencidas são processadas a cada execução, em lotes de `limit` (uma transação
      # por lote, paginada por fim previsto e id): as ainda não sinalizadas recebem o atraso e as já
      # sinalizadas voltam a identificar reservas futuras criadas depois.
      class DetectOverdue
        def initialize(uow:, operations:, alerts:, alert_book:, allocations:, availability:, coverage:, queue:, audit:, clock:)
          @uow = uow
          @operations = operations
          @alerts = alerts
          @alert_book = alert_book
          @allocations = allocations
          @availability = availability
          @coverage = coverage
          @queue = queue
          @audit = audit
          @clock = clock
        end

        def call(actor, limit: 100)
          raise ArgumentError, "lote deve ser positivo" unless limit.positive?

          processed = []
          cursor = nil
          loop do
            ids, cursor = @uow.run(actor, "fulfillment.write") { |tx, current| detect_batch(tx, current, cursor, limit) }
            processed.concat(ids)
            break unless cursor
          end
          processed
        end

        private

        # Devolve os ids processados e o cursor do próximo lote (nil quando não há mais reservas).
        def detect_batch(tx, current, cursor, limit)
          now = @clock.now
          refresh_extended(tx, now) if cursor.nil?
          rows = @operations.lock_overdue(tx, now, limit, after: cursor)
          overdue = rows.select { |reservation, _| Domain::Alerts::Overdue.overdue?(reservation, now) }
          overdue.each { |reservation, since| flag(tx, current, reservation, since) }
          reservations = overdue.map(&:first)
          identify_affected(tx, reservations, now) unless reservations.empty?
          last = rows.last&.first
          [reservations.map(&:id), rows.size == limit ? [last.period.ends_at, last.id] : nil]
        end

        # Prazo estendido para o futuro: a reserva deixa de estar atrasada e os alertas são resolvidos.
        def refresh_extended(tx, now)
          @operations.lock_extended(tx, now).each do |id|
            @operations.clear_overdue(tx, id)
            @alerts.resolve_open(tx, reservation_id: id, kinds: ["overdue"], resolution: "Prazo de devolução estendido", now: now)
            @alerts.resolve_open(tx, reservation_id: id, kinds: ["affected_by_overdue"], related: true, now: now,
                                     resolution: "Prazo da reserva em atraso estendido")
          end
        end

        # Um único alerta de atraso aberto por reserva: se o prazo foi alterado para uma data ainda
        # vencida, o alerta do fim anterior é resolvido e substituído pelo do novo fim previsto.
        def flag(tx, current, reservation, since)
          scheduled_end = reservation.period.ends_at
          key = Keys.overdue(reservation.id, scheduled_end)
          unless since == scheduled_end
            @operations.mark_overdue(tx, reservation.id, scheduled_end)
            if since
              @alerts.resolve_superseded(tx, reservation_id: reservation.id, kind: "overdue", keep_key: key, now: @clock.now,
                                             resolution: "Prazo de devolução alterado; substituído pelo alerta do novo fim previsto")
            end
          end
          created = @alert_book.raise_alert(tx, reservation_id: reservation.id, kind: "overdue", key: key,
                                                details: { "code" => reservation.code, "ends_at" => scheduled_end.iso8601 })
          return unless created

          @audit.record(tx, current, "reservation.overdue", "reservation", reservation.id, "ends_at" => scheduled_end.iso8601)
          notify(tx, current, reservation)
        end

        def notify(tx, actor, reservation)
          contact = @operations.contact_email(tx, reservation.id)
          return unless contact && contact["email"]

          @queue.enqueue(tx, "email.send",
                         { "template" => "late_return", "to" => contact["email"],
                           "variables" => { "customer_name" => contact["name"], "code" => reservation.code,
                                            "ends_at" => reservation.period.ends_at.iso8601 } },
                         unique_key: "late_return:#{reservation.id}", priority: 60, correlation_id: actor.request_id)
        end

        # Reservas futuras que usam os mesmos ativos ainda com o cliente, ou cuja capacidade de estoque
        # fica descoberta pelas unidades em atraso.
        def identify_affected(tx, reservations, now)
          by_id = reservations.to_h { |r| [r.id, r] }
          outstanding = @operations.outstanding(tx, by_id.keys)
          outstanding.select { |row| row["asset_id"] }.each { |row| affected_by_asset(tx, row, by_id.fetch(row["reservation_id"]), now) }
          outstanding.select { |row| row["stock_pool_id"] }.group_by { |row| row["stock_pool_id"] }.each do |pool_id, rows|
            affected_by_stock(tx, pool_id, rows, by_id, now)
          end
        end

        def affected_by_asset(tx, row, overdue, now)
          @allocations.future_reservations_for_asset(tx, row["asset_id"], now, exclude_reservation_id: overdue.id).each do |future|
            @alert_book.raise_alert(tx, reservation_id: future["reservation_id"], kind: "affected_by_overdue",
                                        key: Keys.affected(future["reservation_id"], overdue.id, row["asset_id"]),
                                        related_reservation_id: overdue.id, asset_id: row["asset_id"],
                                        details: { "overdue_code" => overdue.code, "starts_at" => future["starts_at"].utc.iso8601 })
          end
        end

        def affected_by_stock(tx, pool_id, rows, by_id, now)
          sources = rows.map { |row| row["reservation_id"] }.uniq
          capacity = @availability.pool_capacity(tx, pool_id)
          affected = @coverage.affected(tx, pool_id, capacity, now, outstanding: rows.sum { |row| row["quantity"] }, exclude: sources)
          affected.product(sources).each do |reservation_id, source_id|
            @alert_book.raise_alert(tx, reservation_id: reservation_id, kind: "affected_by_overdue", key: Keys.affected(reservation_id, source_id, pool_id),
                                        related_reservation_id: source_id, stock_pool_id: pool_id,
                                        details: { "overdue_code" => by_id.fetch(source_id).code })
          end
        end
      end

      # Resolução do alerta com registro da decisão tomada.
      class ResolveAlert
        def initialize(uow:, alerts:, audit:, clock:)
          @uow = uow
          @alerts = alerts
          @audit = audit
          @clock = clock
        end

        def call(actor, alert_id, resolution:)
          @uow.run(actor, "fulfillment.write") do |tx, current|
            alert = @alerts.lock(tx, Domain::Identifier.parse(alert_id)) || raise(Domain::NotFound, "alerta")
            resolved = alert.resolve(resolution, @clock.now)
            @alerts.resolve(tx, resolved, current.audit_actor_id)
            @audit.record(tx, current, "alert.resolved", "reservation", alert.reservation_id,
                          "alert_id" => alert.id, "kind" => alert.kind, "resolution" => resolved.resolution)
            resolved
          end
        end
      end

      # Painel: retiradas do dia (e atrasadas), devoluções previstas, atrasos, alertas, inspeções,
      # avarias aguardando aprovação e transferências em andamento.
      class OperationsBoard
        def initialize(uow:, operations:, alerts:, inspections:, damage_reports:, transfers:, organizations:, clock:)
          @uow = uow
          @operations = operations
          @alerts = alerts
          @inspections = inspections
          @damage_reports = damage_reports
          @transfers = transfers
          @organizations = organizations
          @clock = clock
        end

        def call(actor)
          @uow.run(actor, "reservations.read") do |tx, _|
            now = @clock.now
            zone = @organizations.find(tx, tx.tenant_id!).time_zone
            day_end = zone.start_of_day(zone.local_date(now) + 1)
            { now: now, pickups: @operations.pickups_due(tx, day_end), returns_due: @operations.in_progress(tx, :due, [now, day_end]),
              overdue: @operations.in_progress(tx, :overdue, [now]), alerts: @alerts.list(tx, limit: 50),
              inspections: @inspections.list(tx, status: "pending", limit: 50), damage_reports: @damage_reports.list(tx, filter: "open", limit: 50),
              transfers: @transfers.list(tx, filter: "active", limit: 50) }
          end
        end
      end

      # Resumo operacional exibido na tela da reserva.
      class ReservationOperations
        def initialize(uow:, fulfillment:, alerts:, damage_reports:)
          @uow = uow
          @fulfillment = fulfillment
          @alerts = alerts
          @damage_reports = damage_reports
        end

        def call(actor, reservation_id)
          @uow.run(actor, "reservations.read") do |tx, _|
            id = Domain::Identifier.parse(reservation_id)
            { pickups: @fulfillment.pickups_for(tx, id), returns: @fulfillment.returns_for(tx, id),
              alerts: @alerts.list(tx, limit: 20, reservation_id: id), damage_reports: @damage_reports.list(tx, filter: "all", reservation_id: id) }
          end
        end
      end
    end
  end
end
