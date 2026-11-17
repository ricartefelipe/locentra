# frozen_string_literal: true

module Locentra
  module Application
    module Reservations
      R = Domain::Reservations

      # Precificação de itens com snapshot completo (tabela, unidades, descontos e totais).
      class Pricer
        def initialize(pricing:)
          @pricing = pricing
        end

        def price(tx, products:, lines:, period:, zone:, customer_id:, now:, coupon_code: nil, manual_discount_bps: 0, fees: [],
                  discount_limit_bps: 0, redeem: false)
          priced = lines.map do |line|
            product = products.fetch(line.product_id)[:product]
            table = Domain::Pricing::PriceTable.from_h(product.pricing)
            negotiated = @pricing.negotiated_discount_bps(tx, customer_id, product.id, now)
            snapshot = if table.priced?
                         Domain::Pricing::Line.price(table: table, period: period, zone: zone, quantity: line.quantity,
                                                     negotiated_bps: negotiated)
                       else
                         { "table" => {}, "description" => "sem tabela de preços", "quantity" => line.quantity, "unit_amount_cents" => 0,
                           "gross_cents" => 0, "total_cents" => 0 }
                       end
            snapshot.merge("product_id" => product.id, "sku" => product.sku, "name" => product.name, "tracking" => product.tracking,
                           "deposit_unit_cents" => product.deposit.cents)
          end
          coupon = load_coupon(tx, coupon_code, redeem)

          deposit = Domain::Money.new(priced.sum { |l| l["deposit_unit_cents"] * l["quantity"] })
          totals = Domain::Pricing::Totals.compose(lines: priced, fees: fees, coupon: coupon, manual_discount_bps: manual_discount_bps,
                                                   discount_limit_bps: discount_limit_bps, now: now, deposit: deposit)
          @pricing.redeem_coupon(tx, coupon.code) if coupon && redeem
          [priced, totals.merge("period" => period.to_h, "timezone" => zone.identifier, "priced_at" => now.iso8601)]
        end

        private

        # Com `redeem`, o cupom é lido com lock para que o limite de utilizações valha sob concorrência.
        def load_coupon(tx, code, redeem)
          text = code.to_s.strip.upcase
          return nil if text.empty?

          @pricing.find_coupon(tx, text, lock: redeem) || raise(Domain::ValidationError.field("cupom", "cupom inexistente"))
        end
      end

      class CreateReservation
        MODES = %w[request hold confirm].freeze

        def initialize(uow:, reservations:, customers:, organizations:, allocator:, pricer:, audit:, events:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @customers = customers
          @organizations = organizations
          @allocator = allocator
          @pricer = pricer
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        # input: customer_id, branch_id, period (Period), lines ([Line]), mode, hold_minutes, notes,
        # coupon_code, manual_discount_bps, fees, source, quote_id.
        def call(actor, input, tx: nil)
          mode = input.fetch(:mode, "hold").to_s
          raise Domain::ValidationError.field("modo", "use request, hold ou confirm") unless MODES.include?(mode)

          if tx
            # Composição: o chamador já abriu a transação e verificou a permissão do ator revalidado.
            execute(tx, actor, input, mode)
          else
            @uow.run(actor, "reservations.write") { |t, current| execute(t, current, input, mode) }
          end
        end

        private

        def execute(tx, current, input, mode)
          now = @clock.now
          period = input.fetch(:period)
          R::Rules.validate_start!(period, now)
          lines = R::Rules.normalize_lines(input.fetch(:lines))
          customer = active_customer!(tx, input.fetch(:customer_id))
          branch_id = active_branch!(tx, input.fetch(:branch_id))
          org = @organizations.find(tx, tx.tenant_id!)
          products = active_products!(tx, lines)
          priced, summary = price(tx, current, input, products: products, lines: lines, period: period, org: org, customer: customer, now: now)
          reservation = build(tx, input, mode, org: org, customer: customer, branch_id: branch_id, period: period, summary: summary, now: now)
          @reservations.insert(tx, reservation, summary, current.audit_actor_id, now)
          items = insert_items(tx, reservation, priced, now)
          if reservation.occupying?
            @allocator.allocate(tx, reservation_id: reservation.id, branch_id: branch_id, period: period, items: items, now: now,
                                    actor_id: current.audit_actor_id)
          end
          finalize(tx, current, reservation, mode)
        end

        def active_customer!(tx, customer_id)
          customer = @customers.find(tx, Domain::Identifier.parse(customer_id, "cliente")) || raise(Domain::NotFound, "cliente")
          raise Domain::ValidationError.field("cliente", "cliente bloqueado ou inativo") unless customer.status == "active"

          customer
        end

        def active_branch!(tx, branch_id)
          id = Domain::Identifier.parse(branch_id, "filial")
          raise Domain::NotFound, "filial" unless @organizations.branch_active?(tx, id)

          id
        end

        def active_products!(tx, lines)
          products = @allocator.products_for(tx, lines.map(&:product_id))
          lines.each { |l| raise Domain::NotFound, "produto" unless products[l.product_id]&.fetch(:product)&.active }
          products
        end

        def price(tx, current, input, products:, lines:, period:, org:, customer:, now:)
          limit = current.user? ? Domain::Identity.discount_limit_bps(current.role) : 0
          @pricer.price(tx, products: products, lines: lines, period: period, zone: org.time_zone, customer_id: customer.id,
                            coupon_code: input[:coupon_code], manual_discount_bps: input.fetch(:manual_discount_bps, 0).to_i,
                            fees: input.fetch(:fees, []), now: now, discount_limit_bps: limit, redeem: true)
        end

        # O código sequencial definitivo é atribuído em `finalize`: o lock da linha do contador fica
        # restrito ao fechamento da transação e não serializa as alocações de reservas concorrentes.
        def build(tx, input, mode, org:, customer:, branch_id:, period:, summary:, now:)
          id = @ids.uuid
          reservation = R::Reservation.new(
            id: id, organization_id: tx.tenant_id!, branch_id: branch_id, customer_id: customer.id,
            code: "PEND-#{id}", status: "requested", source: input.fetch(:source, "staff").to_s,
            period: period, hold_expires_at: nil, quote_id: input[:quote_id], notes: Domain::Organizations::Text.optional(input[:notes]),
            total: Domain::Money.new(summary.fetch("total_cents")), deposit: Domain::Money.new(summary.fetch("deposit_cents")), version: 1
          )
          case mode
          when "hold" then reservation.hold(now + (R::Rules.hold_minutes!(input.fetch(:hold_minutes, org.hold_minutes)) * 60))
          when "confirm" then reservation.transition("confirmed")
          else reservation
          end
        end

        def insert_items(tx, reservation, priced, now)
          priced.each_with_index.map do |snapshot, index|
            item = { id: @ids.uuid, product_id: snapshot["product_id"], quantity: snapshot["quantity"], position: index + 1, pricing: snapshot }
            @reservations.insert_item(tx, reservation.id, item, now)
            item
          end
        end

        def finalize(tx, current, reservation, mode)
          reservation = reservation.with(code: @organizations.next_code(tx, "reservation", "R"))
          @reservations.assign_code(tx, reservation.id, reservation.code)
          @audit.record(tx, current, "reservation.created", "reservation", reservation.id,
                        "code" => reservation.code, "status" => reservation.status, "mode" => mode)
          @events.publish(tx, "reservation.#{reservation.status}", "reservation", reservation.id, "code" => reservation.code)
          reservation
        end
      end

      # Confirmação com revalidação atômica sob lock da reserva e dos estoques envolvidos.
      class ConfirmReservation
        def initialize(uow:, reservations:, allocator:, audit:, events:, clock:)
          @uow = uow
          @reservations = reservations
          @allocator = allocator
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, reservation_id, tx: nil)
          return execute(tx, actor, reservation_id) if tx

          result = @uow.run(actor, "reservations.write") do |t, current|
            execute(t, current, reservation_id)
          rescue Domain::HoldExpired
            :expired
          end
          raise Domain::HoldExpired if result == :expired

          result
        end

        private

        def execute(tx, current, reservation_id)
          now = @clock.now
          reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
          return reservation if reservation.status == "confirmed"

          if reservation.hold_expired?(now)
            expire(tx, current, reservation, now)
            raise Domain::HoldExpired
          end

          if reservation.requested?
            items = @reservations.items(tx, reservation.id).map do |i|
              { id: i["id"], product_id: i["product_id"], quantity: i["quantity"] }
            end
            @allocator.allocate(tx, reservation_id: reservation.id, branch_id: reservation.branch_id, period: reservation.period,
                                    items: items, now: now, actor_id: current.audit_actor_id)
          else
            @allocator.revalidate(tx, reservation_id: reservation.id, branch_id: reservation.branch_id, period: reservation.period,
                                      now: now)
          end
          confirmed = reservation.confirm(now)
          @reservations.update_status(tx, confirmed, now, "confirmed_at" => now)
          @audit.record(tx, current, "reservation.confirmed", "reservation", reservation.id, "code" => reservation.code)
          @events.publish(tx, "reservation.confirmed", "reservation", reservation.id, "code" => reservation.code)
          confirmed
        end

        # A expiração é gravada mesmo quando a confirmação falha (resultado determinístico).
        def expire(tx, current, reservation, now)
          expired = reservation.expire(now)
          @reservations.update_status(tx, expired, now, "expired_at" => now)
          @reservations.release_allocations(tx, reservation.id, now)
          @audit.record(tx, current, "reservation.expired", "reservation", reservation.id, "trigger" => "confirmation_attempt")
        end
      end

      class CancelReservation
        def initialize(uow:, reservations:, audit:, events:, clock:)
          @uow = uow
          @reservations = reservations
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, reservation_id, reason:, tx: nil)
          return execute(tx, actor, reservation_id, reason) if tx

          @uow.run(actor, "reservations.cancel") { |t, current| execute(t, current, reservation_id, reason) }
        end

        private

        def execute(tx, current, reservation_id, reason)
          now = @clock.now
          reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
          cancelled = reservation.cancel
          text = Domain::Organizations::Text.required(reason, "motivo", max: 500)
          @reservations.update_status(tx, cancelled, now, "cancelled_at" => now, "cancellation_reason" => text)
          @reservations.release_allocations(tx, reservation.id, now)
          @audit.record(tx, current, "reservation.cancelled", "reservation", reservation.id, "reason" => text)
          @events.publish(tx, "reservation.cancelled", "reservation", reservation.id, "code" => reservation.code)
          cancelled
        end
      end

      # Reagendamento: libera as alocações atuais e aloca o novo período na mesma transação. Em
      # conflito, a transação é desfeita e a reserva permanece no período original.
      class RescheduleReservation
        def initialize(uow:, reservations:, organizations:, allocator:, audit:, clock:)
          @uow = uow
          @reservations = reservations
          @organizations = organizations
          @allocator = allocator
          @audit = audit
          @clock = clock
        end

        def call(actor, reservation_id, period:)
          @uow.run(actor, "reservations.write") do |tx, current|
            now = @clock.now
            reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            moved = reservation.reschedule(period, now)
            if reservation.occupying?
              previous = @reservations.allocated_asset_ids(tx, reservation.id)
              @reservations.release_allocations(tx, reservation.id, now)
              items = @reservations.items(tx, reservation.id).map do |i|
                { id: i["id"], product_id: i["product_id"], quantity: i["quantity"] }
              end
              @allocator.allocate(tx, reservation_id: reservation.id, branch_id: reservation.branch_id, period: period, items: items, now: now,
                                      preferred_assets: previous, actor_id: current.audit_actor_id)
            end
            @reservations.update_period(tx, moved, now)
            @audit.record(tx, current, "reservation.rescheduled", "reservation", reservation.id,
                          "from" => reservation.period.to_h, "to" => period.to_h)
            moved
          end
        end
      end

      # Extensão do fim: as alocações existentes são estendidas no lugar (mesmos ativos, que podem
      # estar com o cliente). Se o novo período invadir outra reserva, a operação é recusada.
      class ExtendReservation
        def initialize(uow:, reservations:, organizations:, allocator:, availability:, audit:, events:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @organizations = organizations
          @allocator = allocator
          @availability = availability
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        def call(actor, reservation_id, ends_at:)
          @uow.run(actor, "reservations.write") do |tx, current|
            now = @clock.now
            reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            extended = reservation.extend_to(ends_at, now)
            products = @allocator.products_for(tx, @reservations.allocated_product_ids(tx, reservation.id))
            extend_allocations(tx, reservation, extended, products, now)
            zone = @organizations.find(tx, tx.tenant_id!).time_zone
            adjustment = @reservations.items(tx, reservation.id).sum do |item|
              next 0 if item["pricing"].fetch("table", {}).empty?

              delta, repriced = Domain::Pricing::Extension.adjustment(line_snapshot: item["pricing"], new_period: extended.period,
                                                                      zone: zone)
              @reservations.insert_adjustment(tx, "id" => @ids.uuid, "reservation_id" => reservation.id, "reservation_item_id" => item["id"],
                                                  "kind" => "extension", "amount_cents" => delta.cents, "created_by" => current.audit_actor_id,
                                                  "details" => { "from_end" => reservation.period.ends_at.iso8601, "to_end" => ends_at.iso8601,
                                                                 "repriced_total_cents" => repriced["total_cents"] }, "created_at" => now)
              delta.cents
            end
            @reservations.update_period(tx, extended, now, extension_cents: adjustment)
            @audit.record(tx, current, "reservation.extended", "reservation", reservation.id,
                          "from_end" => reservation.period.ends_at.iso8601, "to_end" => ends_at.iso8601, "adjustment_cents" => adjustment)
            @events.publish(tx, "reservation.extended", "reservation", reservation.id, "adjustment_cents" => adjustment)
            { reservation: extended, adjustment: Domain::Money.new(adjustment) }
          end
        end

        private

        def extend_allocations(tx, reservation, extended, products, now)
          shortages = []
          bulk_ids = products.values.map { |p| p[:product] }.select(&:bulk?).map(&:id).sort
          @availability.lock_pools(tx, reservation.branch_id, bulk_ids)
          @reservations.active_allocation_rows(tx, reservation.id).each do |allocation|
            product = products.fetch(allocation["product_id"])[:product]
            window = product.blocked_period(extended.period)
            if allocation["asset_id"]
              begin
                tx.savepoint { @availability.update_asset_allocation_period(tx, allocation["id"], window) }
              rescue AllocationConflict
                shortages << { "product_id" => product.id, "sku" => product.sku, "asset_id" => allocation["asset_id"],
                               "conflict" => @availability.conflicting_reservation_code(tx, allocation["asset_id"], window, reservation.id) }
              end
            else
              @availability.update_stock_allocation_period(tx, allocation["id"], window)
              pool_ledger = Domain::Availability::StockLedger.new(
                capacity: @availability.pool_capacity(tx, allocation["stock_pool_id"]),
                occupancies: @availability.stock_occupancies(tx, allocation["stock_pool_id"], window, now)
              )
              shortages << { "product_id" => product.id, "sku" => product.sku } if pool_ledger.peak(window) > pool_ledger.capacity
            end
          end
          raise Domain::Unavailable.new(shortages, "A extensão conflita com outras reservas") unless shortages.empty?
        end
      end

      # Expira bloqueios temporários vencidos. Reservas bloqueadas por outra transação (por exemplo,
      # uma confirmação em andamento) são ignoradas nesta execução: o resultado é decidido por quem
      # obtiver o lock, sempre comparando o instante atual com `hold_expires_at`.
      class ExpireHolds
        def initialize(uow:, reservations:, audit:, events:, clock:)
          @uow = uow
          @reservations = reservations
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, limit: 200)
          @uow.run(actor) do |tx, current|
            now = @clock.now
            @reservations.lock_expired_holds(tx, now, limit).map do |reservation|
              expired = reservation.expire(now)
              @reservations.update_status(tx, expired, now, "expired_at" => now)
              @reservations.release_allocations(tx, reservation.id, now)
              @audit.record(tx, current, "reservation.expired", "reservation", reservation.id, "trigger" => "sweeper")
              @events.publish(tx, "reservation.expired", "reservation", reservation.id, "code" => reservation.code)
              reservation.id
            end
          end
        end
      end

      class ListReservations
        SORTS = %w[starts_at -starts_at created_at -created_at code].freeze

        def initialize(uow:, reservations:)
          @uow = uow
          @reservations = reservations
        end

        def call(actor, status: nil, customer_id: nil, search: nil, from: nil, to: nil, sort: "-starts_at", limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          raise Domain::ValidationError.field("ordenacao", "inválida") unless SORTS.include?(sort)
          raise Domain::ValidationError.field("situacao", "inválida") if status && !R::STATUSES.key?(status)

          @uow.run(actor, actor.customer? ? "portal.access" : "reservations.read") do |tx, current|
            customer = current.customer? ? current.customer_id : (customer_id && Domain::Identifier.parse(customer_id, "cliente"))
            items, total = @reservations.search(tx, status: status, customer_id: customer, search: search.to_s.strip[0, 40],
                                                    from: from, to: to, sort: sort, limit: lim, offset: off)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetReservation
        def initialize(uow:, reservations:)
          @uow = uow
          @reservations = reservations
        end

        def call(actor, reservation_id)
          @uow.run(actor, actor.customer? ? "portal.access" : "reservations.read") do |tx, current|
            reservation = @reservations.find(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            raise Domain::NotFound, "reserva" if current.customer? && reservation.customer_id != current.customer_id

            { reservation: reservation, items: @reservations.items(tx, reservation.id), allocations: @reservations.allocation_details(tx, reservation.id),
              pricing: @reservations.pricing(tx, reservation.id) }
          end
        end
      end
    end
  end
end
