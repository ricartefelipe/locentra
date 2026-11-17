# frozen_string_literal: true

module Locentra
  module Domain
    module Finance
      DEPOSIT_KINDS = { "paid_deposit" => "Depósito pago", "card_preauthorization" => "Pré-autorização em cartão" }.freeze
      DEPOSIT_ENTRY_KINDS = { "receive" => "Recebimento", "apply" => "Aplicação a cobrança", "return" => "Devolução ao cliente" }.freeze
      DEPOSIT_STATUSES = { "awaiting" => "Aguardando recebimento", "held" => "Retida", "settled" => "Encerrada" }.freeze
      DEPOSIT_RETURN_METHODS = %w[pix transfer cash].freeze
      DEPOSIT_RESERVATION_STATUSES = %w[held confirmed in_progress completed].freeze

      CARD_PREAUTHORIZATION_REFUSAL = "Pré-autorização em cartão não está disponível: o provedor exige tokenização do cartão e o " \
                                      "Locentra não armazena número do cartão (PAN) nem código de segurança (CVV). Registre a caução " \
                                      "como depósito pago."

      # Caução: valor do cliente sob guarda da locadora (passivo). Nunca é receita; só deixa de ser
      # passivo quando aplicada a uma cobrança (avaria, falta, multa) ou devolvida.
      Deposit = Data.define(:id, :organization_id, :reservation_id, :customer_id, :kind, :expected, :notes) do
        def self.open(id:, organization_id:, reservation_id:, customer_id:, reservation_status:, kind:, expected:, notes: nil)
          raise ValidationError.field("tipo", CARD_PREAUTHORIZATION_REFUSAL) if kind == "card_preauthorization"
          raise ValidationError.field("tipo", "tipo de caução inválido") unless DEPOSIT_KINDS.key?(kind)
          raise InvalidTransition.new("reserva", reservation_status, "caução") unless DEPOSIT_RESERVATION_STATUSES.include?(reservation_status)

          new(id: id, organization_id: organization_id, reservation_id: reservation_id, customer_id: customer_id, kind: kind,
              expected: Amount.positive!(expected, "valor"), notes: Organizations::Text.optional(notes, max: 500))
        end

        def kind_label = DEPOSIT_KINDS.fetch(kind)
      end

      # Saldo da caução a partir dos movimentos (somente inserção).
      DepositLedger = Data.define(:received, :applied, :returned) do
        def self.empty = new(received: Money.zero, applied: Money.zero, returned: Money.zero)

        def self.from_entries(entries)
          sums = Hash.new(Money.zero)
          entries.each { |entry| sums[entry.fetch(:kind)] += entry.fetch(:amount) }
          new(received: sums["receive"], applied: sums["apply"], returned: sums["return"])
        end

        def balance = received - applied - returned

        def status
          return "awaiting" if received.zero?

          balance.positive? ? "held" : "settled"
        end

        def status_label = DEPOSIT_STATUSES.fetch(status)

        # Valor ainda esperado para completar a caução prevista.
        def remaining(expected) = [expected - received, Money.zero].max

        def receive!(amount, expected)
          Amount.positive!(amount)
          limit = remaining(expected)
          raise Conflict.new("Valor acima do restante previsto para a caução (#{limit.format_brl})", code: "deposit_over_expected") if amount > limit

          with(received: received + amount)
        end

        def apply!(amount, receivable_open)
          Amount.positive!(amount)
          raise Conflict.new("Valor acima do saldo da caução (#{balance.format_brl})", code: "deposit_insufficient") if amount > balance
          if amount > receivable_open
            raise Conflict.new("Valor acima do saldo em aberto da cobrança (#{receivable_open.format_brl})", code: "receivable_over_applied")
          end

          with(applied: applied + amount)
        end

        def return!(amount, method)
          raise ValidationError.field("metodo", "devolva por Pix, transferência ou dinheiro") unless DEPOSIT_RETURN_METHODS.include?(method)

          Amount.positive!(amount)
          raise Conflict.new("Valor acima do saldo da caução (#{balance.format_brl})", code: "deposit_insufficient") if amount > balance

          with(returned: returned + amount)
        end
      end
    end
  end
end
