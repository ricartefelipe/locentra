# frozen_string_literal: true

require "json"
require "uri"

module Locentra
  module Application
    module Webhooks
      EVENTS = %w[
        reservation.requested reservation.held reservation.confirmed reservation.cancelled reservation.expired reservation.extended
        reservation.picked_up reservation.returned contract.issued payment.confirmed payment.refunded
        quote.sent quote.approved quote.rejected quote.expired quote.converted contract.accepted contract.amended contract.cancelled
      ].freeze
      # Fila própria das entregas, atendida por threads dedicadas do worker (WEBHOOK_CONCURRENCY).
      DELIVERY_QUEUE = "webhooks"
      # Liberação das entregas retidas depois da reativação de um endpoint pausado: tarefa da fila
      # `default`, em lotes, reagendada até não restar entrega retida.
      RELEASE_BATCH = 500
      RELEASE_KIND = "webhooks.release_held"
      DELIVERY_PRIORITY = 40
      RELEASE_PRIORITY = 45

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

        # Na auditoria (visível ao papel auditor) fica só esquema, host e porta: caminho e query de URLs
        # de webhook costumam carregar segredos.
        def self.audit_url(url)
          uri = URI.parse(url.to_s)
          suffix = uri.path.to_s.empty? || uri.path == "/" ? "" : "/…"
          suffix = "/…" if uri.query
          "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}#{suffix}"
        rescue URI::InvalidURIError
          "[URL inválida]"
        end

        def call(actor, url:, events:, description: nil)
          list = Array(events).map(&:to_s).uniq
          raise Domain::ValidationError.field("eventos", "selecione ao menos um evento") if list.empty?
          raise Domain::ValidationError.field("eventos", "evento desconhecido") unless (list - EVENTS - ["*"]).empty?

          begin
            @http.resolve!(url)
          rescue Integrations::UnsafeDestination => e
            raise Domain::ValidationError.field("url", e.message)
          end
          @uow.run(actor, "integrations.manage") do |tx, current|
            Authorizer.confirmed_email!(current, "webhooks.create")
            @limits.feature!(tx, "webhooks")
            secret = "whsec_#{@ids.token(32)}"
            row = { "id" => @ids.uuid, "url" => url.to_s, "events" => list, "description" => Domain::Organizations::Text.optional(description, max: 200),
                    "secret_ciphertext" => @box.encrypt(secret), "created_by" => current.user_id, "created_at" => @clock.now }
            @webhooks.insert_endpoint(tx, row)
            @audit.record(tx, current, "webhook.endpoint_created", "webhook_endpoint", row["id"], "url" => self.class.audit_url(row["url"]),
                                                                                                  "events" => list)
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
          @uow.run(actor, "integrations.manage", read: true) do |tx, _|
            { endpoints: @webhooks.endpoints(tx), deliveries: @webhooks.recent_deliveries(tx, 50) }
          end
        end
      end

      # Reenvio manual de uma entrega que falhou, reutilizando o mesmo identificador de entrega. A
      # entrega volta a `pending` sem retenção; com o endpoint ainda pausado, a tarefa a retém de novo.
      class Redeliver
        def initialize(uow:, webhooks:, queue:, audit:)
          @uow = uow
          @webhooks = webhooks
          @queue = queue
          @audit = audit
        end

        def call(actor, delivery_id)
          @uow.run(actor, "integrations.manage") do |tx, current|
            Authorizer.confirmed_email!(current, "webhooks.redeliver")
            delivery = @webhooks.lock_delivery(tx, Domain::Identifier.parse(delivery_id)) || raise(Domain::NotFound, "entrega")
            raise Domain::Conflict.new("entrega já concluída", code: "already_delivered") if delivery["status"] == "delivered"

            @webhooks.reset_delivery(tx, delivery["id"])
            @queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => delivery["id"] },
                           priority: DELIVERY_PRIORITY, correlation_id: current.request_id, queue: DELIVERY_QUEUE)
            @audit.record(tx, current, "webhook.redelivery_requested", "webhook_delivery", delivery["id"])
            true
          end
        end
      end

      # Despacho de um evento da outbox (executado pelo worker no contexto do tenant do evento):
      # cria uma entrega por endpoint inscrito, enfileira notificações por e-mail e chama os
      # assinantes internos (objetos com `call(tx, event)`, ex.: sincronização financeira), na mesma
      # transação que marca o evento como despachado.
      #
      # Endpoint pausado: a entrega já nasce retida (`held_at`), sem tarefa; sai depois da reativação
      # (ReleaseHeld). Os endpoints são lidos com FOR KEY SHARE, e a reativação (FOR UPDATE) espera este
      # commit: nenhuma entrega fica retida depois de o endpoint voltar.
      class DispatchEvent
        def initialize(webhooks:, queue:, notifications:, clock:, ids:, totals:, subscribers: [])
          @webhooks = webhooks
          @queue = queue
          @notifications = notifications
          @clock = clock
          @ids = ids
          @totals = totals
          @subscribers = subscribers.freeze
        end

        def call(tx, event_id)
          event = @webhooks.lock_event(tx, event_id)
          return :missing unless event
          return :already_dispatched if event["dispatched_at"]

          now = @clock.now
          @webhooks.endpoints_for(tx, event["event_type"]).each do |endpoint|
            delivery_id = @ids.uuid
            held = endpoint["paused_at"] ? now : nil
            next unless @webhooks.insert_delivery(tx, "id" => delivery_id, "endpoint_id" => endpoint["id"], "event_id" => event["id"],
                                                      "event_type" => event["event_type"], "created_at" => now, "held_at" => held)

            if held
              @totals.add(tx, "webhook_delivery", "held", 1, now)
            else
              @queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => delivery_id },
                             priority: DELIVERY_PRIORITY, correlation_id: event["correlation_id"], queue: DELIVERY_QUEUE)
            end
          end
          @notifications.for_event(tx, event)
          @subscribers.each { |subscriber| subscriber.call(tx, event) }
          @webhooks.mark_dispatched(tx, event["id"], now)
          :dispatched
        end
      end

      # Entrega de um webhook: assinatura com timestamp e identificador estável. A chamada de rede
      # ocorre fora de transação; o resultado é gravado em transação curta. A chamada é registrada
      # (`external.call`, serviço "webhook") com a organização e o correlation_id da tarefa, que é o
      # request_id da operação que gerou o evento. Portas: `http.post(url, body, headers)`,
      # `box.decrypt(texto)` e `signer.header(segredo, timestamp, corpo)`.
      #
      # Circuito por endpoint: cada tentativa com falha (status fora de 2xx, rede, tempo, destino
      # bloqueado) soma uma falha consecutiva, e um sucesso zera a sequência, na mesma transação que
      # grava a tentativa; com o endpoint já pausado, o sucesso em voo não zera (a reativação zera).
      # Com Domain::Webhooks::Circuit.trip? o endpoint é pausado uma única vez e a pausa é auditada
      # como ação do sistema (sem a URL). Endpoint pausado: a entrega é retida sem chamada de rede e
      # sem gastar tentativa, e a tarefa conclui com `:endpoint_paused`.
      class Deliver
        HTTP_OUTCOME = ->(response) { response.status.between?(200, 299) ? "ok" : "http_#{response.status / 100}xx" }
        AUDIT_ERROR_LENGTH = 200

        def initialize(transactor:, webhooks:, http:, box:, signer:, clock:, calls:, totals:, audit:)
          @transactor = transactor
          @webhooks = webhooks
          @http = http
          @box = box
          @signer = signer
          @clock = clock
          @calls = calls
          @totals = totals
          @audit = audit
        end

        def call(organization_id, delivery_id, correlation_id: nil)
          data = @transactor.call(tenant_id: organization_id) { |tx| @webhooks.delivery_bundle(tx, delivery_id) }
          return :missing unless data
          return :already_delivered if data["status"] == "delivered"
          return :endpoint_disabled unless data["active"]
          return :endpoint_paused if data["paused_at"] && hold(organization_id, data)

          outcome = attempt(data["url"], *request(organization_id, delivery_id, data), context(organization_id, delivery_id, data, correlation_id))
          @transactor.call(tenant_id: organization_id) do |tx|
            now = @clock.now
            if @webhooks.record_attempt(tx, delivery_id, outcome, now) == 1
              @totals.add(tx, "webhook_delivery", outcome[:success] ? "delivered" : "failed", 1, now)
              track_circuit(tx, data["endpoint_id"], outcome, correlation_id, now)
            end
          end
          raise DeliveryFailed, outcome[:error] || "status #{outcome[:status]}" unless outcome[:success]

          :delivered
        end

        class DeliveryFailed < StandardError; end

        private

        # Verdadeiro quando a entrega ficou retida. Falso quando o endpoint foi reativado entre a leitura
        # e a retenção: a entrega segue normalmente.
        def hold(organization_id, data)
          @transactor.call(tenant_id: organization_id) do |tx|
            now = @clock.now
            next false unless @webhooks.hold_delivery(tx, data["id"], data["endpoint_id"], now) == 1

            @totals.add(tx, "webhook_delivery", "held", 1, now)
            true
          end
        end

        def request(organization_id, delivery_id, data)
          body = JSON.generate("id" => data["event_id"], "type" => data["event_type"], "occurred_at" => data["occurred_at"].utc.iso8601,
                               "organization_id" => organization_id, "data" => data["payload"])
          timestamp = @clock.now.to_i
          headers = { "x-locentra-event-id" => data["event_id"], "x-locentra-delivery-id" => delivery_id, "x-locentra-event" => data["event_type"],
                      "x-locentra-signature" => @signer.header(@box.decrypt(data["secret_ciphertext"]), timestamp, body) }
          [body, headers]
        end

        def context(organization_id, delivery_id, data, correlation_id)
          { organization_id: organization_id, correlation_id: correlation_id, details: { delivery_id: delivery_id, event_type: data["event_type"] } }
        end

        def track_circuit(tx, endpoint_id, outcome, correlation_id, now)
          state = @webhooks.register_endpoint_result(tx, endpoint_id, outcome[:success], now)
          return if outcome[:success] || state.nil? || !state["active"] || state["paused_at"]

          failures = state["consecutive_failures"]
          return unless Domain::Webhooks::Circuit.trip?(consecutive_failures: failures, failing_since: state["failing_since"], now: now)
          return unless @webhooks.pause_endpoint(tx, endpoint_id, now) == 1

          @totals.add(tx, "webhook_circuit", "paused", 1, now)
          actor = Actor.system(organization_id: tx.tenant_id!, request_id: correlation_id)
          @audit.record(tx, actor, "webhook.endpoint_paused", "webhook_endpoint", endpoint_id,
                        "consecutive_failures" => failures, "failing_since" => state["failing_since"].utc.iso8601,
                        "last_status_code" => outcome[:status], "last_error" => Jobs::ErrorText.redact(outcome[:error])&.slice(0, AUDIT_ERROR_LENGTH))
        end

        def attempt(url, body, headers, context)
          blocked = { Integrations::UnsafeDestination => "blocked" }
          response = @calls.track(service: "webhook", operation: "deliver", outcome: HTTP_OUTCOME, errors: blocked, **context) do
            @http.post(url, body, headers)
          end
          { success: response.status.between?(200, 299), status: response.status,
            error: response.status.between?(300, 399) ? "redirecionamento não seguido" : nil }
        rescue Integrations::UnsafeDestination => e
          { success: false, status: nil, error: "destino bloqueado: #{e.message}" }
        rescue StandardError => e
          { success: false, status: nil, error: "#{e.class.name}: #{e.message}"[0, 300] }
        end
      end

      # Reativação de um endpoint pausado pelo circuito, somente pela interface web e com
      # `integrations.manage`. O FOR UPDATE no endpoint espera despachos e retenções em andamento (FOR
      # KEY SHARE): depois do commit, nenhuma entrega nova é retida. O circuito é zerado e uma única
      # tarefa de liberação é enfileirada quando há entregas retidas.
      class ResumeEndpoint
        def initialize(uow:, webhooks:, queue:, audit:)
          @uow = uow
          @webhooks = webhooks
          @queue = queue
          @audit = audit
        end

        def call(actor, endpoint_id)
          @uow.run(actor, "integrations.manage") do |tx, current|
            Authorizer.confirmed_email!(current, "webhooks.resume")
            id = Domain::Identifier.parse(endpoint_id, "endpoint")
            endpoint = @webhooks.lock_endpoint(tx, id) || raise(Domain::NotFound, "endpoint")
            raise Domain::Conflict.new("endpoint desativado não pode ser reativado", code: "endpoint_disabled") unless endpoint["active"]
            raise Domain::Conflict.new("endpoint não está pausado", code: "endpoint_not_paused") unless endpoint["paused_at"]

            held = @webhooks.held_count(tx, id)
            @webhooks.resume_endpoint(tx, id)
            @queue.enqueue(tx, RELEASE_KIND, { "endpoint_id" => id }, priority: RELEASE_PRIORITY, correlation_id: current.request_id) if held.positive?
            @audit.record(tx, current, "webhook.endpoint_resumed", "webhook_endpoint", id,
                          "paused_at" => endpoint["paused_at"].utc.iso8601, "consecutive_failures" => endpoint["consecutive_failures"],
                          "held_deliveries" => held)
            { "id" => id, "held_deliveries" => held }
          end
        end
      end

      # Liberação de um lote de entregas retidas (worker, contexto do tenant): devolve-as a `pending`,
      # enfileira uma entrega por item (sujeita ao limite por organização da fila de webhooks) e se
      # reagenda enquanto o lote vier cheio. Endpoint pausado de novo ou desativado interrompe a
      # liberação; as entregas restantes continuam retidas.
      class ReleaseHeld
        def initialize(transactor:, webhooks:, queue:, totals:, clock:, batch_size: RELEASE_BATCH)
          @transactor = transactor
          @webhooks = webhooks
          @queue = queue
          @totals = totals
          @clock = clock
          @batch_size = batch_size
        end

        def call(organization_id, endpoint_id, correlation_id: nil)
          @transactor.call(tenant_id: organization_id) do |tx|
            endpoint = @webhooks.lock_endpoint_for_release(tx, endpoint_id)
            next :missing unless endpoint
            next :endpoint_paused if !endpoint["active"] || endpoint["paused_at"]

            ids = @webhooks.release_held(tx, endpoint_id, @batch_size)
            ids.each do |id|
              @queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => id }, priority: DELIVERY_PRIORITY, correlation_id: correlation_id,
                                                                              queue: DELIVERY_QUEUE)
            end
            @totals.add(tx, "webhook_delivery", "released", ids.size, @clock.now)
            if ids.size == @batch_size
              @queue.enqueue(tx, RELEASE_KIND, { "endpoint_id" => endpoint_id }, priority: RELEASE_PRIORITY, correlation_id: correlation_id)
            end
            ids.size
          end
        end
      end
    end
  end
end
