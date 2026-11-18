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
          inserted = @inbound.insert(tx, "id" => id, "provider" => account["provider"], "provider_account_id" => account["id"],
                                         "event_id" => event.event_id, "event_type" => event.event_type, "payload" => body.to_s,
                                         "received_at" => @clock.now)
          return :duplicate unless inserted

          @queue.enqueue(tx, "payments.process_webhook", { "inbound_webhook_id" => id }, priority: 25)
          :accepted
        end
      end

      # Processamento de um webhook persistido. Idempotente: o registro é bloqueado e só é tratado
      # enquanto 'received'. O evento só altera pagamentos da conta que o recebeu e da cobrança
      # associada ao pagamento:
      # - confirmação de pagamento em aberto pela cobrança associada (ou ainda sem cobrança) confirma;
      # - confirmação por outra cobrança com a mesma referência (duplicada) confirma o dinheiro, associa
      #   o pagamento à cobrança paga, marca revisão e cria alerta para cancelar a outra;
      # - confirmação para pagamento já concluído por outra cobrança, cancelado ou falho não é lançada:
      #   cria alerta para decisão (reembolso no provedor ou registro manual);
      # - remoção de outra cobrança que não a associada não cancela o pagamento.
      class ProcessWebhook
        def initialize(uow:, inbound:, payments:, providers:, settlement:, alert_book:, clock:)
          @uow = uow
          @inbound = inbound
          @payments = payments
          @providers = providers
          @settlement = settlement
          @alert_book = alert_book
          @clock = clock
        end

        def call(actor, inbound_id)
          @uow.run(actor, "finance.write") do |tx, current|
            row = @inbound.lock(tx, Domain::Identifier.parse(inbound_id, "webhook")) || raise(Domain::NotFound, "webhook")
            next :"already_#{row["status"]}" unless row["status"] == "received"

            event = @providers.for(row["provider"]).parse_webhook(row["payload_text"])
            status, note = handle(tx, current, row["provider_account_id"], event)
            @inbound.finish(tx, row["id"], status, note, @clock.now)
            status.to_sym
          end
        end

        private

        def handle(tx, actor, account_id, event)
          payment = account_id && find_payment(tx, account_id, event)
          return ["ignored", "pagamento não encontrado para o evento"] unless payment
          return ["ignored", "pagamento de outra conta do provedor"] unless payment.provider_account_id == account_id

          case event.action
          when "confirm" then confirm(tx, actor, payment, event)
          when "cancel" then cancel(tx, payment, event)
          else ["ignored", "evento informativo #{event.event_type}"]
          end
        end

        def find_payment(tx, account_id, event)
          by_reference = Domain::Identifier.valid?(event.external_reference) && @payments.lock(tx, event.external_reference.downcase)
          by_reference || (event.provider_payment_id && @payments.lock_by_provider_id(tx, account_id, event.provider_payment_id))
        end

        def confirm(tx, actor, payment, event)
          linked = payment.provider_payment_id
          same_charge = linked.nil? || linked == event.provider_payment_id
          return ["ignored", "pagamento já confirmado"] if payment.confirmed? && same_charge
          return unmatched(tx, payment, event) if payment.final?

          if same_charge
            @settlement.confirm(tx, actor, payment.adopt(event.provider_payment_id, nil), from: payment.status, received: event.amount)
            return ["processed", nil]
          end

          duplicate = F::Review.paid_through_duplicate(linked, event.provider_payment_id)
          @settlement.confirm(tx, actor, payment.relink(event.provider_payment_id), from: payment.status, received: event.amount, extra: [duplicate])
          ["processed", "pago pela cobrança duplicada #{event.provider_payment_id}"]
        end

        def unmatched(tx, payment, event)
          kind, message = F::Review.unmatched_receipt(payment, event.provider_payment_id, event.amount)
          @alert_book.raise_alert(tx, kind: kind, message: message, dedupe_key: "receipt:#{payment.id}:#{event.provider_payment_id}",
                                      reservation_id: payment.reservation_id, payment_id: payment.id)
          ["ignored", "recebimento para pagamento #{payment.status_label.downcase}; alerta criado para decisão"]
        end

        def cancel(tx, payment, event)
          return ["ignored", "pagamento #{payment.status_label.downcase}"] if payment.final?

          linked = payment.provider_payment_id
          return ["ignored", "remoção de cobrança diferente da associada (#{linked})"] if linked && linked != event.provider_payment_id

          cancelled = payment.adopt(event.provider_payment_id, nil).cancel("cobrança removida no provedor")
          @payments.update(tx, cancelled, from: payment.status, now: @clock.now)
          ["processed", nil]
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
