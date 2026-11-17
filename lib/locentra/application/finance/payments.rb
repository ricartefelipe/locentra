# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Alvo de um pagamento (cobrança ou caução) com o valor que ainda pode ser recebido.
      class PaymentTarget
        def initialize(receivables:, deposits:)
          @receivables = receivables
          @deposits = deposits
        end

        def permission(purpose) = purpose == "deposit" ? "deposits.manage" : "finance.write"

        # Retorna { id:, reservation_id:, customer_id:, open: Money, cancelled: bool } com lock no alvo.
        def lock!(tx, purpose, target_id)
          case purpose
          when "receivable"
            receivable = @receivables.lock(tx, Domain::Identifier.parse(target_id, "cobranca")) || raise(Domain::NotFound, "cobrança")
            balance = @receivables.balance(tx, receivable.id)
            { id: receivable.id, reservation_id: receivable.reservation_id, customer_id: receivable.customer_id, open: balance.open_amount,
              cancelled: balance.cancelled? }
          when "deposit"
            deposit = @deposits.lock(tx, Domain::Identifier.parse(target_id, "caucao")) || raise(Domain::NotFound, "caução")
            ledger = @deposits.ledger(tx, deposit.id)
            { id: deposit.id, reservation_id: deposit.reservation_id, customer_id: deposit.customer_id,
              open: ledger.remaining(deposit.expected), cancelled: false }
          else raise Domain::ValidationError.field("finalidade", "use cobrança ou caução")
          end
        end

        def check_amount!(target, amount)
          raise Domain::Conflict.new("Cobrança cancelada não recebe pagamentos", code: "receivable_cancelled") if target[:cancelled]
          return amount if amount <= target[:open]

          raise Domain::Conflict.new("Valor acima do saldo em aberto (#{target[:open].format_brl})", code: "amount_exceeds_open_balance")
        end
      end

      # Registro manual de pagamento recebido fora do provedor (dinheiro, transferência, maquininha).
      # Nasce confirmado; pagamento de reserva expirada ou cancelada é confirmado e enviado para revisão.
      class RegisterPayment
        include Composable

        def initialize(uow:, payments:, target:, settlement:, clock:, ids:)
          @uow = uow
          @payments = payments
          @target = target
          @settlement = settlement
          @clock = clock
          @ids = ids
        end

        # input: purpose, receivable_id | deposit_id, method, amount (Money), paid_at (Time), notes.
        def call(actor, input, tx: nil)
          purpose = input.fetch(:purpose, "receivable").to_s
          within(actor, @target.permission(purpose), tx) do |t, current|
            target = @target.lock!(t, purpose, purpose == "deposit" ? input[:deposit_id] : input[:receivable_id])
            amount = @target.check_amount!(target, F::Amount.positive!(input[:amount]))
            paid_at = paid_at!(input[:paid_at])
            found = @settlement.findings(t, target[:reservation_id])
            payment = F::Payment.manual(id: @ids.uuid, organization_id: t.tenant_id!, purpose: purpose, target_id: target[:id],
                                        reservation_id: target[:reservation_id], customer_id: target[:customer_id], payment_method: input[:method].to_s,
                                        amount: amount, paid_at: paid_at, review_reason: F::Review.reason_text(found), notes: input[:notes])
            @payments.insert(t, payment, current.audit_actor_id, @clock.now)
            @settlement.effects(t, current, payment, found)
            payment
          end
        end

        private

        def paid_at!(value)
          now = @clock.now
          return now if value.nil?
          raise Domain::ValidationError.field("pago_em", "não pode estar no futuro") if value > now

          value
        end
      end

      # Cobrança pelo provedor configurado (simulador ou Asaas). O envio ocorre no worker
      # ('payments.submit'), fora de transação, com a referência externa estável (id do pagamento).
      class RequestPayment
        DEFAULT_DUE_DAYS = 3

        def initialize(uow:, payments:, accounts:, organizations:, target:, queue:, audit:, clock:, ids:)
          @uow = uow
          @payments = payments
          @accounts = accounts
          @organizations = organizations
          @target = target
          @queue = queue
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # input: purpose, receivable_id | deposit_id, method, amount (Money), due_on (Date), scenario, notes.
        def call(actor, input)
          purpose = input.fetch(:purpose, "receivable").to_s
          @uow.run(actor, @target.permission(purpose)) do |tx, current|
            account = @accounts.active(tx) || raise(Domain::ValidationError.field("provedor", "configure um provedor de pagamentos ativo"))
            target = @target.lock!(tx, purpose, purpose == "deposit" ? input[:deposit_id] : input[:receivable_id])
            amount = @target.check_amount!(target, F::Amount.positive!(input[:amount]))
            payment = F::Payment.request(id: @ids.uuid, organization_id: tx.tenant_id!, purpose: purpose, target_id: target[:id],
                                         reservation_id: target[:reservation_id], customer_id: target[:customer_id], payment_method: input[:method].to_s,
                                         amount: amount, provider: account["provider"], account_id: account["id"], due_on: due_on!(tx, input[:due_on]),
                                         scenario: input[:scenario], notes: input[:notes])
            @payments.insert(tx, payment, current.audit_actor_id, @clock.now)
            @queue.enqueue(tx, "payments.submit", { "payment_id" => payment.id }, priority: 30, correlation_id: current.request_id)
            @audit.record(tx, current, "payment.requested", "payment", payment.id,
                          "provider" => payment.provider, "method" => payment.payment_method, "amount_cents" => payment.amount.cents,
                          "scenario" => payment.simulator_scenario)
            payment
          end
        end

        private

        def due_on!(tx, value)
          today = @organizations.find(tx, tx.tenant_id!).time_zone.local_date(@clock.now)
          return today + DEFAULT_DUE_DAYS if value.nil?
          raise Domain::ValidationError.field("vencimento", "não pode estar no passado") if value < today

          value
        end
      end

      # Reembolso de pagamento de cobrança. O pagamento é bloqueado (FOR UPDATE) antes de somar os
      # reembolsos pendentes e confirmados: pedidos concorrentes acima do saldo elegível são recusados.
      class RequestRefund
        include Composable

        def initialize(uow:, payments:, ledger:, queue:, audit:, events:, clock:, ids:)
          @uow = uow
          @payments = payments
          @ledger = ledger
          @queue = queue
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        def call(actor, payment_id, amount:, reason:, tx: nil)
          within(actor, "finance.refund", tx) do |t, current|
            payment = @payments.lock(t, Domain::Identifier.parse(payment_id, "pagamento")) || raise(Domain::NotFound, "pagamento")
            F::RefundPolicy.check!(payment, committed: @payments.committed_refunds(t, payment.id), amount: amount)
            refund = F::Refund.build(id: @ids.uuid, organization_id: t.tenant_id!, payment: payment, amount: amount, reason: reason, now: @clock.now)
            @payments.insert_refund(t, refund, current.audit_actor_id, @clock.now)
            @ledger.post(t, F::Postings.refund_requested(refund.amount), source_type: "refund", source_id: refund.id)
            record(t, current, payment, refund)
            refund
          end
        end

        private

        def record(tx, actor, payment, refund)
          @audit.record(tx, actor, "refund.requested", "payment", payment.id, "refund_id" => refund.id, "amount_cents" => refund.amount.cents)
          if refund.pending?
            @queue.enqueue(tx, "payments.refund", { "refund_id" => refund.id }, priority: 30, correlation_id: actor.request_id)
          else
            RefundCompletion.confirmed(tx, actor, refund, ledger: @ledger, audit: @audit, events: @events)
          end
        end
      end

      # Efeitos da conclusão de um reembolso (compartilhado entre registro manual e provedor).
      module RefundCompletion
        module_function

        def confirmed(tx, actor, refund, ledger:, audit:, events:)
          ledger.post(tx, F::Postings.refund_confirmed(refund.amount), source_type: "refund", source_id: refund.id)
          audit.record(tx, actor, "refund.confirmed", "payment", refund.payment_id, "refund_id" => refund.id, "amount_cents" => refund.amount.cents)
          events.publish(tx, "payment.refunded", "payment", refund.payment_id, "refund_id" => refund.id, "amount_cents" => refund.amount.cents)
        end

        def failed(tx, actor, refund, ledger:, audit:)
          ledger.post(tx, F::Postings.refund_failed(refund.amount), source_type: "refund", source_id: refund.id)
          audit.record(tx, actor, "refund.failed", "payment", refund.payment_id, "refund_id" => refund.id, "reason" => refund.failure_reason)
        end
      end
    end
  end
end
