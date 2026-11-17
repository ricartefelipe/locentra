# frozen_string_literal: true

module Locentra
  module Application
    # Ordens de manutenção: abrir, iniciar, concluir (com custo) e cancelar, com histórico do ativo.
    module Maintenance
      # Abertura manual. Ativo: somente disponível (itens em inspeção são encaminhados pela reprovação);
      # reservas futuras são realocadas e, sem substituto, a abertura é recusada. Estoque: bloqueia as
      # unidades sem descobrir reservas futuras.
      class OpenMaintenanceOrder
        def initialize(uow:, catalog:, allocations:, availability:, desk:, ledger:, relocation:, audit:, clock:)
          @uow = uow
          @catalog = catalog
          @allocations = allocations
          @availability = availability
          @desk = desk
          @ledger = ledger
          @relocation = relocation
          @audit = audit
          @clock = clock
        end

        def call(actor, description:, asset_id: nil, product_id: nil, branch_id: nil, quantity: nil)
          @uow.run(actor, "maintenance.write") do |tx, current|
            now = @clock.now
            order = if asset_id.to_s.empty?
                      for_stock(tx, current, product_id, branch_id, quantity, description, now)
                    else
                      for_asset(tx, current, asset_id, description, now)
                    end
            @audit.record(tx, current, "maintenance.opened", "maintenance_order", order.id,
                          "code" => order.code, "asset_id" => order.asset_id, "stock_pool_id" => order.stock_pool_id, "quantity" => order.quantity)
            order
          end
        end

        private

        def for_asset(tx, current, asset_id, description, now)
          asset = @catalog.lock_asset(tx, Domain::Identifier.parse(asset_id, "ativo")) || raise(Domain::NotFound, "ativo")
          if asset.status == "in_inspection"
            raise Domain::Conflict.new("ativo em inspeção: reprove a inspeção para encaminhá-lo à manutenção", code: "asset_in_inspection")
          end
          raise Domain::InvalidTransition.new("ativo", asset.status, "in_maintenance") unless asset.status == "available"

          order = @desk.open_order(tx, current, product_id: asset.product_id, branch_id: asset.branch_id, description: description, now: now,
                                                asset_id: asset.id, previous_status: asset.status)
          moved = @ledger.move(tx, current, asset, "in_maintenance", kind: "maintenance_opened", now: now, reference_type: "maintenance_order",
                                                                     reference_id: order.id, notes: order.description)
          unresolved = @relocation.relocate(tx, moved, now)
          unless unresolved.empty?
            codes = unresolved.map { |a| a["reservation_code"] }.uniq.join(", ")
            raise Domain::Conflict.new("ativo possui reservas sem unidade substituta: #{codes}", code: "asset_committed")
          end
          order
        end

        def for_stock(tx, current, product_id, branch_id, quantity, description, now)
          qty = positive_quantity!(quantity)
          found = @allocations.find_pool(tx, Domain::Identifier.parse(product_id, "produto"), Domain::Identifier.parse(branch_id, "filial"))
          pool = (found && @allocations.lock_pool(tx, found.id)) || raise(Domain::NotFound, "estoque")
          window = Operations.horizon(now)
          ledger = Domain::Availability::StockLedger.new(capacity: pool.total_quantity, occupancies: @availability.stock_occupancies(tx, pool.id, window, now))
          unless ledger.fits?(window, qty)
            raise Domain::Unavailable.new([{ "stock_pool_id" => pool.id, "requested" => qty, "available" => ledger.available(window) }],
                                          "Unidades comprometidas com reservas futuras")
          end

          block = @desk.block_stock(tx, current, pool, qty, "Manutenção", now)
          @desk.open_order(tx, current, product_id: pool.product_id, branch_id: pool.branch_id, description: description, now: now,
                                        pool_id: pool.id, quantity: qty, block_allocation_id: block)
        end

        def positive_quantity!(value)
          qty = Integer(value.to_s.strip, 10)
          raise Domain::ValidationError.field("quantidade", "deve ser positiva") unless qty.positive?

          qty
        rescue ArgumentError
          raise Domain::ValidationError.field("quantidade", "número inteiro")
        end
      end

      # Carrega a ordem com lock e o ativo, quando houver.
      module OrderLocking
        private

        def lock_order!(tx, order_id)
          @orders.lock(tx, Domain::Identifier.parse(order_id)) || raise(Domain::NotFound, "ordem de manutenção")
        end
      end

      class StartMaintenance
        include OrderLocking

        def initialize(uow:, orders:, catalog:, ledger:, audit:, clock:)
          @uow = uow
          @orders = orders
          @catalog = catalog
          @ledger = ledger
          @audit = audit
          @clock = clock
        end

        def call(actor, order_id)
          @uow.run(actor, "maintenance.write") do |tx, current|
            order = lock_order!(tx, order_id)
            now = @clock.now
            started = order.start(now)
            @orders.update(tx, started, current.audit_actor_id)
            if order.asset?
              @ledger.note(tx, current, @catalog.lock_asset(tx, order.asset_id), kind: "maintenance_started", now: now,
                                                                                 reference_type: "maintenance_order", reference_id: order.id)
            end
            @audit.record(tx, current, "maintenance.started", "maintenance_order", order.id, "code" => order.code)
            started
          end
        end
      end

      # Concluir registra o custo; o item volta a disponível ou segue para inspeção quando exigido.
      class CompleteMaintenance
        include OrderLocking

        def initialize(uow:, orders:, catalog:, allocations:, desk:, ledger:, audit:, clock:)
          @uow = uow
          @orders = orders
          @catalog = catalog
          @allocations = allocations
          @desk = desk
          @ledger = ledger
          @audit = audit
          @clock = clock
        end

        def call(actor, order_id, cost:, requires_inspection: false, notes: nil)
          @uow.run(actor, "maintenance.write") do |tx, current|
            order = lock_order!(tx, order_id)
            now = @clock.now
            completed = order.complete(cost: cost, requires_inspection: requires_inspection, now: now, notes: notes)
            @orders.update(tx, completed, current.audit_actor_id)
            completed.asset? ? finish_asset(tx, current, completed, now) : finish_stock(tx, completed, now)
            @audit.record(tx, current, "maintenance.completed", "maintenance_order", order.id,
                          "code" => order.code, "cost_cents" => completed.cost.cents, "requires_inspection" => completed.requires_inspection)
            completed
          end
        end

        private

        def finish_asset(tx, current, order, now)
          asset = @catalog.lock_asset(tx, order.asset_id)
          target = order.requires_inspection ? "in_inspection" : "available"
          @ledger.move(tx, current, asset, target, kind: "maintenance_completed", now: now, reference_type: "maintenance_order",
                                                   reference_id: order.id, notes: "Custo #{order.cost.format_brl}")
          return unless order.requires_inspection

          @desk.open_inspection(tx, product_id: order.product_id, branch_id: asset.branch_id, reason: "Inspeção após a manutenção #{order.code}",
                                    now: now, asset_id: asset.id, source_order_id: order.id)
        end

        def finish_stock(tx, order, now)
          return @allocations.end_stock_block(tx, order.block_allocation_id, now) unless order.requires_inspection

          @desk.open_inspection(tx, product_id: order.product_id, branch_id: order.branch_id, reason: "Inspeção após a manutenção #{order.code}",
                                    now: now, pool_id: order.stock_pool_id, quantity: order.quantity,
                                    block_allocation_id: order.block_allocation_id, source_order_id: order.id)
        end
      end

      # Cancelar devolve o item à situação anterior: inspeção (quando veio de inspeção reprovada) ou
      # disponível. Itens que retornam à inspeção recebem nova inspeção pendente.
      class CancelMaintenance
        include OrderLocking

        def initialize(uow:, orders:, catalog:, allocations:, desk:, ledger:, audit:, clock:)
          @uow = uow
          @orders = orders
          @catalog = catalog
          @allocations = allocations
          @desk = desk
          @ledger = ledger
          @audit = audit
          @clock = clock
        end

        def call(actor, order_id, reason:)
          @uow.run(actor, "maintenance.write") do |tx, current|
            order = lock_order!(tx, order_id)
            now = @clock.now
            cancelled = order.cancel(reason, now)
            @orders.update(tx, cancelled, current.audit_actor_id)
            cancelled.asset? ? restore_asset(tx, current, cancelled, now) : restore_stock(tx, cancelled, now)
            @audit.record(tx, current, "maintenance.cancelled", "maintenance_order", order.id, "code" => order.code,
                                                                                               "reason" => cancelled.cancellation_reason)
            cancelled
          end
        end

        private

        def restore_asset(tx, current, order, now)
          asset = @catalog.lock_asset(tx, order.asset_id)
          target = order.status_after_cancel
          @ledger.move(tx, current, asset, target, kind: "maintenance_cancelled", now: now, reference_type: "maintenance_order",
                                                   reference_id: order.id, notes: order.cancellation_reason)
          return unless target == "in_inspection"

          @desk.open_inspection(tx, product_id: order.product_id, branch_id: asset.branch_id, now: now, asset_id: asset.id, source_order_id: order.id,
                                    reason: "Retorno à inspeção: manutenção #{order.code} cancelada")
        end

        def restore_stock(tx, order, now)
          return @allocations.end_stock_block(tx, order.block_allocation_id, now) unless order.inspection_id

          @desk.open_inspection(tx, product_id: order.product_id, branch_id: order.branch_id, now: now, pool_id: order.stock_pool_id,
                                    quantity: order.quantity, block_allocation_id: order.block_allocation_id, source_order_id: order.id,
                                    reason: "Retorno à inspeção: manutenção #{order.code} cancelada")
        end
      end

      class ListMaintenanceOrders
        FILTERS = %w[active closed all].freeze

        def initialize(uow:, orders:)
          @uow = uow
          @orders = orders
        end

        def call(actor, filter: "active")
          raise Domain::ValidationError.field("situacao", "inválida") unless FILTERS.include?(filter)

          @uow.run(actor, "catalog.read") { |tx, _| @orders.list(tx, filter: filter) }
        end
      end

      class GetMaintenanceOrder
        def initialize(uow:, orders:, catalog:, attachments:)
          @uow = uow
          @orders = orders
          @catalog = catalog
          @attachments = attachments
        end

        def call(actor, order_id)
          @uow.run(actor, "catalog.read") do |tx, _|
            order = @orders.find(tx, Domain::Identifier.parse(order_id)) || raise(Domain::NotFound, "ordem de manutenção")
            events = order.asset? ? @catalog.asset_events(tx, order.asset_id).select { |e| e["reference_id"] == order.id } : []
            { order: order, labels: @orders.labels(tx, order.id), events: events,
              attachments: @attachments.for_owner(tx, "maintenance_order", order.id) }
          end
        end
      end
    end
  end
end
