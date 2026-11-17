# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Recebimento de webhooks do provedor. O token é comparado em tempo constante com o resumo
      # armazenado da conta; o evento é persistido em inbound_webhooks (único por organização,
      # provedor e identificador do evento) ANTES de qualquer processamento, que ocorre na tarefa
      # 'payments.process_webhook'. Eventos repetidos não geram nova tarefa.
      class IngestWebhook
        def initialize(uow:, accounts:, inbound:, providers:, queue:, clock:, ids:)
          @uow = uow
          @accounts = accounts
          @inbound = inbound
          @providers = providers
          @queue = queue
          @clock = clock
          @ids = ids
        end

        # Requisição pública: retorna :accepted ou :duplicate; WebhookUnauthorized sem token válido.
        def call(account_id, token:, body:)
          raise WebhookUnauthorized, "conta inválida" unless Domain::Identifier.valid?(account_id)

          @uow.anonymous do |tx|
            account = @accounts.for_webhook(tx, account_id.to_s.downcase)
            authorized = TokenCheck.match?(account&.fetch("webhook_token_digest"), token)
            raise WebhookUnauthorized, "token inválido" unless authorized && account["active"]

            tx.switch_tenant!(account["organization_id"])
            store(tx, account, body)
          end
        end

        # Evento gerado internamente (simulador local), pelo mesmo caminho de persistência e deduplicação.
        def accept(account, body)
          @uow.anonymous(tenant_id: account["organization_id"]) { |tx| store(tx, account, body) }
        end

        private

        def store(tx, account, body)
          event = @providers.for(account["provider"]).parse_webhook(body)
          id = @ids.uuid
          inserted = @inbound.insert(tx, "id" => id, "provider" => account["provider"], "event_id" => event.event_id,
                                         "event_type" => event.event_type, "payload" => body.to_s, "received_at" => @clock.now)
          return :duplicate unless inserted

          @queue.enqueue(tx, "payments.process_webhook", { "inbound_webhook_id" => id }, priority: 25)
          :accepted
        end
      end

      # Processamento de um webhook persistido. Idempotente: o registro é bloqueado e só é tratado
      # enquanto 'received'; confirmação de pagamento já confirmado não tem efeito.
      class ProcessWebhook
        def initialize(uow:, inbound:, payments:, providers:, settlement:, clock:)
          @uow = uow
          @inbound = inbound
          @payments = payments
          @providers = providers
          @settlement = settlement
          @clock = clock
        end

        def call(actor, inbound_id)
          @uow.run(actor, "finance.write") do |tx, current|
            row = @inbound.lock(tx, Domain::Identifier.parse(inbound_id, "webhook")) || raise(Domain::NotFound, "webhook")
            next :"already_#{row["status"]}" unless row["status"] == "received"

            event = @providers.for(row["provider"]).parse_webhook(row["payload_text"])
            payment = find_payment(tx, event)
            status, note = payment ? apply(tx, current, payment, event) : ["ignored", "pagamento não encontrado para o evento"]
            @inbound.finish(tx, row["id"], status, note, @clock.now)
            status.to_sym
          end
        end

        private

        def find_payment(tx, event)
          by_reference = Domain::Identifier.valid?(event.external_reference) && @payments.lock(tx, event.external_reference.downcase)
          by_reference || (event.provider_payment_id && @payments.lock_by_provider_id(tx, event.provider_payment_id))
        end

        def apply(tx, actor, payment, event)
          case event.action
          when "confirm"
            return ["ignored", "pagamento já confirmado"] if payment.confirmed?
            return ["ignored", "pagamento #{payment.status_label.downcase}"] if payment.final?

            @settlement.confirm(tx, actor, payment.adopt(event.provider_payment_id, nil), from: payment.status, received: event.amount)
            ["processed", nil]
          when "cancel"
            return ["ignored", "pagamento #{payment.status_label.downcase}"] if payment.final?

            @payments.update(tx, payment.cancel("cobrança removida no provedor"), from: payment.status, now: @clock.now)
            ["processed", nil]
          else
            ["ignored", "evento informativo #{event.event_type}"]
          end
        end
      end

      # Simulação de pagamento no provedor local: o simulador marca a cobrança como paga e emite o
      # evento no formato do provedor, ingerido pelo mesmo caminho de um webhook real.
      class SimulateProviderEvent
        def initialize(uow:, payments:, accounts:, simulator:, ingest:)
          @uow = uow
          @payments = payments
          @accounts = accounts
          @simulator = simulator
          @ingest = ingest
        end

        def call(actor, payment_id)
          payment, account = @uow.run(actor, "finance.write") do |tx, _|
            found = @payments.find(tx, Domain::Identifier.parse(payment_id, "pagamento")) || raise(Domain::NotFound, "pagamento")
            unless found.provider == "simulator" && found.provider_payment_id
              raise Domain::Conflict.new("Somente cobranças registradas no simulador podem ser simuladas", code: "not_simulated")
            end

            [found, @accounts.find(tx, found.provider_account_id)]
          end
          @ingest.accept(account, @simulator.settle(account, payment.provider_payment_id))
        end
      end
    end
  end
end
