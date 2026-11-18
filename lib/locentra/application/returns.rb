# frozen_string_literal: true

module Locentra
  module Application
    # Devolução total ou parcial com resultado por item (ok, avariado, faltante) e inspeção opcional.
    #
    # Devolução duplicada é impedida pelo lock da reserva e das linhas da retirada, pela verificação
    # do pendente de cada linha (domínio) e, no banco, pelo CHECK do acumulado e pelo índice único
    # parcial por ativo entregue.
    module Returns
      F = Domain::Fulfillment
      M = Domain::Maintenance
      Keys = Domain::Alerts::Keys

      class RegisterReturn
        Ctx = Data.define(:tx, :actor, :reservation, :return_id, :now, :products)

        def initialize(uow:, reservations:, fulfillment:, allocations:, availability:, catalog:, organizations:, desk:, damage_reports:,
                       ledger:, relocation:, coverage:, alert_book:, alerts:, audit:, events:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @allocations = allocations
          @availability = availability
          @catalog = catalog
          @organizations = organizations
          @desk = desk
          @damage_reports = damage_reports
          @ledger = ledger
          @relocation = relocation
          @coverage = coverage
          @alert_book = alert_book
          @alerts = alerts
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        # entries: [{ pickup_line_id:, outcome:, quantity:, requires_inspection:, notes: }]
        def call(actor, reservation_id, entries:, notes: nil)
          parsed = entries.map { |entry| F::ReturnEntry.build(**entry) }.sort_by(&:pickup_line_id)
          @uow.run(actor, "fulfillment.write") do |tx, current|
            reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            raise Domain::InvalidTransition.new("reserva", reservation.status, "devolução") unless reservation.status == "in_progress"

            execute(tx, current, reservation, parsed, notes)
          end
        end

        private

        def execute(tx, current, reservation, entries, notes)
          pickup = @fulfillment.delivered_pickup_for(tx, reservation.id) || raise(Domain::NotFound, "retirada")
          before = @fulfillment.pickup_lines(tx, pickup.id, lock: true).select(&:delivered?).to_h { |line| [line.id, line] }
          after = F::ReturnPlan.apply(before, entries)
          lock_stock_pools(tx, before, entries)
          now = @clock.now
          completes = F::ReturnPlan.complete?(after)
          fees = late_fees(tx, reservation, entries, before, after, now)
          row = { "id" => @ids.uuid, "reservation_id" => reservation.id, "pickup_id" => pickup.id, "branch_id" => reservation.branch_id,
                  "returned_at" => now, "received_by" => current.audit_actor_id, "late_fee_cents" => fees.sum { |f| f[:amount].cents },
                  "completes_reservation" => completes, "notes" => Domain::Organizations::Text.optional(notes, max: 1000), "created_at" => now }
          @fulfillment.insert_return(tx, row)
          ctx = Ctx.new(tx: tx, actor: current, reservation: reservation, return_id: row["id"], now: now,
                        products: @availability.product_specs(tx, before.values.map(&:product_id).uniq).transform_values { |p| p[:product] })
          entries.each { |entry| process(ctx, before.fetch(entry.pickup_line_id), entry) }
          after.each { |id, line| @fulfillment.update_line_counters(tx, line) unless line == before[id] }
          fees.each { |fee| charge_late_fee(ctx, fee) }
          complete!(ctx) if completes
          record(ctx, entries, row)
          row
        end

        # Estoques envolvidos bloqueados de uma vez, em ordem de id (a mesma da criação e da extensão de
        # reservas), antes das alocações: a ordem das linhas não forma ciclo de locks.
        def lock_stock_pools(tx, before, entries)
          @allocations.lock_pools_in_order(tx, entries.filter_map { |entry| before.fetch(entry.pickup_line_id).stock_pool_id })
        end

        def late_fees(tx, reservation, entries, before, after, now)
          items = @reservations.items(tx, reservation.id).to_h { |item| [item["id"], item] }
          zone = @organizations.find(tx, tx.tenant_id!).time_zone
          F::LateFeePolicy.charges(items: items, entries: entries, before: before, after: after, scheduled_end: reservation.period.ends_at,
                                   returned_at: now, zone: zone)
        end

        def process(ctx, line, entry)
          return_line_id = @ids.uuid
          @fulfillment.insert_return_line(ctx.tx, "id" => return_line_id, "return_id" => ctx.return_id, "pickup_line_id" => line.id,
                                                  "reservation_item_id" => line.reservation_item_id, "product_id" => line.product_id,
                                                  "asset_id" => line.asset_id, "stock_pool_id" => line.stock_pool_id, "outcome" => entry.outcome,
                                                  "quantity" => entry.quantity, "requires_inspection" => entry.requires_inspection,
                                                  "notes" => entry.notes, "created_at" => ctx.now)
          line.asset? ? return_asset(ctx, line, entry, return_line_id) : return_stock(ctx, line, entry, return_line_id)
          report_damage(ctx, line, entry, return_line_id) unless entry.outcome == "ok"
        end

        def return_asset(ctx, line, entry, return_line_id)
          asset = @catalog.lock_asset(ctx.tx, line.asset_id)
          target = if entry.missing? then "lost"
                   elsif entry.requires_inspection then "in_inspection"
                   else "available"
                   end
          moved = @ledger.move(ctx.tx, ctx.actor, asset, target, kind: "returned", now: ctx.now, reference_type: "return",
                                                                 reference_id: ctx.return_id, notes: [entry.outcome_label, entry.notes].compact.join(": "))
          release_asset(ctx, line, prep: target == "available")
          if entry.requires_inspection
            @desk.open_inspection(ctx.tx, product_id: line.product_id, branch_id: moved.branch_id, reason: inspection_reason(ctx, entry), now: ctx.now,
                                          asset_id: asset.id, reservation_id: ctx.reservation.id, return_line_id: return_line_id)
          elsif entry.missing?
            unresolved = @relocation.relocate(ctx.tx, moved, ctx.now).map { |allocation| allocation["reservation_id"] }.uniq
            details = { "tag" => asset.tag, "reason" => "faltante na devolução de #{ctx.reservation.code}" }
            @alert_book.unavailable(ctx.tx, unresolved, resource_id: asset.id, source_id: ctx.return_id, related_reservation_id: ctx.reservation.id,
                                                        asset_id: asset.id, details: details)
          end
        end

        # Libera a alocação da reserva. Na devolução antecipada sem inspeção, a preparação posterior do
        # produto continua bloqueando o ativo até o menor entre o fim original e agora + preparação.
        def release_asset(ctx, line, prep:)
          allocation = @allocations.lock_asset_allocation(ctx.tx, line.asset_allocation_id)
          return unless allocation&.fetch("active")

          @allocations.release_asset_allocation(ctx.tx, allocation["id"], ctx.now)
          buffer = ctx.products.fetch(line.product_id).buffer_after_minutes * 60
          prep_end = [allocation["ends_at"], ctx.now + buffer].min
          return unless prep && buffer.positive? && prep_end > ctx.now

          block = { "id" => @ids.uuid, "organization_id" => ctx.tx.tenant_id!, "asset_id" => line.asset_id, "product_id" => line.product_id,
                    "reservation_id" => nil, "reservation_item_id" => nil, "kind" => "block", "reason" => "Preparação após devolução",
                    "period" => Domain::Period.new(ctx.now, prep_end), "created_by" => ctx.actor.audit_actor_id, "created_at" => ctx.now }
          ctx.tx.savepoint { @availability.insert_asset_allocation(ctx.tx, block) }
        rescue AllocationConflict
          nil
        end

        def return_stock(ctx, line, entry, return_line_id)
          reduce_stock_allocation(ctx, line, entry.quantity)
          pool = @allocations.lock_pool(ctx.tx, line.stock_pool_id)
          if entry.missing?
            pool = write_off(ctx, pool, entry.quantity)
          elsif entry.requires_inspection
            block = @desk.block_stock(ctx.tx, ctx.actor, pool, entry.quantity, "Inspeção pós-devolução", ctx.now)
            @desk.open_inspection(ctx.tx, product_id: line.product_id, branch_id: pool.branch_id, reason: inspection_reason(ctx, entry), now: ctx.now,
                                          pool_id: pool.id, quantity: entry.quantity, block_allocation_id: block,
                                          reservation_id: ctx.reservation.id, return_line_id: return_line_id)
          end
          alert_uncovered(ctx, pool) if entry.missing? || entry.requires_inspection
        end

        def reduce_stock_allocation(ctx, line, quantity)
          allocation = @allocations.lock_stock_allocation(ctx.tx, line.stock_allocation_id)
          return unless allocation&.fetch("active")

          remaining = allocation["quantity"] - quantity
          if remaining.positive?
            @allocations.set_stock_quantity(ctx.tx, allocation["id"], remaining)
          else
            @allocations.release_stock_allocation(ctx.tx, allocation["id"], ctx.now)
          end
        end

        def write_off(ctx, pool, quantity)
          updated = pool.adjust(-quantity)
          @catalog.update_pool_total(ctx.tx, updated, ctx.now)
          @catalog.insert_stock_movement(ctx.tx, "id" => @ids.uuid, "stock_pool_id" => pool.id, "kind" => "loss", "quantity_delta" => -quantity,
                                                 "reason" => "Falta na devolução da reserva #{ctx.reservation.code}", "actor_id" => ctx.actor.audit_actor_id,
                                                 "reference_type" => "return", "reference_id" => ctx.return_id, "occurred_at" => ctx.now)
          updated
        end

        # Baixa ou bloqueio de estoque não descobre reservas futuras em silêncio: cada uma recebe alerta.
        def alert_uncovered(ctx, pool)
          affected = @coverage.affected(ctx.tx, pool.id, pool.total_quantity, ctx.now)
          @alert_book.unavailable(ctx.tx, affected, resource_id: pool.id, source_id: ctx.return_id, related_reservation_id: ctx.reservation.id,
                                                    stock_pool_id: pool.id, details: { "reason" => "estoque reduzido na devolução de #{ctx.reservation.code}" })
        end

        def report_damage(ctx, line, entry, return_line_id)
          product = ctx.products.fetch(line.product_id)
          report = M::DamageReport.build(
            id: @ids.uuid, organization_id: ctx.tx.tenant_id!, code: @organizations.next_code(ctx.tx, "damage_report", "AV"),
            reservation_id: ctx.reservation.id, reservation_item_id: line.reservation_item_id, return_line_id: return_line_id,
            product_id: line.product_id, asset_id: line.asset_id, stock_pool_id: line.stock_pool_id, quantity: entry.quantity,
            kind: entry.missing? ? "missing" : "damage", severity: entry.missing? ? "total_loss" : "moderate", description: entry.notes,
            estimated_cost: entry.missing? ? product.replacement_cost * entry.quantity : Domain::Money.zero
          )
          @damage_reports.insert(ctx.tx, report, ctx.actor.audit_actor_id, ctx.now)
        end

        def inspection_reason(ctx, entry)
          "#{entry.outcome_label} na devolução da reserva #{ctx.reservation.code}#{": #{entry.notes}" if entry.notes}"[0, 500]
        end

        def charge_late_fee(ctx, fee)
          @reservations.insert_adjustment(ctx.tx, "id" => @ids.uuid, "reservation_id" => ctx.reservation.id, "reservation_item_id" => fee[:item_id],
                                                  "kind" => "late_fee", "amount_cents" => fee[:amount].cents, "created_by" => ctx.actor.audit_actor_id,
                                                  "details" => { "return_id" => ctx.return_id, "quantity" => fee[:quantity],
                                                                 "scheduled_end" => ctx.reservation.period.ends_at.iso8601,
                                                                 "returned_at" => ctx.now.iso8601 },
                                                  "created_at" => ctx.now)
        end

        def complete!(ctx)
          @reservations.update_status(ctx.tx, ctx.reservation.complete, ctx.now)
          @alerts.resolve_open(ctx.tx, reservation_id: ctx.reservation.id, kinds: ["overdue"], resolution: "Devolução concluída", now: ctx.now)
          @alerts.resolve_open(ctx.tx, reservation_id: ctx.reservation.id, kinds: ["affected_by_overdue"], related: true, now: ctx.now,
                                       resolution: "Devolução da reserva #{ctx.reservation.code} concluída")
        end

        def record(ctx, entries, row)
          outcomes = entries.map(&:outcome).tally
          @audit.record(ctx.tx, ctx.actor, "reservation.returned", "reservation", ctx.reservation.id,
                        "return_id" => row["id"], "outcomes" => outcomes, "completed" => row["completes_reservation"],
                        "late_fee_cents" => row["late_fee_cents"])
          @events.publish(ctx.tx, "reservation.returned", "reservation", ctx.reservation.id,
                          "code" => ctx.reservation.code, "return_id" => row["id"], "completed" => row["completes_reservation"],
                          "late_fee_cents" => row["late_fee_cents"], "outcomes" => outcomes)
        end
      end

      # Itens pendentes de devolução da reserva (formulário de devolução).
      class ReturnForm
        def initialize(uow:, reservations:, fulfillment:, customers:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
          @customers = customers
        end

        def call(actor, reservation_id)
          @uow.run(actor, "reservations.read") do |tx, _|
            reservation = @reservations.find(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            pickup = @fulfillment.delivered_pickup_for(tx, reservation.id)
            lines = pickup ? @fulfillment.line_details(tx, pickup.id).select { |l| F::DELIVERED_LINE_STATUSES.include?(l["status"]) } : []
            { reservation: reservation, customer: @customers.find(tx, reservation.customer_id), pickup: pickup, lines: lines,
              returns: @fulfillment.returns_for(tx, reservation.id) }
          end
        end
      end

      class GetReturn
        def initialize(uow:, reservations:, fulfillment:)
          @uow = uow
          @reservations = reservations
          @fulfillment = fulfillment
        end

        def call(actor, return_id)
          @uow.run(actor, "reservations.read") do |tx, _|
            row = @fulfillment.find_return(tx, Domain::Identifier.parse(return_id)) || raise(Domain::NotFound, "devolução")
            fees = @reservations.adjustments(tx, row["reservation_id"]).select { |a| a["kind"] == "late_fee" && a["details"]["return_id"] == row["id"] }
            { return: row, lines: @fulfillment.return_lines(tx, row["id"]), late_fees: fees }
          end
        end
      end
    end
  end
end
