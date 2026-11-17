# frozen_string_literal: true

require "bigdecimal"
require "json"

module Locentra
  module Infrastructure
    module Payments
      # Representação do Asaas (API v3) para cobranças e eventos de webhook, compartilhada pelo
      # simulador local. Valores decimais são lidos como BigDecimal e convertidos para centavos
      # inteiros; nenhum Float é usado.
      module AsaasFormat
        FN = Application::Finance
        BILLING_TYPES = { "pix" => "PIX", "boleto" => "BOLETO", "card" => "CREDIT_CARD" }.freeze
        STATUSES = {
          "PENDING" => "pending", "OVERDUE" => "pending", "AWAITING_RISK_ANALYSIS" => "pending", "DUNNING_REQUESTED" => "pending",
          "RECEIVED" => "confirmed", "CONFIRMED" => "confirmed", "RECEIVED_IN_CASH" => "confirmed", "DUNNING_RECEIVED" => "confirmed",
          "REFUNDED" => "refunded", "REFUND_REQUESTED" => "refunded", "REFUND_IN_PROGRESS" => "refunded",
          "CHARGEBACK_REQUESTED" => "disputed", "CHARGEBACK_DISPUTE" => "disputed", "AWAITING_CHARGEBACK_REVERSAL" => "disputed",
          "DELETED" => "cancelled"
        }.freeze
        CONFIRM_EVENTS = %w[PAYMENT_CONFIRMED PAYMENT_RECEIVED].freeze
        CANCEL_EVENTS = %w[PAYMENT_DELETED].freeze

        module_function

        def parse_json(text)
          JSON.parse(text.to_s, decimal_class: BigDecimal, max_nesting: 20, create_additions: false)
        rescue JSON::ParserError
          raise Domain::ValidationError.field("corpo", "JSON inválido do provedor")
        end

        # "150.5" → 15050. Mais de duas casas decimais é recusado.
        def cents(value)
          decimal = case value
                    when Integer, BigDecimal then BigDecimal(value)
                    when String then BigDecimal(value.strip)
                    else raise Domain::ValidationError.field("valor", "valor ausente ou inválido no provedor")
                    end
          scaled = decimal * 100
          raise Domain::ValidationError.field("valor", "valor com fração de centavo") unless scaled.frac.zero?

          Domain::Money.new(scaled.to_i)
        rescue ArgumentError
          raise Domain::ValidationError.field("valor", "valor inválido no provedor")
        end

        # Número decimal exato para o corpo JSON ("150.50").
        def decimal(money) = JSON::Fragment.new(money.to_decimal_string)

        def status(remote, deleted: false)
          return "cancelled" if deleted

          STATUSES.fetch(remote.to_s, "pending")
        end

        def charge(data)
          FN::ProviderCharge.new(provider_payment_id: data.fetch("id").to_s, external_reference: data["externalReference"]&.to_s,
                                 status: status(data["status"], deleted: data["deleted"] == true), amount: cents(data["value"]),
                                 invoice_url: safe_url(data["invoiceUrl"]))
        end

        # Evento: { "id", "event", "dateCreated", "payment": { "id", "status", "value", "externalReference", ... } }.
        # O campo `id` identifica o evento e é a chave de deduplicação.
        def parse_event(text)
          data = text.is_a?(Hash) ? text : parse_json(text)
          payment = data["payment"]
          unless data["id"].is_a?(String) && !data["id"].empty? && data["event"].is_a?(String) && payment.is_a?(Hash) && payment["id"]
            raise Domain::ValidationError.field("evento", "evento do provedor sem id, tipo ou cobrança")
          end

          FN::ProviderEvent.new(event_id: data["id"][0, 200], event_type: data["event"][0, 80], action: action(data["event"]),
                                provider_payment_id: payment["id"].to_s, external_reference: payment["externalReference"]&.to_s,
                                status: status(payment["status"], deleted: payment["deleted"] == true),
                                amount: payment.key?("value") ? cents(payment["value"]) : nil)
        end

        def action(event)
          return "confirm" if CONFIRM_EVENTS.include?(event)
          return "cancel" if CANCEL_EVENTS.include?(event)

          "ignore"
        end

        def safe_url(value)
          text = value.to_s
          text.match?(%r{\Ahttps://\S{1,1990}\z}) ? text : nil
        end
      end
    end
  end
end
