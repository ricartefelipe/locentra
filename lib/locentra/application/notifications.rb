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

        def initialize(queue:, reservations:, customers:)
          @queue = queue
          @reservations = reservations
          @customers = customers
        end

        def for_event(tx, event)
          template = CUSTOMER_EVENTS[event["event_type"]]
          return unless template && event["aggregate_type"] == "reservation"

          reservation = @reservations.find(tx, event["aggregate_id"])
          customer = reservation && @customers.find(tx, reservation.customer_id)
          return unless customer&.email

          @queue.enqueue(tx, "email.send",
                         { "template" => template, "to" => customer.email,
                           "variables" => { "customer_name" => customer.name, "code" => reservation.code,
                                            "starts_at" => reservation.period.starts_at.iso8601, "ends_at" => reservation.period.ends_at.iso8601,
                                            "total" => reservation.total.format_brl } },
                         priority: 60, correlation_id: event["correlation_id"])
        end
      end
    end
  end
end
