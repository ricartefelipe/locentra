# frozen_string_literal: true

module Locentra
  module Application
    # Retirada: separação, conferência e entrega dos itens efetivamente entregues.
    #
    # Retirada duplicada é impedida em três camadas: lock da reserva com verificação de estado, uma
    # única retirada não cancelada por reserva e uma única linha não cancelada por alocação (índices
    # únicos parciais no banco).
    module Fulfillment
      F = Domain::Fulfillment

      # Locks em ordem única: primeiro a reserva, depois a retirada e suas linhas.
      module PickupLocking
        private

        def lock_pickup!(tx, pickup_id)
          found = @fulfillment.find_pickup(tx, Domain::Identifier.parse(pickup_id)) || raise(Domain::NotFound, "retirada")
          reservation = @reservations.lock(tx, found.reservation_id)
          [reservation, @fulfillment.lock_pickup(tx, found.id)]
        end

        def ensure_picking!(reservation, pickup)
          raise Domain::Conflict.new("retirada já registrada para esta reserva", code: "already_picked_up") if pickup.delivered?
          raise Domain::InvalidTransition.new("retirada", pickup.status, "delivered") unless pickup.picking?
          raise Domain::InvalidTransition.new("reserva", reservation.status, "in_progress") unless reservation.status == "confirmed"
        end
      end

      # Separação: uma linha por alocação ativa da reserva confirmada. Repetir a operação devolve a
      # retirada em andamento.
      class StartPickup
        def initialize(uow:, reservations:, fulfillment:, audit:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, reservation_id)
          @uow.run(actor, "fulfillment.write") do |tx, current|
            reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            @fulfillment.open_pickup_for(tx, reservation.id) || start(tx, current, reservation)
          end
        end

        private

        def start(tx, current, reservation)
          pickup = F::Pickup.start(id: @ids.uuid, organization_id: tx.tenant_id!, reservation: reservation, now: @clock.now)
          allocations = @reservations.active_allocation_rows(tx, reservation.id)
          raise Domain::ValidationError.field("reserva", "não há alocações ativas para separar") if allocations.empty?

          @fulfillment.insert_pickup(tx, pickup, current.audit_actor_id)
          allocations.each do |allocation|
            @fulfillment.insert_pickup_line(tx, F::PickupLine.from_allocation(id: @ids.uuid, pickup_id: pickup.id, reservation_id: reservation.id,
                                                                              allocation: allocation))
          end
          @audit.record(tx, current, "pickup.started", "reservation", reservation.id, "pickup_id" => pickup.id, "lines" => allocations.size)
          pickup
        end
      end

      # Conferência: o patrimônio informado deve corresponder ao ativo alocado. Outra unidade livre do
      # mesmo produto pode substituí-lo por realocação segura (exclusion constraint sob savepoint).
      class CheckPickup
        include PickupLocking

        def initialize(uow:, reservations:, fulfillment:, allocations:, availability:, catalog:, audit:, clock:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @allocations = allocations
          @availability = availability
          @catalog = catalog
          @audit = audit
          @clock = clock
        end

        # entries: [{ line_id:, tag: }] para ativos e [{ line_id:, quantity: }] para estoque.
        def call(actor, pickup_id, entries)
          raise Domain::ValidationError.field("itens", "informe ao menos um item conferido") if entries.empty?

          @uow.run(actor, "fulfillment.write") do |tx, current|
            reservation, pickup = lock_pickup!(tx, pickup_id)
            ensure_picking!(reservation, pickup)
            lines = @fulfillment.pickup_lines(tx, pickup.id, lock: true).to_h { |line| [line.id, line] }
            swaps = check_all(tx, current, pickup, lines, entries)
            @audit.record(tx, current, "pickup.checked", "reservation", reservation.id, "pickup_id" => pickup.id, "entries" => entries.size,
                                                                                        "swaps" => swaps)
            @fulfillment.pickup_lines(tx, pickup.id)
          end
        end

        private

        # Cada item é conferido sob savepoint; os erros de todos os itens são reunidos numa única resposta.
        def check_all(tx, current, pickup, lines, entries)
          now = @clock.now
          errors = Hash.new { |hash, key| hash[key] = [] }
          swaps = []
          entries.each do |entry|
            line = lines[Domain::Identifier.parse(entry[:line_id], "item")] || raise(Domain::NotFound, "item da retirada")
            tx.savepoint do
              checked, swap = check(tx, pickup, line, entry)
              @fulfillment.update_pickup_line(tx, checked, checked_by: current.audit_actor_id, checked_at: now)
              swaps << swap if swap
            end
          rescue Domain::ValidationError => e
            e.errors.each { |field, messages| errors[field].concat(Array(messages)) }
          end
          raise Domain::ValidationError, errors unless errors.empty?

          swaps
        end

        def check(tx, pickup, line, entry)
          return [line.check_quantity(quantity!(entry[:quantity])), nil] unless line.asset?

          asset = scanned_asset!(tx, pickup, line, entry[:tag])
          allocation = @allocations.lock_asset_allocation(tx, line.asset_allocation_id)
          raise Domain::Conflict.new("a alocação do item foi alterada; reinicie a separação", code: "allocation_changed") unless allocation&.fetch("active")
          return [line.check_asset(asset.id), nil] if allocation["asset_id"] == asset.id

          begin
            tx.savepoint { @availability.reassign_asset_allocation(tx, allocation["id"], asset.id) }
          rescue AllocationConflict
            raise invalid("patrimônio #{asset.tag} já está alocado em período sobreposto; escolha outra unidade")
          end
          [line.check_asset(asset.id), { "from" => allocation["asset_id"], "to" => asset.id }]
        end

        def scanned_asset!(tx, pickup, line, tag)
          text = tag.to_s.strip.upcase
          raise invalid("informe o patrimônio conferido") if text.empty?

          asset = @catalog.find_asset_by_tag(tx, text) || raise(invalid("patrimônio #{text} não encontrado"))
          raise invalid("patrimônio #{text} é de outro produto") unless asset.product_id == line.product_id
          raise invalid("patrimônio #{text} pertence a outra filial") unless asset.branch_id == pickup.branch_id
          raise invalid("patrimônio #{text} está #{asset.status_label.downcase}") unless asset.status == "available"

          asset
        end

        def quantity!(value)
          Integer(value.to_s.strip, 10)
        rescue ArgumentError
          raise Domain::ValidationError.field("quantidade", "número inteiro")
        end

        def invalid(message) = Domain::ValidationError.field("patrimonio", message)
      end

      # Entrega: somente itens conferidos. Ativos entregues passam a "com cliente"; itens não entregues
      # têm a alocação liberada e o registro explícito na linha. A reserva passa a em andamento.
      class DeliverPickup
        include PickupLocking

        def initialize(uow:, reservations:, fulfillment:, allocations:, customers:, catalog:, ledger:, audit:, events:, clock:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @allocations = allocations
          @customers = customers
          @catalog = catalog
          @ledger = ledger
          @audit = audit
          @events = events
          @clock = clock
        end

        # picker: { kind: "customer" } ou { kind: "contact", contact_id: }
        def call(actor, pickup_id, picker:, notes: nil)
          @uow.run(actor, "fulfillment.write") do |tx, current|
            reservation, pickup = lock_pickup!(tx, pickup_id)
            ensure_picking!(reservation, pickup)
            lines = @fulfillment.pickup_lines(tx, pickup.id, lock: true)
            raise Domain::ValidationError.field("itens", "confira ao menos um item antes da entrega") if lines.none?(&:checked?)

            who = picker_for(tx, reservation, picker)
            now = @clock.now
            delivered_lines = lines.map { |line| deliver_line(tx, current, pickup, line, now) }
            @reservations.update_status(tx, reservation.start, now)
            delivered = pickup.deliver(who, now, notes: notes)
            @fulfillment.update_pickup(tx, delivered, current.audit_actor_id)
            record(tx, current, reservation, delivered, delivered_lines)
            delivered
          end
        end

        private

        def picker_for(tx, reservation, picker)
          customer = @customers.find(tx, reservation.customer_id)
          case picker[:kind].to_s
          when "customer" then F::Picker.customer(customer)
          when "contact"
            id = Domain::Identifier.parse(picker[:contact_id], "retirante")
            contact = @customers.contacts(tx, customer.id).find { |c| c.id == id }
            raise Domain::ValidationError.field("retirante", "contato não encontrado") unless contact

            F::Picker.contact(contact)
          else raise Domain::ValidationError.field("retirante", "informe quem está retirando")
          end
        end

        def deliver_line(tx, current, pickup, line, now)
          done = line.deliver
          if line.asset?
            if done.delivered_quantity.positive?
              hand_over(tx, current, pickup, done, now)
            else
              @allocations.release_asset_allocation(tx, line.asset_allocation_id, now)
            end
          elsif done.delivered_quantity.zero?
            @allocations.release_stock_allocation(tx, line.stock_allocation_id, now)
          elsif done.undelivered_quantity.positive?
            @allocations.set_stock_quantity(tx, line.stock_allocation_id, done.delivered_quantity)
          end
          @fulfillment.update_pickup_line(tx, done, release_reason: done.undelivered_quantity.positive? ? "não conferido na retirada" : nil)
          done
        end

        def hand_over(tx, current, pickup, line, now)
          allocation = @allocations.lock_asset_allocation(tx, line.asset_allocation_id)
          unless allocation&.fetch("active") && allocation["asset_id"] == line.asset_id
            raise Domain::Conflict.new("a alocação do item foi alterada após a conferência; confira novamente", code: "allocation_changed")
          end

          asset = @catalog.lock_asset(tx, line.asset_id)
          unless asset.status == "available"
            raise Domain::Conflict.new("ativo #{asset.tag} não está disponível para entrega (#{asset.status_label})", code: "asset_unavailable")
          end

          @ledger.move(tx, current, asset, "checked_out", kind: "checked_out", now: now, reference_type: "pickup", reference_id: pickup.id)
        end

        def record(tx, current, reservation, pickup, lines)
          delivered = lines.count(&:delivered?)
          released = lines.count { |l| l.undelivered_quantity.positive? }
          @audit.record(tx, current, "reservation.picked_up", "reservation", reservation.id,
                        "pickup_id" => pickup.id, "picker_kind" => pickup.picker.kind, "picker_name" => pickup.picker.name,
                        "delivered_lines" => delivered, "released_lines" => released)
          @events.publish(tx, "reservation.picked_up", "reservation", reservation.id, "code" => reservation.code, "pickup_id" => pickup.id,
                                                                                      "delivered_lines" => delivered, "released_lines" => released)
        end
      end

      # Descarta a separação em andamento; a reserva continua confirmada com as alocações atuais.
      class CancelPickup
        include PickupLocking

        def initialize(uow:, reservations:, fulfillment:, audit:, clock:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @audit = audit
          @clock = clock
        end

        def call(actor, pickup_id, reason:)
          @uow.run(actor, "fulfillment.write") do |tx, current|
            reservation, pickup = lock_pickup!(tx, pickup_id)
            raise Domain::Conflict.new("retirada já registrada para esta reserva", code: "already_picked_up") if pickup.delivered?

            text = Domain::Organizations::Text.required(reason, "motivo", max: 500)
            cancelled = pickup.cancel(@clock.now).with(notes: text)
            @fulfillment.pickup_lines(tx, pickup.id, lock: true).each do |line|
              @fulfillment.update_pickup_line(tx, line.cancel, release_reason: text)
            end
            @fulfillment.update_pickup(tx, cancelled, current.audit_actor_id)
            @audit.record(tx, current, "pickup.cancelled", "reservation", reservation.id, "pickup_id" => pickup.id, "reason" => text)
            cancelled
          end
        end
      end

      class GetPickup
        def initialize(uow:, reservations:, fulfillment:, customers:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @customers = customers
        end

        def call(actor, pickup_id)
          @uow.run(actor, "reservations.read") do |tx, _|
            pickup = @fulfillment.find_pickup(tx, Domain::Identifier.parse(pickup_id)) || raise(Domain::NotFound, "retirada")
            reservation = @reservations.find(tx, pickup.reservation_id)
            customer = @customers.find(tx, reservation.customer_id)
            { pickup: pickup, reservation: reservation, customer: customer, lines: @fulfillment.line_details(tx, pickup.id),
              pickers: @customers.authorized_pickups(tx, customer.id) }
          end
        end
      end
    end
  end
end
