# frozen_string_literal: true

module Locentra
  module Interfaces
    module Worker
      # Tarefas do financeiro. Cada tarefa executa um caso de uso com o ator de sistema do tenant da
      # própria tarefa. Chamadas ao provedor ocorrem fora de transação, dentro dos casos de uso.
      class FinanceHandlers
        RECONCILE_PRIORITY = 80

        def initialize(system)
          @system = system
        end

        def map
          {
            "finance.sync_reservation" => method(:sync_reservation),
            "payments.submit" => method(:submit),
            "payments.process_webhook" => method(:process_webhook),
            "payments.refund" => method(:refund),
            "finance.reconcile" => method(:reconcile)
          }
        end

        # Conciliação periódica: uma tarefa por organização com conta de provedor ativa, por hora
        # (chave única por janela, sem duplicar entre workers).
        def schedule_reconciliation(job)
          hour = job.payload.fetch("bucket", @system.clock.now.utc.iso8601)[0, 13]
          @system.transactor.call(tenant_id: job.organization_id) do |tx|
            next nil unless @system.repos[:payment_accounts].active(tx)

            @system.queue.enqueue(tx, "finance.reconcile", {}, unique_key: "finance-reconcile:#{job.organization_id}:#{hour}",
                                                               priority: RECONCILE_PRIORITY)
          end
        end

        private

        def uc(name) = @system.use_cases[name]
        def actor(job) = Application::Actor.system(organization_id: job.organization_id, request_id: job.correlation_id)

        def sync_reservation(job)
          permanent { uc(:sync_reservation_charges).call(actor(job), job.payload.fetch("reservation_id")).size }
        end

        def submit(job) = permanent { uc(:submit_payment).call(actor(job), job.payload.fetch("payment_id")) }
        def process_webhook(job) = permanent { uc(:process_payment_webhook).call(actor(job), job.payload.fetch("inbound_webhook_id")) }
        def refund(job) = permanent { uc(:process_refund).call(actor(job), job.payload.fetch("refund_id")) }
        def reconcile(job) = permanent { uc(:reconcile_payments).call(actor(job)) }

        # Dados inválidos ou recurso inexistente não melhoram com novas tentativas.
        def permanent
          yield
        rescue Domain::NotFound, Domain::ValidationError, Domain::InvalidTransition => e
          raise PermanentFailure, "#{e.class.name.split("::").last}: #{e.message}"
        end
      end
    end
  end
end
