# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Abertura da caução de uma reserva (valor previsto). O recebimento é um pagamento com
      # finalidade caução (manual ou pelo provedor). Pré-autorização em cartão é recusada.
      class OpenDeposit
        def initialize(uow:, reservations:, deposits:, audit:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @deposits = deposits
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, reservation_id, kind:, amount: nil, notes: nil)
          @uow.run(actor, "deposits.manage") do |tx, current|
            reservation = @reservations.find(tx, Domain::Identifier.parse(reservation_id, "reserva")) || raise(Domain::NotFound, "reserva")
            deposit = F::Deposit.open(id: @ids.uuid, organization_id: tx.tenant_id!, reservation_id: reservation.id, customer_id: reservation.customer_id,
                                      reservation_status: reservation.status, kind: kind.to_s, expected: amount || reservation.deposit, notes: notes)
            raise Domain::Conflict.new("A reserva já possui caução", code: "deposit_exists") if @deposits.for_reservation(tx, reservation.id)

            @deposits.insert(tx, deposit, current.audit_actor_id, @clock.now)
            @audit.record(tx, current, "deposit.opened", "deposit", deposit.id, "reservation_id" => reservation.id,
                                                                                "expected_cents" => deposit.expected.cents)
            deposit
          end
        end
      end

      # Movimentos de saída da caução (aplicação a cobrança e devolução), com lock da caução.
      class MoveDeposit
        def initialize(uow:, deposits:, receivables:, ledger:, audit:, clock:, ids:)
          @uow = uow
          @deposits = deposits
          @receivables = receivables
          @ledger = ledger
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # Aplica parte da caução a uma cobrança da mesma reserva (ex.: avaria). A caução deixa de ser
        # passivo e quita a cobrança; a receita já foi reconhecida na emissão da cobrança.
        def apply(actor, deposit_id, receivable_id:, amount:)
          @uow.run(actor, "deposits.manage") do |tx, current|
            deposit = lock!(tx, deposit_id)
            receivable = @receivables.lock(tx, Domain::Identifier.parse(receivable_id, "cobranca")) || raise(Domain::NotFound, "cobrança")
            unless receivable.reservation_id == deposit.reservation_id
              raise Domain::ValidationError.field("cobranca", "a cobrança deve ser da mesma reserva da caução")
            end

            balance = @receivables.balance(tx, receivable.id)
            raise Domain::Conflict.new("Cobrança cancelada", code: "receivable_cancelled") if balance.cancelled?

            ledger = @deposits.ledger(tx, deposit.id).apply!(amount, balance.open_amount)
            entry = insert(tx, current, deposit, "apply", amount, "receivable_id" => receivable.id)
            @ledger.post(tx, F::Postings.deposit_applied(amount), source_type: "deposit_entry", source_id: entry)
            @audit.record(tx, current, "deposit.applied", "deposit", deposit.id, "receivable_id" => receivable.id, "amount_cents" => amount.cents)
            ledger
          end
        end

        def give_back(actor, deposit_id, amount:, method:, notes: nil)
          @uow.run(actor, "deposits.manage") do |tx, current|
            deposit = lock!(tx, deposit_id)
            ledger = @deposits.ledger(tx, deposit.id).return!(amount, method.to_s)
            entry = insert(tx, current, deposit, "return", amount, "method" => method.to_s, "notes" => Domain::Organizations::Text.optional(notes, max: 500))
            @ledger.post(tx, F::Postings.deposit_returned(amount), source_type: "deposit_entry", source_id: entry)
            @audit.record(tx, current, "deposit.returned", "deposit", deposit.id, "amount_cents" => amount.cents, "method" => method.to_s)
            ledger
          end
        end

        private

        def lock!(tx, deposit_id)
          @deposits.lock(tx, Domain::Identifier.parse(deposit_id, "caucao")) || raise(Domain::NotFound, "caução")
        end

        def insert(tx, actor, deposit, kind, amount, extra)
          id = @ids.uuid
          @deposits.insert_entry(tx, { "id" => id, "deposit_id" => deposit.id, "kind" => kind, "amount_cents" => amount.cents,
                                       "created_by" => actor.audit_actor_id, "created_at" => @clock.now }.merge(extra))
          id
        end
      end
    end
  end
end
