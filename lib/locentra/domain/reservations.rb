# frozen_string_literal: true

module Locentra
  module Domain
    module Reservations
      STATUSES = {
        "requested" => "Solicitada",
        "held" => "Bloqueio temporário",
        "confirmed" => "Confirmada",
        "in_progress" => "Em andamento",
        "completed" => "Concluída",
        "cancelled" => "Cancelada",
        "expired" => "Expirada"
      }.freeze

      TRANSITIONS = {
        "requested" => %w[held confirmed cancelled],
        "held" => %w[confirmed cancelled expired],
        "confirmed" => %w[in_progress cancelled],
        "in_progress" => %w[completed],
        "completed" => [],
        "cancelled" => [],
        "expired" => []
      }.freeze

      # Estados cujas alocações ocupam disponibilidade.
      OCCUPYING = %w[held confirmed in_progress].freeze
      MODIFIABLE = %w[requested held confirmed].freeze

      MAX_LINES = 50
      MAX_QUANTITY = 100_000
      HOLD_MINUTES = (5..1440)
      PAST_TOLERANCE_SECONDS = 15 * 60

      Line = Data.define(:product_id, :quantity) do
        def self.build(product_id:, quantity:)
          qty = Integer(quantity.to_s, 10)
          raise ValidationError.field("quantidade", "entre 1 e #{MAX_QUANTITY}") unless qty.between?(1, MAX_QUANTITY)

          new(product_id: Identifier.parse(product_id, "produto"), quantity: qty)
        rescue ArgumentError
          raise ValidationError.field("quantidade", "número inteiro")
        end

        def to_h = { product_id: product_id, quantity: quantity }
      end

      module Rules
        module_function

        # Linhas repetidas para o mesmo produto são somadas: a mesma demanda nunca é verificada duas vezes.
        def normalize_lines(lines)
          raise ValidationError.field("itens", "informe ao menos um item") if lines.empty?
          raise ValidationError.field("itens", "no máximo #{MAX_LINES} itens") if lines.size > MAX_LINES

          lines.group_by(&:product_id).map { |product_id, group| Line.new(product_id: product_id, quantity: group.sum(&:quantity)) }
        end

        def validate_start!(period, now)
          return if period.starts_at.to_i >= now.to_i - PAST_TOLERANCE_SECONDS

          raise ValidationError.field("inicio", "não pode estar no passado")
        end

        def hold_minutes!(value)
          minutes = Integer(value.to_s, 10)
          unless HOLD_MINUTES.cover?(minutes)
            raise ValidationError.field("validade_bloqueio",
                                        "entre #{HOLD_MINUTES.min} e #{HOLD_MINUTES.max} minutos")
          end

          minutes
        rescue ArgumentError
          raise ValidationError.field("validade_bloqueio", "número inteiro de minutos")
        end
      end

      Reservation = Data.define(:id, :organization_id, :branch_id, :customer_id, :code, :status, :source, :period,
                                :hold_expires_at, :quote_id, :notes, :total, :deposit, :version) do
        def status_label = STATUSES.fetch(status)
        def occupying? = OCCUPYING.include?(status)
        def held? = status == "held"
        def requested? = status == "requested"
        def cancellable? = TRANSITIONS.fetch(status).include?("cancelled")

        # Um bloqueio temporário é válido enquanto `now < hold_expires_at`. O instante de expiração
        # pertence ao período expirado, de modo que confirmação e expiração concorrentes têm
        # resultado determinado pelo instante em que cada operação obtém o lock da reserva.
        def hold_valid?(now) = held? && now < hold_expires_at
        def hold_expired?(now) = held? && now >= hold_expires_at

        def transition(target)
          raise InvalidTransition.new("reserva", status, target) unless TRANSITIONS.fetch(status).include?(target)

          with(status: target, version: version + 1)
        end

        def hold(until_time)
          raise InvalidTransition.new("reserva", status, "held") unless TRANSITIONS.fetch(status).include?("held")

          with(status: "held", hold_expires_at: until_time, version: version + 1)
        end

        def confirm(now)
          raise HoldExpired if hold_expired?(now)

          transition("confirmed")
        end

        def expire(now)
          raise InvariantViolation, "bloqueio ainda válido" unless hold_expired?(now)

          transition("expired")
        end

        def cancel = transition("cancelled")
        def start = transition("in_progress")
        def complete = transition("completed")

        def reschedule(new_period, now)
          raise InvalidTransition.new("reserva", status, "reagendada") unless MODIFIABLE.include?(status)
          raise HoldExpired if hold_expired?(now)

          Rules.validate_start!(new_period, now)
          with(period: new_period, version: version + 1)
        end

        def extend_to(new_end, now)
          raise InvalidTransition.new("reserva", status, "estendida") unless %w[held confirmed in_progress].include?(status)
          raise HoldExpired if hold_expired?(now)
          raise ValidationError.field("fim", "a extensão deve terminar após o fim atual") unless new_end > period.ends_at

          with(period: period.with_end(new_end), version: version + 1)
        end
      end
    end
  end
end
