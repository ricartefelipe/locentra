# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Cria as cobranças de uma reserva: locação (total da reserva confirmada, em andamento ou
      # concluída) e uma cobrança por ajuste com valor positivo; numa reserva cancelada, apenas a
      # multa de cancelamento. A origem é única no banco, portanto execuções repetidas (eventos
      # reentregues, botão na interface) não duplicam cobranças.
      class SyncReservationCharges
        include Composable

        def initialize(uow:, reservations:, organizations:, receivables:, ledger:, alert_book:, audit:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @organizations = organizations
          @receivables = receivables
          @ledger = ledger
          @alert_book = alert_book
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # `prepayment`: permite cobrança antecipada da locação de um bloqueio temporário.
        def call(actor, reservation_id, prepayment: false, tx: nil)
          within(actor, "finance.write", tx) do |t, current|
            reservation = @reservations.find(t, Domain::Identifier.parse(reservation_id, "reserva")) || raise(Domain::NotFound, "reserva")
            created = charge(t, current, reservation, prepayment)
            flag_closed(t, reservation)
            created
          end
        end

        private

        def charge(tx, actor, reservation, prepayment)
          rental = F::Charges.chargeable?(reservation.status, prepayment: prepayment)
          adjustments = @reservations.adjustments(tx, reservation.id).select do |adjustment|
            adjustment["amount_cents"].positive? && F::Charges.adjustment_chargeable?(adjustment["kind"], reservation.status, prepayment: prepayment)
          end
          return [] unless rental || adjustments.any?

          zone = @organizations.find(tx, tx.tenant_id!).time_zone
          created = []
          if rental && reservation.total.positive?
            created << issue(tx, actor, reservation, kind: "rental", source_type: "reservation", source_id: reservation.id,
                                                     description: F::Charges.rental_description(reservation.code), amount: reservation.total,
                                                     due_on: zone.local_date(reservation.period.starts_at))
          end
          adjustments.each do |adjustment|
            created << issue(tx, actor, reservation, kind: F::Charges.adjustment_kind(adjustment["kind"]), source_type: "reservation_adjustment",
                                                     source_id: adjustment["id"],
                                                     description: F::Charges.adjustment_description(adjustment["kind"], reservation.code),
                                                     amount: Domain::Money.new(adjustment["amount_cents"]), due_on: zone.local_date(adjustment["created_at"]))
          end
          created.compact
        end

        def issue(tx, actor, reservation, **attrs)
          receivable = F::Receivable.build(id: @ids.uuid, organization_id: tx.tenant_id!, reservation_id: reservation.id,
                                           customer_id: reservation.customer_id, **attrs)
          return nil unless @receivables.insert_if_absent(tx, receivable, actor.audit_actor_id, @clock.now)

          @ledger.post(tx, F::Postings.receivable_issued(receivable), source_type: "receivable", source_id: receivable.id)
          @audit.record(tx, actor, "receivable.created", "receivable", receivable.id,
                        "kind" => receivable.kind, "amount_cents" => receivable.amount.cents, "reservation_id" => reservation.id)
          receivable
        end

        # Reserva cancelada ou expirada com saldo em aberto: a equipe decide (cancelamento compensatório,
        # multa de cancelamento ou cobrança mantida). A multa de cancelamento em aberto é esperada.
        def flag_closed(tx, reservation)
          return unless F::CLOSED_RESERVATION_STATUSES.include?(reservation.status)
          return unless @receivables.open_for_reservation?(tx, reservation.id, except_kinds: F::CANCELLATION_CHARGE_KINDS)

          @alert_book.raise_alert(tx, kind: "reservation_closed_with_charges", reservation_id: reservation.id,
                                      dedupe_key: "reservation_closed:#{reservation.id}",
                                      message: "Reserva #{reservation.code} #{reservation.status_label.downcase} com cobranças em aberto.")
        end
      end

      # Assinante do despacho de eventos: eventos de reserva agendam a sincronização de cobranças.
      class ReservationChargesSubscriber
        def initialize(queue:)
          @queue = queue
        end

        def call(tx, event)
          return :ignored unless event["event_type"].to_s.start_with?("reservation.") && event["aggregate_type"] == "reservation"

          @queue.enqueue(tx, "finance.sync_reservation", { "reservation_id" => event["aggregate_id"] }, priority: 45,
                                                                                                        correlation_id: event["correlation_id"])
          :enqueued
        end
      end

      # Cobrança adicional lançada pela equipe (multa, avaria, falta, multa de cancelamento, outros).
      class CreateManualCharge
        def initialize(uow:, reservations:, organizations:, receivables:, ledger:, audit:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @organizations = organizations
          @receivables = receivables
          @ledger = ledger
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, reservation_id, kind:, amount:, description:, due_on: nil)
          @uow.run(actor, "finance.write") do |tx, current|
            reservation = @reservations.find(tx, Domain::Identifier.parse(reservation_id, "reserva")) || raise(Domain::NotFound, "reserva")
            F::Charges.manual_allowed!(reservation.status)
            due = due_on || @organizations.find(tx, tx.tenant_id!).time_zone.local_date(@clock.now)
            receivable = F::Receivable.build(id: @ids.uuid, organization_id: tx.tenant_id!, reservation_id: reservation.id,
                                             customer_id: reservation.customer_id, kind: F::Charges.manual_kind!(kind.to_s),
                                             source_type: "manual", source_id: @ids.uuid, description: description, amount: amount, due_on: due)
            @receivables.insert_if_absent(tx, receivable, current.audit_actor_id, @clock.now)
            @ledger.post(tx, F::Postings.receivable_issued(receivable), source_type: "receivable", source_id: receivable.id)
            @audit.record(tx, current, "receivable.created", "receivable", receivable.id,
                          "kind" => receivable.kind, "amount_cents" => receivable.amount.cents, "reservation_id" => reservation.id, "manual" => true)
            receivable
          end
        end
      end

      # Cancelamento por operação compensatória: a cobrança original permanece; um registro de
      # cancelamento e o estorno contábil da receita anulam o saldo. Valores já pagos viram crédito do
      # cliente, a ser reembolsado.
      class CancelReceivable
        def initialize(uow:, receivables:, ledger:, audit:, clock:, ids:)
          @uow = uow
          @receivables = receivables
          @ledger = ledger
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, receivable_id, reason:)
          @uow.run(actor, "finance.write") do |tx, current|
            receivable = @receivables.lock(tx, Domain::Identifier.parse(receivable_id, "cobranca")) || raise(Domain::NotFound, "cobrança")
            raise Domain::Conflict.new("Cobrança já cancelada", code: "receivable_already_cancelled") if @receivables.cancellation(tx, receivable.id)

            text = Domain::Organizations::Text.required(reason, "motivo", min: 3, max: 500)
            @receivables.insert_cancellation(tx, "id" => @ids.uuid, "receivable_id" => receivable.id, "amount_cents" => receivable.amount.cents,
                                                 "reason" => text, "created_by" => current.audit_actor_id, "created_at" => @clock.now)
            @ledger.post(tx, F::Postings.receivable_cancelled(receivable), source_type: "receivable_cancellation", source_id: receivable.id)
            @audit.record(tx, current, "receivable.cancelled", "receivable", receivable.id, "reason" => text, "amount_cents" => receivable.amount.cents)
            @receivables.balance(tx, receivable.id)
          end
        end
      end
    end
  end
end
