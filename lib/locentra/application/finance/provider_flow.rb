# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Consulta ao provedor de um pagamento com envio sem confirmação (tempo esgotado). Nenhum novo
      # envio acontece sem antes procurar a cobrança pela referência externa: encontrada, a situação
      # remota é adotada; ausente, o pagamento volta para envio com a mesma referência.
      class ResolveSubmission
        def initialize(uow:, payments:, accounts:, providers:, remote:, alert_book:, queue:, audit:, clock:)
          @uow = uow
          @clock = clock
          @payments = payments
          @accounts = accounts
          @providers = providers
          @remote = remote
          @alert_book = alert_book
          @queue = queue
          @audit = audit
        end

        def call(actor, payment_id)
          id = Domain::Identifier.parse(payment_id, "pagamento")
          prepared = @uow.run(actor, "finance.write") do |tx, _|
            payment = @payments.find(tx, id) || raise(Domain::NotFound, "pagamento")
            next :"already_#{payment.status}" unless payment.status == "submission_unknown"

            { payment: payment, account: @accounts.find(tx, payment.provider_account_id) }
          end
          return prepared unless prepared.is_a?(Hash)

          found = @providers.for(prepared[:account]["provider"]).find_by_external_reference(prepared[:account], prepared[:payment].external_reference)
          @uow.run(actor, "finance.write") { |tx, current| resolve(tx, current, id, found) }
        end

        # Também usado pela conciliação, dentro da transação dela.
        def resolve(tx, actor, id, found)
          payment = @payments.lock(tx, id)
          return :"already_#{payment.status}" unless payment.status == "submission_unknown"

          if found.empty?
            @payments.update(tx, payment.transition("pending_submission"), from: payment.status, now: @clock.now)
            @queue.enqueue(tx, "payments.submit", { "payment_id" => id }, priority: 30)
            @audit.record(tx, actor, "payment.resubmission_scheduled", "payment", id, "external_reference" => payment.external_reference)
            return :resubmission_scheduled
          end

          flag_duplicates(tx, payment, found)
          @remote.apply(tx, actor, payment, found.first)
          @audit.record(tx, actor, "payment.submission_resolved", "payment", id,
                        "provider_payment_id" => found.first.provider_payment_id, "remote_status" => found.first.status)
          :resolved
        end

        private

        def flag_duplicates(tx, payment, found)
          return if found.size < 2

          @alert_book.raise_alert(tx, kind: "duplicate_provider_charge", dedupe_key: "duplicate_charge:#{payment.id}",
                                      reservation_id: payment.reservation_id, payment_id: payment.id,
                                      message: "O provedor tem #{found.size} cobranças com a referência #{payment.external_reference}; " \
                                               "a primeira foi associada ao pagamento e as demais precisam ser canceladas no provedor.")
        end
      end

      # Envio de uma cobrança ao provedor, executado pelo worker. Transação curta para preparar,
      # chamada de rede sem transação aberta, transação curta para registrar o resultado.
      class SubmitPayment
        RECHECK_DELAY = 60

        def initialize(uow:, payments:, accounts:, customers:, reservations:, providers:, remote:, resolver:, queue:, audit:, clock:)
          @uow = uow
          @payments = payments
          @accounts = accounts
          @customers = customers
          @reservations = reservations
          @providers = providers
          @remote = remote
          @resolver = resolver
          @queue = queue
          @audit = audit
          @clock = clock
        end

        def call(actor, payment_id)
          id = Domain::Identifier.parse(payment_id, "pagamento")
          prepared = @uow.run(actor, "finance.write") { |tx, current| prepare(tx, current, id) }
          return @resolver.call(actor, id) if prepared == :resolve
          return prepared unless prepared.is_a?(Hash)

          outcome = submit(prepared)
          @uow.run(actor, "finance.write") { |tx, current| record(tx, current, id, outcome) }
        end

        private

        def prepare(tx, actor, id)
          payment = @payments.lock(tx, id) || raise(Domain::NotFound, "pagamento")
          return :resolve if payment.status == "submission_unknown"
          return :"already_#{payment.status}" unless payment.status == "pending_submission"

          account = @accounts.find(tx, payment.provider_account_id)
          return reject(tx, actor, payment, "conta do provedor desativada antes do envio") unless account && account["active"]

          @payments.update(tx, payment.attempt, from: payment.status, now: @clock.now)
          { account: account, request: request_for(tx, payment) }
        end

        def request_for(tx, payment)
          customer = @customers.find(tx, payment.customer_id)
          reservation = @reservations.find(tx, payment.reservation_id)
          ChargeRequest.new(external_reference: payment.external_reference, amount: payment.amount, payment_method: payment.payment_method,
                            due_on: payment.due_on,
                            description: "#{F::PAYMENT_PURPOSES.fetch(payment.purpose)} da reserva #{reservation.code}",
                            customer: CustomerRef.new(id: customer.id, name: customer.name, document: customer.document, email: customer.email),
                            scenario: payment.simulator_scenario)
        end

        # ProviderUnavailable não é tratado aqui: a requisição não saiu, o pagamento continua aguardando
        # envio e a tarefa é reagendada pela fila.
        def submit(prepared)
          [:created, @providers.for(prepared[:account]["provider"]).create_charge(prepared[:account], prepared[:request])]
        rescue ProviderTimeout => e
          [:unknown, e.message]
        rescue ProviderRejected => e
          [:rejected, e.message]
        end

        def record(tx, actor, id, outcome)
          kind, value = outcome
          payment = @payments.lock(tx, id)
          return :"already_#{payment.status}" unless payment.status == "pending_submission"

          case kind
          when :created
            @remote.apply(tx, actor, payment, value)
            @audit.record(tx, actor, "payment.submitted", "payment", id, "provider_payment_id" => value.provider_payment_id)
            :submitted
          when :unknown
            @payments.update(tx, payment.transition("submission_unknown"), from: payment.status, now: @clock.now)
            @queue.enqueue(tx, "payments.submit", { "payment_id" => id }, run_at: @clock.now + RECHECK_DELAY, priority: 30)
            @audit.record(tx, actor, "payment.submission_unknown", "payment", id, "error" => value.to_s[0, 300])
            :submission_unknown
          else
            reject(tx, actor, payment, value)
          end
        end

        def reject(tx, actor, payment, reason)
          @payments.update(tx, payment.fail(reason), from: payment.status, now: @clock.now)
          @audit.record(tx, actor, "payment.failed", "payment", payment.id, "reason" => reason.to_s[0, 300])
          :failed
        end
      end

      # Execução de reembolso no provedor. Antes de pedir o estorno, os reembolsos já registrados no
      # provedor são consultados pela descrição estável: uma nova tentativa após tempo esgotado não
      # estorna duas vezes.
      class ProcessRefund
        def initialize(uow:, payments:, accounts:, providers:, ledger:, audit:, events:, clock:)
          @uow = uow
          @payments = payments
          @accounts = accounts
          @providers = providers
          @ledger = ledger
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, refund_id)
          id = Domain::Identifier.parse(refund_id, "reembolso")
          prepared = @uow.run(actor, "finance.refund") do |tx, _|
            refund = @payments.find_refund(tx, id) || raise(Domain::NotFound, "reembolso")
            next :"already_#{refund.status}" unless refund.pending?

            payment = @payments.find(tx, refund.payment_id)
            { refund: refund, payment: payment, account: @accounts.find(tx, payment.provider_account_id) }
          end
          return prepared unless prepared.is_a?(Hash)

          outcome = execute(prepared)
          @uow.run(actor, "finance.refund") { |tx, current| record(tx, current, id, outcome) }
        end

        private

        def execute(prepared)
          provider = @providers.for(prepared[:account]["provider"])
          account = prepared[:account]
          payment = prepared[:payment]
          refund = prepared[:refund]
          existing = provider.refunds(account, payment.provider_payment_id).find { |r| r.description.to_s.include?(refund.id) }
          return [:confirmed, existing.reference] if existing

          [:confirmed, provider.refund(account, payment.provider_payment_id, amount: refund.amount, description: refund.provider_description).reference]
        rescue ProviderRejected => e
          [:failed, e.message]
        end

        def record(tx, actor, id, outcome)
          kind, value = outcome
          refund = @payments.lock_refund(tx, id)
          return :"already_#{refund.status}" unless refund.pending?

          if kind == :confirmed
            done = refund.confirm(@clock.now, value)
            @payments.update_refund(tx, done, from: refund.status, now: @clock.now)
            RefundCompletion.confirmed(tx, actor, done, ledger: @ledger, audit: @audit, events: @events)
          else
            done = refund.fail(value)
            @payments.update_refund(tx, done, from: refund.status, now: @clock.now)
            RefundCompletion.failed(tx, actor, done, ledger: @ledger, audit: @audit)
          end
          done.status.to_sym
        end
      end
    end
  end
end
