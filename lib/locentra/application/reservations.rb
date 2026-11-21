# frozen_string_literal: true

module Locentra
  module Application
    module Reservations
      R = Domain::Reservations

      # Precificação de itens com snapshot completo (tabela, unidades, descontos, condição negociada
      # aplicada, cupom e tarifas) e registro do uso do cupom pela reserva.
      #
      # Ordem de travas na criação de reserva: cupom (FOR UPDATE, com a contagem de usos ativos em
      # instrução separada, depois da trava) → inserção da reserva e do uso → estoques. Cancelamento,
      # expiração e alocador não tocam em cupons: o uso deixa de ser ativo pela situação da reserva.
      class Pricer
        P = Domain::Pricing

        # `overrides`: tarifas com valor diferente do padrão ou avulsas, para a auditoria; nunca entram
        # no resumo gravado.
        Priced = Data.define(:items, :summary, :coupon, :overrides)

        def initialize(pricing:, ids:)
          @pricing = pricing
          @ids = ids
        end

        def price(tx, products:, lines:, period:, zone:, customer_id:, now:, coupon_code: nil, manual_discount_bps: 0, fees: [],
                  previous_fees: [], fee_override: false, discount_limit_bps: 0, lock_coupon: false)
          agreements = []
          items = lines.map do |line|
            product = products.fetch(line.product_id)[:product]
            snapshot = line_snapshot(tx, product, line, period, zone, customer_id, now, agreements)
            snapshot.merge("product_id" => product.id, "sku" => product.sku, "name" => product.name, "tracking" => product.tracking,
                           "deposit_unit_cents" => product.deposit.cents)
          end
          coupon = load_coupon(tx, coupon_code, lock_coupon, now)
          resolution = resolve_fees(tx, fees, previous_fees, fee_override, discount_limit_bps)
          deposit = Domain::Money.new(items.sum { |l| l["deposit_unit_cents"] * l["quantity"] })
          totals = P::Totals.compose(lines: items, fees: resolution.entries, coupon: coupon, manual_discount_bps: manual_discount_bps,
                                     discount_limit_bps: discount_limit_bps, now: now, deposit: deposit)
          summary = totals.merge("coupon" => coupon&.to_snapshot, "agreements" => agreements.uniq(&:id).map(&:to_snapshot),
                                 "period" => period.to_h, "timezone" => zone.identifier, "priced_at" => now.iso8601)
          Priced.new(items: items, summary: summary, coupon: coupon, overrides: resolution.overrides)
        end

        # Grava o uso do cupom de uma reserva recém-inserida (sem cupom, nada a fazer). O gatilho do banco
        # repete a verificação do limite sob a mesma trava do cupom.
        def record_redemption(tx, priced, reservation:, actor_id:, now:)
          return nil unless priced.coupon

          row = { "id" => @ids.uuid, "coupon_id" => priced.coupon.id, "reservation_id" => reservation.id,
                  "subtotal_cents" => priced.summary.fetch("subtotal_cents"), "discount_cents" => priced.summary.fetch("coupon_discount_cents"),
                  "redeemed_by" => actor_id, "redeemed_at" => now }
          tx.savepoint { @pricing.insert_redemption(tx, row) }
          row
        rescue Domain::ValidationError
          raise Domain::ValidationError.field("cupom", "cupom esgotado")
        end

        private

        def line_snapshot(tx, product, line, period, zone, customer_id, now, agreements)
          table = P::PriceTable.from_h(product.pricing)
          unless table.priced?
            return { "table" => {}, "description" => "sem tabela de preços", "quantity" => line.quantity, "unit_amount_cents" => 0,
                     "gross_cents" => 0, "total_cents" => 0, "negotiated_agreement_id" => nil }
          end

          agreement = @pricing.applicable_agreement(tx, customer_id, product.id, now)
          agreements << agreement if agreement
          P::Line.price(table: table, period: period, zone: zone, quantity: line.quantity, negotiated_bps: agreement ? agreement.discount_bps : 0)
                 .merge("negotiated_agreement_id" => agreement&.id)
        end

        # Com `lock`, o cupom é lido com FOR UPDATE para que o limite de usos valha sob concorrência.
        def load_coupon(tx, code, lock, now)
          text = P::Codes.normalize(code)
          return nil if text.empty?

          @pricing.find_coupon(tx, text, lock: lock, now: now) || raise(Domain::ValidationError.field("cupom", "cupom inexistente"))
        end

        def resolve_fees(tx, requests, previous, may_override, limit)
          ids = requests.filter_map(&:fee_id) + previous.filter_map { |entry| entry["fee_id"] }
          catalog = ids.empty? ? {} : @pricing.fees_by_ids(tx, ids)
          P::Fees.resolve(requests, catalog: catalog, previous: previous, may_override: may_override, reduction_limit_bps: limit)
        end
      end

      # Reservas ligadas a outros documentos são alteradas pelo próprio documento:
      #
      # - o bloqueio temporário de um orçamento ainda não convertido é confirmado somente pela
      #   conversão do orçamento aprovado e não é reagendado nem estendido (exige nova versão do
      #   orçamento); o cancelamento direto é permitido e equivale ao vencimento do bloqueio;
      # - reservas com contrato em aberto são estendidas por aditivo e canceladas pelo contrato, que
      #   aplica a política de cancelamento; o reagendamento não é permitido.
      #
      # `via:` identifica o caso de uso que compõe a operação (`:quote` ou `:contract`) e dispensa
      # somente a verificação do próprio vínculo. A composição com `tx:` não dispensa nada: outras
      # composições (por exemplo, a API com idempotência) passam pelas mesmas verificações.
      class ChangeGuard
        VIAS = [nil, :quote, :contract].freeze
        QUOTE_MESSAGES = {
          "confirm" => "a confirmação é feita pela conversão do orçamento aprovado",
          "reschedule" => "alterações de período exigem uma nova versão do orçamento",
          "extend" => "alterações de período exigem uma nova versão do orçamento"
        }.freeze
        CONTRACT_MESSAGES = {
          "reschedule" => "o reagendamento não é permitido; alterações de prazo são formalizadas por aditivo no contrato",
          "extend" => "a extensão deve ser registrada como aditivo no contrato",
          "cancel" => "cancele pelo contrato, que aplica a política de cancelamento"
        }.freeze

        def initialize(contracts:, quotes:)
          @contracts = contracts
          @quotes = quotes
        end

        def ensure_changeable!(tx, reservation, operation, via: nil)
          raise ArgumentError, "composição desconhecida: #{via.inspect}" unless VIAS.include?(via)

          ensure_not_quote_hold!(tx, reservation, operation) unless via == :quote
          ensure_without_contract!(tx, reservation, operation) unless via == :contract
          true
        end

        private

        def ensure_not_quote_hold!(tx, reservation, operation)
          message = QUOTE_MESSAGES[operation]
          quote = message && @quotes.holding(tx, reservation.id)
          return unless quote

          raise Domain::Conflict.new("A reserva #{reservation.code} é o bloqueio temporário do orçamento #{quote.code}: #{message}.",
                                     code: "quote_hold")
        end

        def ensure_without_contract!(tx, reservation, operation)
          message = CONTRACT_MESSAGES[operation]
          contract = message && @contracts.open_for_reservation(tx, reservation.id)
          return unless contract

          raise Domain::Conflict.new("A reserva #{reservation.code} possui o contrato #{contract.code}: #{message}.",
                                     code: "contract_amendment_required")
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
        # coupon_code, manual_discount_bps, fees, source, quote_id, pricing_snapshot.
        #
        # `pricing_snapshot` ({ items:, summary: }) é um snapshot de preços pré-calculado (por exemplo,
        # o da versão aprovada de um orçamento): substitui a precificação pelo catálogo atual e precisa
        # corresponder exatamente aos itens e ao período informados.
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
          priced = if input[:pricing_snapshot]
                     snapshot_pricing!(input[:pricing_snapshot], lines, period)
                   else
                     price(tx, current, input, products: products, lines: lines, period: period, org: org, customer: customer, now: now)
                   end
          reservation = build(tx, input, mode, org: org, customer: customer, branch_id: branch_id, period: period, summary: priced.summary,
                                               now: now)
          @reservations.insert(tx, reservation, priced.summary, current.audit_actor_id, now)
          @pricer.record_redemption(tx, priced, reservation: reservation, actor_id: current.audit_actor_id, now: now)
          items = insert_items(tx, reservation, priced.items, now)
          if reservation.occupying?
            @allocator.allocate(tx, reservation_id: reservation.id, branch_id: branch_id, period: period, items: items, now: now,
                                    actor_id: current.audit_actor_id)
          end
          finalize(tx, current, reservation, mode, priced)
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

        # Cupom travado (o uso é gravado na mesma transação); ajuste de tarifa exige `fees.override` e
        # a redução respeita o mesmo limite do desconto manual do papel (0 para credenciais).
        def price(tx, current, input, products:, lines:, period:, org:, customer:, now:)
          limit = current.user? ? Domain::Identity.discount_limit_bps(current.role) : 0
          @pricer.price(tx, products: products, lines: lines, period: period, zone: org.time_zone, customer_id: customer.id,
                            coupon_code: input[:coupon_code], manual_discount_bps: input.fetch(:manual_discount_bps, 0).to_i,
                            fees: input.fetch(:fees, []), fee_override: Authorizer.allowed?(current, "fees.override"), now: now,
                            discount_limit_bps: limit, lock_coupon: true)
        end

        # O snapshot é usado como está: itens e período precisam coincidir com a reserva solicitada. Um
        # snapshot pré-calculado nunca traz cupom (orçamentos não aplicam cupons e o uso não seria gravado).
        def snapshot_pricing!(snapshot, lines, period)
          items = snapshot.fetch(:items)
          summary = snapshot.fetch(:summary)
          expected = lines.map { |l| [l.product_id, l.quantity] }.sort
          given = items.map { |i| [i.fetch("product_id"), i.fetch("quantity")] }.sort
          raise Domain::ValidationError.field("precos", "o snapshot de preços não corresponde aos itens") unless expected == given
          raise Domain::ValidationError.field("precos", "o snapshot de preços não corresponde ao período") unless summary["period"] == period.to_h
          raise Domain::ValidationError.field("precos", "o snapshot de preços não pode conter cupom") if summary["coupon_code"] || summary["coupon"]

          Pricer::Priced.new(items: items, summary: summary, coupon: nil, overrides: [])
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

        # O uso do cupom é auditado aqui (o histórico do cupom fica só com as alterações de cadastro).
        def finalize(tx, current, reservation, mode, priced)
          reservation = reservation.with(code: @organizations.next_code(tx, "reservation", "R"))
          @reservations.assign_code(tx, reservation.id, reservation.code)
          details = { "code" => reservation.code, "status" => reservation.status, "mode" => mode,
                      "fees_cents" => priced.summary.fetch("fees_cents", 0) }
          details = details.merge("coupon_id" => priced.coupon.id, "coupon_code" => priced.coupon.code) if priced.coupon
          details["fee_overrides"] = priced.overrides unless priced.overrides.empty?
          @audit.record(tx, current, "reservation.created", "reservation", reservation.id, details)
          @events.publish(tx, "reservation.#{reservation.status}", "reservation", reservation.id, "code" => reservation.code)
          reservation
        end
      end

      # Confirmação com revalidação atômica sob lock da reserva e dos estoques envolvidos. O bloqueio
      # temporário de um orçamento é confirmado somente pela conversão (`via: :quote`).
      class ConfirmReservation
        def initialize(uow:, reservations:, allocator:, audit:, events:, clock:, guard:, expiry:)
          @uow = uow
          @reservations = reservations
          @allocator = allocator
          @audit = audit
          @events = events
          @clock = clock
          @guard = guard
          @expiry = expiry
        end

        def call(actor, reservation_id, tx: nil, via: nil)
          return execute(tx, actor, reservation_id, via) if tx

          result = @uow.run(actor, "reservations.write") do |t, current|
            execute(t, current, reservation_id, via)
          rescue Domain::HoldExpired
            :expired
          end
          raise Domain::HoldExpired if result == :expired

          result
        end

        private

        def execute(tx, current, reservation_id, via)
          now = @clock.now
          reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
          return reservation if reservation.status == "confirmed"

          @guard.ensure_changeable!(tx, reservation, "confirm", via: via)

          if reservation.hold_expired?(now)
            @expiry.expire(tx, current, reservation, now, "confirmation_attempt")
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
      end

      # Cancelamento. Reservas com contrato em aberto são canceladas pelo contrato, que aplica a
      # política de cancelamento e compõe este caso de uso com `via: :contract`. Qualquer outra
      # chamada, com ou sem `tx:`, passa pela verificação.
      class CancelReservation
        def initialize(uow:, reservations:, audit:, events:, clock:, guard:)
          @uow = uow
          @reservations = reservations
          @audit = audit
          @events = events
          @clock = clock
          @guard = guard
        end

        def call(actor, reservation_id, reason:, tx: nil, via: nil)
          return execute(tx, actor, reservation_id, reason, via) if tx

          @uow.run(actor, "reservations.cancel") { |t, current| execute(t, current, reservation_id, reason, via) }
        end

        private

        def execute(tx, current, reservation_id, reason, via)
          now = @clock.now
          reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
          @guard.ensure_changeable!(tx, reservation, "cancel", via: via)
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
      # conflito, a transação é desfeita e a reserva permanece no período original. Reservas com
      # contrato em aberto não são reagendadas (a alteração de prazo é feita por aditivo), nem o
      # bloqueio temporário de um orçamento (exige nova versão do orçamento).
      class RescheduleReservation
        def initialize(uow:, reservations:, organizations:, allocator:, audit:, clock:, guard:)
          @uow = uow
          @reservations = reservations
          @organizations = organizations
          @allocator = allocator
          @audit = audit
          @clock = clock
          @guard = guard
        end

        def call(actor, reservation_id, period:)
          @uow.run(actor, "reservations.write") do |tx, current|
            now = @clock.now
            reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
            @guard.ensure_changeable!(tx, reservation, "reschedule")
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
      #
      # Reservas com contrato em aberto são estendidas somente por aditivo (`AmendContract`), que
      # compõe este caso de uso na mesma transação (`tx:`, `via: :contract`). O bloqueio temporário de
      # um orçamento não é estendido diretamente.
      class ExtendReservation
        def initialize(uow:, reservations:, organizations:, allocator:, availability:, audit:, events:, clock:, ids:, guard:)
          @uow = uow
          @reservations = reservations
          @organizations = organizations
          @allocator = allocator
          @availability = availability
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
          @guard = guard
        end

        def call(actor, reservation_id, ends_at:, tx: nil, via: nil)
          return execute(tx, actor, reservation_id, ends_at, via) if tx

          @uow.run(actor, "reservations.write") { |t, current| execute(t, current, reservation_id, ends_at, via) }
        end

        private

        def execute(tx, current, reservation_id, ends_at, via)
          now = @clock.now
          reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id)) || raise(Domain::NotFound, "reserva")
          @guard.ensure_changeable!(tx, reservation, "extend", via: via)
          extended = reservation.extend_to(ends_at, now)
          products = @allocator.products_for(tx, @reservations.allocated_product_ids(tx, reservation.id))
          extend_allocations(tx, reservation, extended, products, now)
          adjustment = record_adjustments(tx, current, reservation, extended, ends_at, now)
          @reservations.update_period(tx, extended, now, extension_cents: adjustment)
          @audit.record(tx, current, "reservation.extended", "reservation", reservation.id,
                        "from_end" => reservation.period.ends_at.iso8601, "to_end" => ends_at.iso8601, "adjustment_cents" => adjustment)
          @events.publish(tx, "reservation.extended", "reservation", reservation.id, "adjustment_cents" => adjustment)
          { reservation: extended, adjustment: Domain::Money.new(adjustment) }
        end

        # Diferença por item calculada com o snapshot da tabela contratada; o preço original é mantido.
        def record_adjustments(tx, current, reservation, extended, ends_at, now)
          zone = @organizations.find(tx, tx.tenant_id!).time_zone
          @reservations.items(tx, reservation.id).sum do |item|
            next 0 if item["pricing"].fetch("table", {}).empty?

            delta, repriced = Domain::Pricing::Extension.adjustment(line_snapshot: item["pricing"], new_period: extended.period, zone: zone)
            @reservations.insert_adjustment(tx, "id" => @ids.uuid, "reservation_id" => reservation.id, "reservation_item_id" => item["id"],
                                                "kind" => "extension", "amount_cents" => delta.cents, "created_by" => current.audit_actor_id,
                                                "details" => { "from_end" => reservation.period.ends_at.iso8601, "to_end" => ends_at.iso8601,
                                                               "repriced_total_cents" => repriced["total_cents"] }, "created_at" => now)
            delta.cents
          end
        end

        def extend_allocations(tx, reservation, extended, products, now)
          shortages = []
          bulk_ids = products.values.map { |p| p[:product] }.select(&:bulk?).map(&:id).sort
          @availability.lock_pools(tx, reservation.branch_id, bulk_ids)
          @reservations.active_allocation_rows(tx, reservation.id).each do |allocation|
            product = products.fetch(allocation["product_id"])[:product]
            window = product.blocked_period(extended.period)
            if allocation["asset_id"]
              begin
                tx.savepoint { @availability.extend_asset_allocation(tx, allocation["id"], window) }
              rescue AllocationConflict
                shortages << { "product_id" => product.id, "sku" => product.sku, "asset_id" => allocation["asset_id"],
                               "conflict" => @availability.conflicting_reservation_code(tx, allocation["asset_id"], window, reservation.id) }
              end
            else
              @availability.extend_stock_allocation(tx, allocation["id"], window)
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
      # Expiração de bloqueio temporário, qualquer que seja o gatilho (varredura, tentativa de
      # confirmação ou alocação que encontra o bloqueio vencido): situação, liberação das alocações,
      # auditoria e evento `reservation.expired` na mesma transação.
      class HoldExpiry
        def initialize(reservations:, audit:, events:)
          @reservations = reservations
          @audit = audit
          @events = events
        end

        def expire(tx, actor, reservation, now, trigger)
          expired = reservation.expire(now)
          @reservations.update_status(tx, expired, now, "expired_at" => now)
          @reservations.release_allocations(tx, reservation.id, now)
          record(tx, actor, reservation.id, reservation.code, trigger)
          expired
        end

        # Reservas já gravadas como expiradas por uma instrução em lote (alocador).
        def record(tx, actor, reservation_id, code, trigger)
          @audit.record(tx, actor, "reservation.expired", "reservation", reservation_id, "trigger" => trigger)
          @events.publish(tx, "reservation.expired", "reservation", reservation_id, "code" => code)
        end
      end

      class ExpireHolds
        def initialize(uow:, reservations:, expiry:, clock:)
          @uow = uow
          @reservations = reservations
          @expiry = expiry
          @clock = clock
        end

        def call(actor, limit: 200)
          @uow.run(actor) do |tx, current|
            now = @clock.now
            @reservations.lock_expired_holds(tx, now, limit).map do |reservation|
              @expiry.expire(tx, current, reservation, now, "sweeper")
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
            names = self.class.customer_names?(current)
            items, total = @reservations.search(tx, status: status, customer_id: customer, search: search.to_s.strip[0, 40],
                                                    from: from, to: to, sort: sort, limit: lim, offset: off, customer_names: names)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end

        # O nome do cliente (na listagem e na busca) exige `customers.read`, como nos detalhes do
        # cliente; o portal lista somente as reservas do próprio cliente. Sem o escopo, `customer_name`
        # vem nil e a busca considera apenas o código da reserva.
        def self.customer_names?(actor)
          actor.customer? || Authorizer.allowed?(actor, "customers.read")
        end
      end

      class GetReservation
        def initialize(uow:, reservations:)
          @uow = uow
          @reservations = reservations
        end

        def call(actor, reservation_id)
          details(actor) { |tx| @reservations.find(tx, Domain::Identifier.parse(reservation_id)) }
        end

        # Reserva pelo código (R-000001) ou pelo identificador, com as mesmas permissões.
        def by_reference(actor, reference)
          text = reference.to_s.strip
          raise Domain::ValidationError.field("reserva", "informe o código ou o identificador") if text.empty?

          details(actor) { |tx| Domain::Identifier.valid?(text) ? @reservations.find(tx, text.downcase) : @reservations.find_by_code(tx, text) }
        end

        private

        def details(actor)
          @uow.run(actor, actor.customer? ? "portal.access" : "reservations.read") do |tx, current|
            reservation = yield(tx) || raise(Domain::NotFound, "reserva")
            raise Domain::NotFound, "reserva" if current.customer? && reservation.customer_id != current.customer_id

            { reservation: reservation, items: @reservations.items(tx, reservation.id), allocations: @reservations.allocation_details(tx, reservation.id),
              pricing: @reservations.pricing(tx, reservation.id) }
          end
        end
      end
    end
  end
end
