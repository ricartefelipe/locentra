# frozen_string_literal: true

module Locentra
  module Application
    module Notifications
      # Notificações por e-mail derivadas de eventos de negócio (executado no despacho da outbox).
      class EventNotifications
        CUSTOMER_EVENTS = {
          "reservation.confirmed" => "reservation_confirmed", "reservation.cancelled" => "reservation_cancelled",
          "reservation.extended" => "reservation_extended"
        }.freeze

        def initialize(queue:, reservations:, customers:, quotes:, contracts:)
          @queue = queue
          @reservations = reservations
          @customers = customers
          @quotes = quotes
          @contracts = contracts
        end

        def for_event(tx, event)
          case [event["aggregate_type"], event["event_type"]]
          in ["quote", "quote.sent"] then quote_sent(tx, event)
          in ["contract", "contract.issued"] then contract_issued(tx, event)
          in ["reservation", type] if CUSTOMER_EVENTS.key?(type) then reservation_event(tx, event, CUSTOMER_EVENTS.fetch(type))
          else nil
          end
        end

        private

        # Bloqueios temporários de orçamentos ainda não convertidos são internos ao orçamento: o cliente
        # é avisado pelo e-mail do orçamento, não por e-mails de reserva.
        def reservation_event(tx, event, template)
          reservation = @reservations.find(tx, event["aggregate_id"])
          return if reservation.nil? || (reservation.source == "quote" && reservation.quote_id.nil?)

          customer = @customers.find(tx, reservation.customer_id)
          return unless customer&.email

          deliver(tx, event, template, customer, "code" => reservation.code, "starts_at" => reservation.period.starts_at.iso8601,
                                                 "ends_at" => reservation.period.ends_at.iso8601, "total" => reservation.total.format_brl)
        end

        # O e-mail informa a política de bloqueio: sem bloqueio, o orçamento não garante disponibilidade.
        def quote_sent(tx, event)
          quote = @quotes.find(tx, event["aggregate_id"])
          version = quote && @quotes.find_version(tx, quote.id, event.dig("payload", "version") || quote.current_version)
          customer = version && @customers.find(tx, quote.customer_id)
          return unless customer&.email

          deliver(tx, event, "quote_sent", customer,
                  "code" => quote.code, "version" => version.number, "total" => version.total.format_brl,
                  "starts_at" => version.period.starts_at.iso8601, "ends_at" => version.period.ends_at.iso8601,
                  "valid_until" => version.valid_until.iso8601, "hold" => quote.hold_on_send?, "hold_minutes" => quote.hold_minutes)
        end

        def contract_issued(tx, event)
          contract = @contracts.find(tx, event["aggregate_id"])
          customer = contract && @customers.find(tx, contract.customer_id)
          return unless customer&.email

          period = contract.terms.fetch("period")
          deliver(tx, event, "contract_issued", customer,
                  "code" => contract.code, "reservation_code" => contract.terms.dig("reservation", "code"), "starts_at" => period["starts_at"],
                  "ends_at" => period["ends_at"], "total" => contract.contracted_total.format_brl,
                  "acceptance_notice" => Domain::Contracts::ACCEPTANCE_NOTICE)
        end

        def deliver(tx, event, template, customer, variables)
          @queue.enqueue(tx, "email.send", { "template" => template, "to" => customer.email,
                                             "variables" => variables.merge("customer_name" => customer.name) },
                         priority: 60, correlation_id: event["correlation_id"])
        end
      end
    end
  end
end
