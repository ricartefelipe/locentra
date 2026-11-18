# frozen_string_literal: true

require "date"

module Locentra
  module Domain
    # Financeiro: contas a receber, pagamentos, reembolsos, cauções, diário contábil e conciliação.
    # Valores sempre em Money (centavos inteiros). Nenhuma regra depende de banco, rede ou HTTP.
    module Finance
      RECEIVABLE_KINDS = {
        "rental" => "Locação", "extension" => "Extensão", "late_fee" => "Multa por atraso", "damage" => "Avaria",
        "missing" => "Falta", "cancellation_fee" => "Multa de cancelamento", "other" => "Outros"
      }.freeze

      # Cobranças lançadas manualmente pela equipe (a locação e as extensões vêm da reserva).
      MANUAL_KINDS = %w[late_fee damage missing cancellation_fee other].freeze

      # Ajustes da reserva (reservation_adjustments.kind) convertidos em cobranças.
      ADJUSTMENT_KINDS = {
        "extension" => "extension", "amendment" => "other", "late_fee" => "late_fee", "damage" => "damage",
        "missing" => "missing", "cancellation_fee" => "cancellation_fee"
      }.freeze

      SOURCE_TYPES = %w[reservation reservation_adjustment manual].freeze

      # A locação é cobrada automaticamente para reservas confirmadas, em andamento ou concluídas. Um
      # bloqueio temporário só recebe cobrança com pedido explícito de cobrança antecipada.
      CHARGEABLE_RESERVATION_STATUSES = %w[confirmed in_progress completed].freeze
      PREPAYABLE_RESERVATION_STATUSES = (%w[held] + CHARGEABLE_RESERVATION_STATUSES).freeze
      MANUAL_CHARGE_RESERVATION_STATUSES = (CHARGEABLE_RESERVATION_STATUSES + %w[cancelled]).freeze
      CLOSED_RESERVATION_STATUSES = %w[cancelled expired].freeze
      # Cobranças que nascem do próprio cancelamento: geradas para reserva cancelada e esperadas em
      # aberto depois dele (não motivam o alerta de reserva encerrada com cobranças).
      CANCELLATION_CHARGE_KINDS = %w[cancellation_fee].freeze

      RECEIVABLE_STATUSES = {
        "open" => "Em aberto", "partial" => "Parcialmente paga", "paid" => "Quitada", "credit" => "Crédito do cliente",
        "cancelled" => "Cancelada"
      }.freeze

      # Conversão de valores recebidos de fora do sistema.
      module Amount
        module_function

        # Centavos informados por API: inteiro (ou texto só com dígitos). Float é recusado.
        def cents!(value, field = "valor")
          cents = case value
                  when Integer then value
                  when String then value.strip.match?(/\A\d{1,13}\z/) ? Integer(value.strip, 10) : nil
                  end
          raise ValidationError.field(field, "informe centavos como número inteiro") if cents.nil?

          positive!(Money.new(cents), field)
        end

        def positive!(money, field = "valor")
          raise ValidationError.field(field, "deve ser maior que zero") unless money.is_a?(Money) && money.positive?

          money
        end
      end

      Receivable = Data.define(:id, :organization_id, :reservation_id, :customer_id, :kind, :source_type, :source_id, :description,
                               :amount, :due_on) do
        def self.build(id:, organization_id:, reservation_id:, customer_id:, kind:, source_type:, source_id:, description:, amount:, due_on:)
          raise ValidationError.field("tipo", "tipo de cobrança inválido") unless RECEIVABLE_KINDS.key?(kind)
          raise ValidationError.field("origem", "origem de cobrança inválida") unless SOURCE_TYPES.include?(source_type)
          raise InvariantViolation, "a locação é cobrada somente a partir da reserva" unless (source_type == "reservation") == (kind == "rental")
          raise ValidationError.field("vencimento", "data inválida") unless due_on.is_a?(Date)

          new(id: id, organization_id: organization_id, reservation_id: reservation_id, customer_id: customer_id, kind: kind,
              source_type: source_type, source_id: source_id, description: Organizations::Text.required(description, "descricao", max: 300),
              amount: Amount.positive!(amount), due_on: due_on)
        end

        def kind_label = RECEIVABLE_KINDS.fetch(kind)

        # Locação e extensões são receita de locação; multas, avarias, faltas e outros são receitas adicionais.
        def revenue_account = %w[rental extension].include?(kind) ? "rental_revenue" : "additional_revenue"
      end

      # Saldo derivado de uma cobrança: valor − cancelado − pago + reembolsado − caução aplicada.
      # Reembolsos pendentes já contam: o valor está comprometido com o cliente.
      Balance = Data.define(:amount, :cancelled, :paid, :refunded, :applied) do
        def self.of(amount, cancelled: Money.zero, paid: Money.zero, refunded: Money.zero, applied: Money.zero)
          new(amount: amount, cancelled: cancelled, paid: paid, refunded: refunded, applied: applied)
        end

        def outstanding = amount - cancelled - paid + refunded - applied
        def settled = paid - refunded + applied
        def cancelled? = cancelled.positive?
        def credit = outstanding.negative? ? -outstanding : Money.zero

        # Valor que ainda pode ser recebido ou compensado na cobrança.
        def open_amount = outstanding.positive? ? outstanding : Money.zero

        def status
          return "cancelled" if cancelled?
          return "credit" if outstanding.negative?
          return "paid" if outstanding.zero?

          settled.positive? ? "partial" : "open"
        end

        def status_label = RECEIVABLE_STATUSES.fetch(status)
      end

      # Descrições e prazos das cobranças geradas a partir de reservas.
      module Charges
        module_function

        def rental_description(code) = "Locação da reserva #{code}"

        def adjustment_description(kind, code)
          "#{RECEIVABLE_KINDS.fetch(ADJUSTMENT_KINDS.fetch(kind))} da reserva #{code}"
        end

        def adjustment_kind(kind) = ADJUSTMENT_KINDS[kind]

        def chargeable?(reservation_status, prepayment: false)
          (prepayment ? PREPAYABLE_RESERVATION_STATUSES : CHARGEABLE_RESERVATION_STATUSES).include?(reservation_status)
        end

        # Ajuste vira cobrança quando a locação é cobrável; numa reserva cancelada, somente a multa de
        # cancelamento (os demais ajustes pressupõem a locação).
        def adjustment_chargeable?(adjustment_kind, reservation_status, prepayment: false)
          return false unless ADJUSTMENT_KINDS.key?(adjustment_kind)
          return true if chargeable?(reservation_status, prepayment: prepayment)

          reservation_status == "cancelled" && CANCELLATION_CHARGE_KINDS.include?(ADJUSTMENT_KINDS.fetch(adjustment_kind))
        end

        def manual_kind!(kind)
          raise ValidationError.field("tipo", "use multa, avaria, falta, multa de cancelamento ou outros") unless MANUAL_KINDS.include?(kind)

          kind
        end

        def manual_allowed!(reservation_status)
          return if MANUAL_CHARGE_RESERVATION_STATUSES.include?(reservation_status)

          raise InvalidTransition.new("reserva", reservation_status, "cobrança adicional")
        end
      end
    end
  end
end
