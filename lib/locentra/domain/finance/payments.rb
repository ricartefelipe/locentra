# frozen_string_literal: true

module Locentra
  module Domain
    module Finance
      PAYMENT_METHODS = {
        "pix" => "Pix", "boleto" => "Boleto", "card" => "Cartão (página do provedor)", "cash" => "Dinheiro", "transfer" => "Transferência"
      }.freeze
      # Métodos cobrados por provedor. Cartão usa a página de pagamento do provedor: o Locentra nunca
      # recebe nem armazena número do cartão (PAN) ou código de segurança (CVV).
      PROVIDER_METHODS = %w[pix boleto card].freeze
      PAYMENT_PURPOSES = { "receivable" => "Cobrança", "deposit" => "Caução" }.freeze
      PROVIDERS = { "manual" => "Registro manual", "simulator" => "Simulador local", "asaas" => "Asaas" }.freeze
      ONLINE_PROVIDERS = %w[simulator asaas].freeze

      PAYMENT_STATUSES = {
        "pending_submission" => "Aguardando envio ao provedor", "submission_unknown" => "Envio sem confirmação",
        "pending" => "Aguardando pagamento", "confirmed" => "Confirmado", "failed" => "Falhou", "cancelled" => "Cancelado"
      }.freeze

      # Máquina de estados do pagamento. Confirmado, falho e cancelado são finais e imutáveis.
      # - pending_submission → confirmed cobre o webhook que chega antes da resposta do envio.
      # - submission_unknown só sai do estado após consulta ao provedor pela referência externa:
      #   encontrada → pending/confirmed/cancelled; não encontrada → pending_submission (novo envio
      #   com a mesma referência).
      PAYMENT_TRANSITIONS = {
        "pending_submission" => %w[pending submission_unknown confirmed failed cancelled],
        "submission_unknown" => %w[pending_submission pending confirmed cancelled],
        "pending" => %w[confirmed failed cancelled],
        "confirmed" => [], "failed" => [], "cancelled" => []
      }.freeze

      SIMULATOR_SCENARIOS = {
        "success" => "Sucesso", "fail" => "Recusa pelo provedor", "timeout_after_success" => "Tempo esgotado após registrar a cobrança"
      }.freeze

      Payment = Data.define(:id, :organization_id, :purpose, :receivable_id, :deposit_id, :reservation_id, :customer_id, :payment_method,
                            :provider, :provider_account_id, :status, :amount, :external_reference, :provider_payment_id, :invoice_url,
                            :due_on, :simulator_scenario, :requires_review, :review_reason, :failure_reason, :submission_attempts,
                            :notes, :paid_at, :confirmed_at) do
        # Pagamento recebido fora do provedor e registrado pela equipe: nasce confirmado.
        def self.manual(id:, organization_id:, purpose:, target_id:, reservation_id:, customer_id:, payment_method:, amount:, paid_at:,
                        review_reason: nil, notes: nil)
          raise ValidationError.field("metodo", "método de pagamento inválido") unless PAYMENT_METHODS.key?(payment_method)

          base(id: id, organization_id: organization_id, purpose: purpose, target_id: target_id, reservation_id: reservation_id,
               customer_id: customer_id, payment_method: payment_method, amount: amount, notes: notes)
            .with(provider: "manual", status: "confirmed", paid_at: paid_at, confirmed_at: paid_at,
                  requires_review: !review_reason.nil?, review_reason: review_reason)
        end

        # Cobrança a enviar ao provedor pelo worker, fora de transação.
        def self.request(id:, organization_id:, purpose:, target_id:, reservation_id:, customer_id:, payment_method:, amount:, provider:,
                         account_id:, due_on:, scenario: nil, notes: nil)
          raise ValidationError.field("metodo", "use Pix, boleto ou cartão para cobranças pelo provedor") unless PROVIDER_METHODS.include?(payment_method)
          raise ValidationError.field("provedor", "provedor de pagamento inválido") unless ONLINE_PROVIDERS.include?(provider)

          scenario = if provider == "simulator"
                       scenario.to_s.empty? ? "success" : scenario.to_s
                     end
          raise ValidationError.field("cenario", "cenário do simulador inválido") if scenario && !SIMULATOR_SCENARIOS.key?(scenario)
          raise ValidationError.field("vencimento", "data inválida") unless due_on.is_a?(Date)

          base(id: id, organization_id: organization_id, purpose: purpose, target_id: target_id, reservation_id: reservation_id,
               customer_id: customer_id, payment_method: payment_method, amount: amount, notes: notes)
            .with(provider: provider, provider_account_id: account_id, status: "pending_submission", due_on: due_on, simulator_scenario: scenario)
        end

        def self.base(id:, organization_id:, purpose:, target_id:, reservation_id:, customer_id:, payment_method:, amount:, notes:)
          raise ValidationError.field("finalidade", "finalidade inválida") unless PAYMENT_PURPOSES.key?(purpose)

          new(id: id, organization_id: organization_id, purpose: purpose, receivable_id: purpose == "receivable" ? target_id : nil,
              deposit_id: purpose == "deposit" ? target_id : nil, reservation_id: reservation_id, customer_id: customer_id, payment_method: payment_method,
              provider: nil, provider_account_id: nil, status: nil, amount: Amount.positive!(amount), external_reference: id,
              provider_payment_id: nil, invoice_url: nil, due_on: nil, simulator_scenario: nil, requires_review: false, review_reason: nil,
              failure_reason: nil, submission_attempts: 0, notes: Organizations::Text.optional(notes, max: 500), paid_at: nil, confirmed_at: nil)
        end
        private_class_method :base

        def status_label = PAYMENT_STATUSES.fetch(status)
        def method_label = PAYMENT_METHODS.fetch(payment_method)
        def provider_label = PROVIDERS.fetch(provider)
        def confirmed? = status == "confirmed"
        def manual? = provider == "manual"
        def online? = ONLINE_PROVIDERS.include?(provider)
        def final? = PAYMENT_TRANSITIONS.fetch(status).empty?
        def refundable? = confirmed? && purpose == "receivable"
        def target_id = receivable_id || deposit_id

        def transition(target)
          raise InvalidTransition.new("pagamento", status, target) unless PAYMENT_TRANSITIONS.fetch(status).include?(target)

          with(status: target)
        end

        def attempt = with(submission_attempts: submission_attempts + 1)

        # Identificadores devolvidos pelo provedor (preenchidos uma vez; a situação é tratada separadamente).
        def adopt(provider_payment_id, invoice_url)
          with(provider_payment_id: self.provider_payment_id || provider_payment_id, invoice_url: self.invoice_url || invoice_url)
        end

        def fail(reason) = transition("failed").with(failure_reason: Organizations::Text.optional(reason, max: 500) || "recusado")
        def cancel(reason) = transition("cancelled").with(failure_reason: Organizations::Text.optional(reason, max: 500))

        def confirm(at, review_reason: nil)
          transition("confirmed").with(confirmed_at: at, paid_at: paid_at || at, requires_review: !review_reason.nil?, review_reason: review_reason)
        end
      end

      # Situações que pedem decisão humana. A confirmação do dinheiro nunca altera a reserva.
      module Review
        RESERVATION_REASONS = {
          "expired" => ["payment_after_expiration",
                        "Pagamento recebido após a expiração do bloqueio temporário. A reserva não foi reativada; decida entre reembolso e nova reserva."],
          "cancelled" => ["payment_after_cancellation",
                          "Pagamento recebido para reserva cancelada. A reserva não foi reativada; decida entre reembolso e nova reserva."]
        }.freeze

        module_function

        def for_reservation(status) = RESERVATION_REASONS[status]

        def amount_mismatch(expected, received)
          return nil if received.nil? || received == expected

          ["payment_amount_mismatch", "Valor informado pelo provedor (#{received.format_brl}) difere do valor cobrado (#{expected.format_brl})."]
        end

        def reason_text(findings)
          findings.empty? ? nil : findings.map(&:last).join(" ")
        end
      end

      REFUND_STATUSES = { "pending" => "Pendente no provedor", "confirmed" => "Confirmado", "failed" => "Falhou" }.freeze
      REFUND_TRANSITIONS = { "pending" => %w[confirmed failed], "confirmed" => [], "failed" => [] }.freeze

      Refund = Data.define(:id, :organization_id, :payment_id, :amount, :reason, :status, :provider_reference, :failure_reason, :confirmed_at) do
        def self.build(id:, organization_id:, payment:, amount:, reason:, now:)
          refund = new(id: id, organization_id: organization_id, payment_id: payment.id, amount: amount,
                       reason: Organizations::Text.required(reason, "motivo", min: 3, max: 500), status: "pending", provider_reference: nil,
                       failure_reason: nil, confirmed_at: nil)
          payment.manual? ? refund.confirm(now, nil) : refund
        end

        def status_label = REFUND_STATUSES.fetch(status)
        def pending? = status == "pending"

        def transition(target)
          raise InvalidTransition.new("reembolso", status, target) unless REFUND_TRANSITIONS.fetch(status).include?(target)

          with(status: target)
        end

        def confirm(at, provider_reference) = transition("confirmed").with(confirmed_at: at, provider_reference: provider_reference)
        def fail(reason) = transition("failed").with(failure_reason: Organizations::Text.optional(reason, max: 500) || "recusado")

        # Descrição enviada ao provedor: permite reconhecer o reembolso numa nova tentativa.
        def provider_description = "Locentra reembolso #{id}"
      end

      # Soma de reembolsos pendentes e confirmados nunca excede o valor confirmado do pagamento.
      module RefundPolicy
        module_function

        def check!(payment, committed:, amount:)
          raise InvalidTransition.new("pagamento", payment.status, "reembolso") unless payment.confirmed?
          raise ValidationError.field("pagamento", "cauções são devolvidas pela própria caução, não por reembolso") unless payment.purpose == "receivable"

          Amount.positive!(amount)
          eligible = payment.amount - committed
          return amount if amount <= eligible

          raise Conflict.new("Reembolso acima do saldo elegível do pagamento (#{eligible.format_brl})", code: "refund_exceeds_eligible")
        end

        def eligible(payment, committed) = payment.confirmed? ? payment.amount - committed : Money.zero
      end
    end
  end
end
