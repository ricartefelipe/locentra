# frozen_string_literal: true

require "json"

module Locentra
  module Application
    module Webhooks
      EVENTS = %w[
        reservation.requested reservation.held reservation.confirmed reservation.cancelled reservation.expired reservation.extended
        reservation.picked_up reservation.returned contract.issued payment.confirmed payment.refunded
      ].freeze

      class CreateEndpoint
        def initialize(uow:, webhooks:, limits:, http:, box:, audit:, clock:, ids:)
          @uow = uow
          @webhooks = webhooks
          @limits = limits
          @http = http
          @box = box
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, url:, events:, description: nil)
          list = Array(events).map(&:to_s).uniq
          raise Domain::ValidationError.field("eventos", "selecione ao menos um evento") if list.empty?
          raise Domain::ValidationError.field("eventos", "evento desconhecido") unless (list - EVENTS - ["*"]).empty?

          begin
            @http.resolve!(url)
          rescue Infrastructure::Integrations::UnsafeDestination => e
            raise Domain::ValidationError.field("url", e.message)
          end
          @uow.run(actor, "integrations.manage") do |tx, current|
            @limits.feature!(tx, "webhooks")
            secret = "whsec_#{@ids.token(32)}"
            row = { "id" => @ids.uuid, "url" => url.to_s, "events" => list, "description" => Domain::Organizations::Text.optional(description, max: 200),
                    "secret_ciphertext" => @box.encrypt(secret), "created_by" => current.user_id, "created_at" => @clock.now }
            @webhooks.insert_endpoint(tx, row)
            @audit.record(tx, current, "webhook.endpoint_created", "webhook_endpoint", row["id"], "url" => row["url"], "events" => list)
            row.merge("secret" => secret)
          end
        end
      end

      class DisableEndpoint
        def initialize(uow:, webhooks:, audit:, clock:)
          @uow = uow
          @webhooks = webhooks
          @audit = audit
          @clock = clock
        end

        def call(actor, endpoint_id)
          @uow.run(actor, "integrations.manage") do |tx, current|
            id = Domain::Identifier.parse(endpoint_id)
            raise Domain::NotFound, "endpoint" unless @webhooks.disable_endpoint(tx, id, @clock.now) == 1

            @audit.record(tx, current, "webhook.endpoint_disabled", "webhook_endpoint", id)
            true
          end
        end
      end

      class ListEndpoints
        def initialize(uow:, webhooks:)
          @uow = uow
          @webhooks = webhooks
        end

        def call(actor)
          @uow.run(actor, "integrations.manage") do |tx, _|
            { endpoints: @webhooks.endpoints(tx), deliveries: @webhooks.recent_deliveries(tx, 50) }
          end
        end
      end

      # Reenvio manual de uma entrega que falhou, reutilizando o mesmo identificador de entrega.
      class Redeliver
        def initialize(uow:, webhooks:, queue:, audit:)
          @uow = uow
          @webhooks = webhooks
          @queue = queue
          @audit = audit
        end

        def call(actor, delivery_id)
          @uow.run(actor, "integrations.manage") do |tx, current|
            delivery = @webhooks.lock_delivery(tx, Domain::Identifier.parse(delivery_id)) || raise(Domain::NotFound, "entrega")
            raise Domain::Conflict.new("entrega já concluída", code: "already_delivered") if delivery["status"] == "delivered"

            @webhooks.reset_delivery(tx, delivery["id"])
            @queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => delivery["id"] }, priority: 40)
            @audit.record(tx, current, "webhook.redelivery_requested", "webhook_delivery", delivery["id"])
            true
          end
        end
      end

      # Despacho de um evento da outbox (executado pelo worker no contexto do tenant do evento):
      # cria uma entrega por endpoint inscrito e enfileira notificações por e-mail.
      class DispatchEvent
        def initialize(webhooks:, queue:, notifications:, clock:, ids:)
          @webhooks = webhooks
          @queue = queue
          @notifications = notifications
          @clock = clock
          @ids = ids
        end

        def call(tx, event_id)
          event = @webhooks.lock_event(tx, event_id)
          return :missing unless event
          return :already_dispatched if event["dispatched_at"]

          @webhooks.endpoints_for(tx, event["event_type"]).each do |endpoint|
            delivery_id = @ids.uuid
            next unless @webhooks.insert_delivery(tx, "id" => delivery_id, "endpoint_id" => endpoint["id"], "event_id" => event["id"],
                                                      "event_type" => event["event_type"], "created_at" => @clock.now)

            @queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => delivery_id }, priority: 40, correlation_id: event["correlation_id"])
          end
          @notifications.for_event(tx, event)
          @webhooks.mark_dispatched(tx, event["id"], @clock.now)
          :dispatched
        end
      end

      # Entrega de um webhook: assinatura com timestamp e identificador estável. A chamada de rede
      # ocorre fora de transação; o resultado é gravado em transação curta.
      class Deliver
        def initialize(transactor:, webhooks:, http:, box:, clock:, logger:)
          @transactor = transactor
          @webhooks = webhooks
          @http = http
          @box = box
          @clock = clock
          @logger = logger
        end

        def call(organization_id, delivery_id)
          data = @transactor.call(tenant_id: organization_id) { |tx| @webhooks.delivery_bundle(tx, delivery_id) }
          return :missing unless data
          return :already_delivered if data["status"] == "delivered"
          return :endpoint_disabled unless data["active"]

          body = JSON.generate("id" => data["event_id"], "type" => data["event_type"], "occurred_at" => data["occurred_at"].utc.iso8601,
                               "organization_id" => organization_id, "data" => data["payload"])
          timestamp = @clock.now.to_i
          headers = { "x-locentra-event-id" => data["event_id"], "x-locentra-delivery-id" => delivery_id, "x-locentra-event" => data["event_type"],
                      "x-locentra-signature" => Infrastructure::WebhookSignature.header(@box.decrypt(data["secret_ciphertext"]), timestamp, body) }
          outcome = attempt(data["url"], body, headers)
          @transactor.call(tenant_id: organization_id) { |tx| @webhooks.record_attempt(tx, delivery_id, outcome, @clock.now) }
          raise DeliveryFailed, outcome[:error] || "status #{outcome[:status]}" unless outcome[:success]

          :delivered
        end

        class DeliveryFailed < StandardError; end

        private

        def attempt(url, body, headers)
          response = @http.post(url, body, headers)
          { success: response.status.between?(200, 299), status: response.status,
            error: response.status.between?(300, 399) ? "redirecionamento não seguido" : nil }
        rescue Infrastructure::Integrations::UnsafeDestination => e
          { success: false, status: nil, error: "destino bloqueado: #{e.message}" }
        rescue StandardError => e
          { success: false, status: nil, error: "#{e.class.name}: #{e.message}"[0, 300] }
        end
      end
    end
  end
end
