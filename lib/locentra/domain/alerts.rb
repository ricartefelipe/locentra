# frozen_string_literal: true

module Locentra
  module Domain
    # Alertas operacionais de reservas: atraso na devolução, reservas futuras afetadas por atraso e
    # itens que deixaram de estar disponíveis para reservas futuras. Nenhum alerta cancela reservas:
    # a decisão é registrada na resolução.
    module Alerts
      KINDS = {
        "overdue" => "Devolução em atraso",
        "affected_by_overdue" => "Reserva afetada por atraso",
        "asset_unavailable" => "Item indisponível para a reserva"
      }.freeze
      STATUSES = { "open" => "Aberto", "resolved" => "Resolvido" }.freeze

      Alert = Data.define(:id, :reservation_id, :kind, :related_reservation_id, :asset_id, :stock_pool_id, :status, :details,
                          :created_at, :resolved_at, :resolution) do
        def open? = status == "open"
        def kind_label = KINDS.fetch(kind)

        def resolve(text, now)
          raise InvalidTransition.new("alerta", status, "resolved") unless open?

          with(status: "resolved", resolution: Organizations::Text.required(text, "decisao", min: 3, max: 1000), resolved_at: now)
        end
      end

      # Chaves de deduplicação: cada situação gera um único alerta, mesmo com execuções repetidas.
      module Keys
        module_function

        def overdue(reservation_id, scheduled_end) = "overdue:#{reservation_id}:#{scheduled_end.to_i}"
        def affected(reservation_id, overdue_id, resource_id) = "affected:#{reservation_id}:#{overdue_id}:#{resource_id}"
        def unavailable(reservation_id, resource_id, source_id) = "unavailable:#{reservation_id}:#{resource_id}:#{source_id}"
      end

      module Overdue
        module_function

        # Atraso a partir do fim previsto (instante final exclusivo do período).
        def overdue?(reservation, now) = reservation.status == "in_progress" && now >= reservation.period.ends_at
      end

      # Reservas cuja ocupação de estoque ultrapassa a capacidade efetiva em algum trecho da janela.
      # `outstanding` são unidades fora do estoque além das próprias alocações (atrasos).
      module StockShortfall
        module_function

        # occupancies: [{ reservation_id:, period:, quantity: }]
        def affected(capacity:, occupancies:, window:, outstanding: 0)
          limit = capacity - outstanding
          relevant = occupancies.select { |o| o[:period].overlaps?(window) }
          list = relevant.map { |o| Availability::Occupancy.new(period: o[:period], quantity: o[:quantity]) }
          short = Availability::Peak.timeline(window, list).select { |segment| segment.quantity > limit }
          return [] if short.empty?

          relevant.select { |o| short.any? { |segment| segment.period.overlaps?(o[:period]) } }.filter_map { |o| o[:reservation_id] }.uniq
        end
      end
    end
  end
end
