# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Consulta ao provedor de um pagamento com envio sem confirmação. Nenhum novo envio acontece sem
      # antes procurar a cobrança pela referência externa: encontrada, a situação remota é adotada;
      # ausente numa consulta feita depois da janela da última tentativa, o pagamento volta para envio
      # com a mesma referência. Antes da janela, a consulta não é conclusiva (a requisição da tentativa
      # pode estar em andamento) e uma nova consulta é agendada para o fim da janela.
      class ResolveSubmission
        OUTCOME_ACTIONS = { resolved: "local_updated", resubmission_scheduled: "resubmission_scheduled", awaiting_settlement: "check_scheduled" }.freeze
        # Entre cobranças com a mesma referência, a associada é a que recebeu o dinheiro ou ainda pode
        # recebê-lo; uma cobrança removida só é adotada se não houver outra.
        ADOPTION_ORDER = %w[confirmed refunded disputed pending cancelled].freeze

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

          found = Lookup.perform(@providers, prepared[:account], prepared[:payment], @clock, actor: actor)
          @uow.run(actor, "finance.write") { |tx, current| resolve(tx, current, id, found) }
        end

        # Aplica o resultado de uma consulta (também dentro da transação da conciliação).
        def resolve(tx, actor, id, lookup)
          payment = @payments.lock(tx, id)
          return :"already_#{payment.status}" unless payment.status == "submission_unknown"
          # Uma tentativa nova começou depois da consulta: o resultado dela decide.
          return :superseded unless payment.submission_attempts == lookup.attempt
          return adopt(tx, actor, payment, lookup.charges) unless lookup.charges.empty?
          return await(tx, actor, payment) unless payment.submission_settled?(lookup.at)

          @payments.update(tx, payment.transition("pending_submission"), from: payment.status, now: @clock.now)
          @queue.enqueue(tx, "payments.submit", { "payment_id" => id }, priority: 30, correlation_id: actor.request_id)
          @audit.record(tx, actor, "payment.resubmission_scheduled", "payment", id, "external_reference" => payment.external_reference)
          :resubmission_scheduled
        end

        # Nova consulta ao fim da janela da tentativa atual (uma por tentativa), com a correlação da
        # operação que originou o envio.
        def schedule_check(tx, payment, actor)
          @queue.enqueue(tx, "payments.submit", { "payment_id" => payment.id }, run_at: payment.settles_at, priority: 30,
                                                                                unique_key: "payment-check:#{payment.id}:#{payment.submission_attempts}",
                                                                                correlation_id: actor.request_id)
        end

        private

        def adopt(tx, actor, payment, found)
          chosen = found.min_by { |charge| ADOPTION_ORDER.index(charge.status) || ADOPTION_ORDER.size }
          flag_duplicates(tx, payment, found, chosen)
          @remote.apply(tx, actor, payment, chosen)
          @audit.record(tx, actor, "payment.submission_resolved", "payment", payment.id,
                        "provider_payment_id" => chosen.provider_payment_id, "remote_status" => chosen.status)
          :resolved
        end

        def await(tx, actor, payment)
          schedule_check(tx, payment, actor)
          @audit.record(tx, actor, "payment.submission_check_scheduled", "payment", payment.id, "run_at" => payment.settles_at.utc.iso8601)
          :awaiting_settlement
        end

        def flag_duplicates(tx, payment, found, chosen)
          return if found.size < 2

          @alert_book.raise_alert(tx, kind: "duplicate_provider_charge", dedupe_key: "duplicate_charge:#{payment.id}",
                                      reservation_id: payment.reservation_id, payment_id: payment.id,
                                      message: "O provedor tem #{found.size} cobranças com a referência #{payment.external_reference}; " \
                                               "a cobrança #{chosen.provider_payment_id} foi associada ao pagamento e as demais precisam " \
                                               "ser canceladas no provedor.")
        end
      end

      # Envio de uma cobrança ao provedor, executado pelo worker. Transação curta para registrar a
      # tentativa (submission_unknown) ANTES da chamada de rede, chamada sem transação aberta e
      # transação curta para registrar o resultado. Uma reexecução da tarefa (queda do processo, lease
      # vencido, erro ao registrar) ou uma segunda tarefa do mesmo pagamento encontra o pagamento em
      # submission_unknown e passa pela consulta ao provedor, nunca por um novo envio às cegas.
      class SubmitPayment
        RECHECK_DELAY = F::SUBMISSION_WINDOW_SECONDS

        def initialize(uow:, payments:, accounts:, customers:, reservations:, providers:, remote:, resolver:, alert_book:, audit:, clock:)
          @uow = uow
          @payments = payments
          @accounts = accounts
          @customers = customers
          @reservations = reservations
          @providers = providers
          @remote = remote
          @resolver = resolver
          @alert_book = alert_book
          @audit = audit
          @clock = clock
        end

        def call(actor, payment_id)
          id = Domain::Identifier.parse(payment_id, "pagamento")
          prepared = @uow.run(actor, "finance.write") { |tx, current| prepare(tx, current, id) }
          return @resolver.call(actor, id) if prepared == :resolve
          return prepared unless prepared.is_a?(Hash)

          outcome = submit(actor, prepared)
          result = @uow.run(actor, "finance.write") { |tx, current| record(tx, current, id, prepared[:attempt], outcome) }
          # Requisição não enviada: a fila reagenda a tarefa com espera crescente.
          raise outcome.last if result == :not_sent

          result
        end

        private

        def prepare(tx, actor, id)
          payment = @payments.lock(tx, id) || raise(Domain::NotFound, "pagamento")
          return :resolve if payment.status == "submission_unknown"
          return :"already_#{payment.status}" unless payment.status == "pending_submission"

          account = @accounts.find(tx, payment.provider_account_id)
          return reject(tx, actor, payment, "conta do provedor desativada antes do envio") unless account && account["active"]

          started = payment.begin_submission(@clock.now)
          @payments.update(tx, started, from: payment.status, now: @clock.now)
          { account: account, request: request_for(tx, payment), attempt: started.submission_attempts }
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

        # Qualquer outra exceção deixa o pagamento em submission_unknown (já gravado): a nova execução
        # da tarefa consulta o provedor antes de decidir.
        def submit(actor, prepared)
          [:created, @providers.for(prepared[:account]["provider"], actor: actor).create_charge(prepared[:account], prepared[:request])]
        rescue ProviderTimeout => e
          [:unknown, e.message]
        rescue ProviderRejected => e
          [:rejected, e.message]
        rescue ProviderUnavailable => e
          [:not_sent, e]
        end

        def record(tx, actor, id, attempt, outcome)
          kind, value = outcome
          payment = @payments.lock(tx, id)
          unless payment.status == "submission_unknown" && payment.submission_attempts == attempt
            stray(tx, payment, value) if kind == :created
            return :"already_#{payment.status}"
          end

          case kind
          when :created
            @remote.apply(tx, actor, payment, value)
            @audit.record(tx, actor, "payment.submitted", "payment", id, "provider_payment_id" => value.provider_payment_id)
            :submitted
          when :unknown
            @resolver.schedule_check(tx, payment, actor)
            @audit.record(tx, actor, "payment.submission_unknown", "payment", id, "error" => value.to_s[0, 300])
            :submission_unknown
          when :not_sent
            @payments.update(tx, payment.transition("pending_submission"), from: payment.status, now: @clock.now)
            @audit.record(tx, actor, "payment.submission_not_sent", "payment", id, "error" => value.message.to_s[0, 300])
            :not_sent
          else
            reject(tx, actor, payment, value)
          end
        end

        # Resposta de uma tentativa que chegou depois de o pagamento seguir adiante (por outra tentativa,
        # pela consulta ou por webhook). Uma cobrança diferente da associada é duplicada.
        def stray(tx, payment, charge)
          return if charge.provider_payment_id == payment.provider_payment_id

          @alert_book.raise_alert(tx, kind: "duplicate_provider_charge", dedupe_key: "duplicate_charge:#{payment.id}:#{charge.provider_payment_id}",
                                      reservation_id: payment.reservation_id, payment_id: payment.id,
                                      message: "A tentativa de envio criou a cobrança #{charge.provider_payment_id} depois de o pagamento ser " \
                                               "resolvido por outra via; cancele-a no provedor se não for a cobrança associada.")
        end

        def reject(tx, actor, payment, reason)
          @payments.update(tx, payment.fail(reason), from: payment.status, now: @clock.now)
          @audit.record(tx, actor, "payment.failed", "payment", payment.id, "reason" => reason.to_s[0, 300])
          :failed
        end
      end

      # Execução de reembolso no provedor. Antes de pedir o estorno, os reembolsos já registrados no
      # provedor são consultados pela descrição estável: uma nova tentativa após tempo esgotado não
      # estorna duas vezes. A situação devolvida pelo provedor decide: concluído confirma; em andamento
      # (pendente ou aguardando autorização) mantém o reembolso pendente com nova consulta agendada;
      # cancelado no provedor falha (sem novo pedido automático: a decisão foi tomada no provedor).
      class ProcessRefund
        RECHECK_DELAY = 1800

        def initialize(uow:, payments:, accounts:, providers:, ledger:, queue:, audit:, events:, clock:)
          @uow = uow
          @payments = payments
          @accounts = accounts
          @providers = providers
          @ledger = ledger
          @queue = queue
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

          outcome = execute(actor, prepared)
          @uow.run(actor, "finance.refund") { |tx, current| record(tx, current, id, outcome) }
        end

        private

        def execute(actor, prepared)
          provider = @providers.for(prepared[:account]["provider"], actor: actor)
          account = prepared[:account]
          charge = prepared[:payment].provider_payment_id
          refund = prepared[:refund]
          previous = provider.refunds(account, charge).select { |r| r.description.to_s.include?(refund.id) }
          return outcome_of(previous) unless previous.empty?

          outcome_of([provider.refund(account, charge, amount: refund.amount, description: refund.provider_description)])
        rescue ProviderRejected => e
          [:failed, e.message]
        end

        def outcome_of(items)
          done = items.find(&:done?)
          return [:confirmed, done.reference] if done
          return [:pending, nil] unless items.all?(&:cancelled?)

          [:failed, "estorno cancelado no provedor"]
        end

        def record(tx, actor, id, outcome)
          kind, value = outcome
          refund = @payments.lock_refund(tx, id)
          return :"already_#{refund.status}" unless refund.pending?

          case kind
          when :confirmed
            done = refund.confirm(@clock.now, value)
            @payments.update_refund(tx, done, from: refund.status, now: @clock.now)
            RefundCompletion.confirmed(tx, actor, done, ledger: @ledger, audit: @audit, events: @events)
          when :pending
            return recheck(tx, actor, refund)
          else
            done = refund.fail(value)
            @payments.update_refund(tx, done, from: refund.status, now: @clock.now)
            RefundCompletion.failed(tx, actor, done, ledger: @ledger, audit: @audit)
          end
          done.status.to_sym
        end

        # Estorno em andamento no provedor: o reembolso continua pendente (o valor segue comprometido)
        # e a situação é consultada de novo, uma tarefa por janela.
        def recheck(tx, actor, refund)
          run_at = @clock.now + RECHECK_DELAY
          @queue.enqueue(tx, "payments.refund", { "refund_id" => refund.id }, run_at: run_at, priority: 40,
                                                                              unique_key: "refund-check:#{refund.id}:#{run_at.to_i / RECHECK_DELAY}",
                                                                              correlation_id: actor.request_id)
          :pending
        end
      end
    end
  end
end
