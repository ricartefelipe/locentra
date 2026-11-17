# frozen_string_literal: true

module Locentra
  module Application
    # Sinaliza violação da exclusion constraint de alocações (outro processo alocou o mesmo ativo).
    class AllocationConflict < StandardError; end

    module Availability
      AV = Domain::Availability

      # Aloca disponibilidade dentro de uma transação já aberta.
      #
      # Sequência: carrega produtos e componentes, bloqueia (FOR UPDATE) os estoques quantitativos
      # envolvidos em ordem determinística, expira bloqueios temporários vencidos que ainda ocupam
      # esses produtos, calcula faltas com o domínio e só então insere as alocações. Ativos
      # individuais são inseridos sob savepoint; se outra transação alocou o mesmo ativo, a
      # exclusion constraint rejeita e o próximo candidato livre é tentado.
      class Allocator
        def initialize(repository:, ids:)
          @repository = repository
          @ids = ids
        end

        # items: [{id:, product_id:, quantity:}] — linhas persistidas da reserva.
        def allocate(tx, reservation_id:, branch_id:, period:, items:, now:, preferred_assets: [], actor_id: nil)
          context = prepare(tx, branch_id, items.map { |i| i[:product_id] }, now)
          demands = expand(context, items)
          shortages = shortages_for(tx, context, demands, branch_id, period, now)
          raise Domain::Unavailable, shortages unless shortages.empty?

          insert_all(tx, context, demands, reservation_id: reservation_id, branch_id: branch_id, period: period, now: now,
                                           preferred: preferred_assets, actor_id: actor_id)
        end

        # Verifica disponibilidade sem alocar; retorna lista de faltas (vazia quando disponível).
        def check(tx, branch_id:, period:, lines:, now:)
          context = prepare(tx, branch_id, lines.map { |l| l[:product_id] }, now, lock: false)
          demands = expand(context, lines.each_with_index.map { |l, i| l.merge(id: i.to_s) })
          shortages_for(tx, context, demands, branch_id, period, now)
        end

        # Revalida as alocações existentes de uma reserva (confirmação de bloqueio temporário).
        # Ativos que deixaram de ser alocáveis são substituídos por outra unidade livre quando possível.
        def revalidate(tx, reservation_id:, branch_id:, period:, now:)
          allocations = @repository.active_allocations(tx, reservation_id)
          product_ids = (allocations[:assets].map { |a| a["product_id"] } + allocations[:stock].map { |s| s["product_id"] }).uniq
          context = prepare(tx, branch_id, product_ids, now)
          shortages = []
          allocations[:assets].each do |allocation|
            next if @repository.asset_allocatable?(tx, allocation["asset_id"], allocation_window(context, allocation["product_id"], period))

            shortages << allocation["product_id"] unless reassign(tx, context, allocation, branch_id, period, now)
          end
          allocations[:stock].group_by { |s| s["stock_pool_id"] }.each_value do |rows|
            pool = context[:pools].fetch(rows.first["product_id"], nil)
            window = allocation_window(context, rows.first["product_id"], period)
            ledger = AV::StockLedger.new(capacity: pool ? pool["total_quantity"] : 0,
                                         occupancies: @repository.stock_occupancies(tx, rows.first["stock_pool_id"], window, now))
            shortages << rows.first["product_id"] if ledger.peak(window) > ledger.capacity
          end
          raise(Domain::Unavailable, shortages.uniq.map { |id| { "product_id" => id, "reason" => "revalidação" } }) unless shortages.empty?

          true
        end

        # Tenta mover uma alocação de ativo para outra unidade livre do mesmo produto e filial.
        def reassign(tx, context, allocation, branch_id, period, now)
          product_id = allocation["product_id"]
          window = allocation_window(context, product_id, period)
          schedules = @repository.asset_schedules(tx, product_id, branch_id, window, now)
          AV::AssetPicker.pick(window, schedules, schedules.size, exclude: [allocation["asset_id"]]).each do |candidate|
            tx.savepoint { @repository.reassign_asset_allocation(tx, allocation["id"], candidate) }
            return candidate
          rescue AllocationConflict
            next
          end
          nil
        end

        def products_for(tx, product_ids)
          @repository.product_specs(tx, product_ids)
        end

        private

        def prepare(tx, branch_id, product_ids, now, lock: true)
          products = @repository.product_specs(tx, product_ids)
          physical = products.values.reject { |p| p[:product].kit? }
          bulk_ids = physical.select { |p| p[:product].bulk? }.map { |p| p[:product].id }.sort
          pools = lock ? @repository.lock_pools(tx, branch_id, bulk_ids) : @repository.pools(tx, branch_id, bulk_ids)
          @repository.release_stale_holds(tx, physical.map { |p| p[:product].id }, now) if lock
          { products: products, pools: pools }
        end

        def expand(context, items)
          specs = context[:products].transform_values { |p| p[:spec] }
          expander = AV::DemandExpander.new(specs)
          demands = expander.expand(items.map { |i| { product_id: i[:product_id], quantity: i[:quantity] } })
          demands.map { |d| { demand: d, item_id: items[d.line_index][:id] } }
        end

        def allocation_window(context, product_id, period)
          context[:products].fetch(product_id)[:product].blocked_period(period)
        end

        def shortages_for(tx, context, demands, branch_id, period, now)
          demands.group_by { |d| d[:demand].product_id }.filter_map do |product_id, list|
            product = context[:products].fetch(product_id)[:product]
            window = product.blocked_period(period)
            requested = list.sum { |d| d[:demand].quantity }
            available = available_units(tx, context, product, branch_id, window, now)
            next if requested <= available

            { "product_id" => product_id, "sku" => product.sku, "name" => product.name, "requested" => requested, "available" => available }
          end
        end

        def available_units(tx, context, product, branch_id, window, now)
          if product.bulk?
            pool = context[:pools][product.id]
            return 0 unless pool

            AV::StockLedger.new(capacity: pool["total_quantity"],
                                occupancies: @repository.stock_occupancies(tx, pool["id"], window,
                                                                           now)).available(window)
          else
            AV::AssetPicker.available_count(window, @repository.asset_schedules(tx, product.id, branch_id, window, now))
          end
        end

        def insert_all(tx, context, demands, reservation_id:, branch_id:, period:, now:, preferred:, actor_id:)
          used_assets = []
          demands.flat_map do |entry|
            demand = entry[:demand]
            product = context[:products].fetch(demand.product_id)[:product]
            window = product.blocked_period(period)
            base = { "organization_id" => tx.tenant_id!, "product_id" => product.id, "reservation_id" => reservation_id,
                     "reservation_item_id" => entry[:item_id], "kind" => "reservation", "period" => window, "created_by" => actor_id, "created_at" => now }
            if product.bulk?
              pool = context[:pools].fetch(product.id)
              row = base.merge("id" => @ids.uuid, "stock_pool_id" => pool["id"], "quantity" => demand.quantity)
              @repository.insert_stock_allocation(tx, row)
              [row]
            else
              Array.new(demand.quantity) do
                asset_id = insert_asset(tx, product, branch_id, window, now, base, used_assets, preferred)
                used_assets << asset_id
                base.merge("asset_id" => asset_id)
              end
            end
          end
        end

        def insert_asset(tx, product, branch_id, window, now, base, used, preferred)
          schedules = @repository.asset_schedules(tx, product.id, branch_id, window, now)
          free = AV::AssetPicker.pick(window, schedules, schedules.size, exclude: used)
          candidates = (preferred & free) + (free - preferred)
          candidates.each do |asset_id|
            tx.savepoint { @repository.insert_asset_allocation(tx, base.merge("id" => @ids.uuid, "asset_id" => asset_id)) }
            return asset_id
          rescue AllocationConflict
            next
          end
          raise Domain::Unavailable,
                [{ "product_id" => product.id, "sku" => product.sku, "name" => product.name, "requested" => 1, "available" => 0 }]
        end
      end

      # Consulta de disponibilidade por período, inclusive para kits.
      class CheckAvailability
        def initialize(uow:, repository:, allocator:, clock:)
          @uow = uow
          @repository = repository
          @allocator = allocator
          @clock = clock
        end

        def call(actor, branch_id:, period:, product_ids: nil)
          @uow.run(actor, "availability.read") do |tx, _current|
            branch = Domain::Identifier.parse(branch_id, "filial")
            ids = product_ids&.map { |id| Domain::Identifier.parse(id, "produto") } || @repository.active_product_ids(tx)
            products = @allocator.products_for(tx, ids)
            now = @clock.now
            physical = products.values.reject { |p| p[:product].kit? }.to_h do |p|
              [p[:product].id, units(tx, p[:product], branch, period, now)]
            end
            ids.filter_map do |id|
              entry = products[id]
              next unless entry

              product = entry[:product]
              result = if product.kit?
                         kit_units(entry[:spec], physical)
                       else
                         physical.fetch(id)
                       end
              { "product" => product, "available" => result[:available], "total" => result[:total] }
            end
          end
        end

        private

        def units(tx, product, branch_id, period, now)
          window = product.blocked_period(period)
          if product.bulk?
            pool = @repository.pools(tx, branch_id, [product.id])[product.id]
            return { available: 0, total: 0 } unless pool

            ledger = AV::StockLedger.new(capacity: pool["total_quantity"],
                                         occupancies: @repository.stock_occupancies(tx,
                                                                                    pool["id"], window, now))
            { available: ledger.available(window), total: pool["total_quantity"] }
          else
            schedules = @repository.asset_schedules(tx, product.id, branch_id, window, now)
            { available: AV::AssetPicker.available_count(window, schedules), total: schedules.size }
          end
        end

        def kit_units(spec, physical)
          counts = spec.components.map do |component|
            stock = physical.fetch(component.fetch(:product_id), { available: 0, total: 0 })
            [stock[:available] / component.fetch(:quantity), stock[:total] / component.fetch(:quantity)]
          end
          { available: counts.map(&:first).min || 0, total: counts.map(&:last).min || 0 }
        end
      end

      # Calendário: disponibilidade por dia local da organização.
      class Calendar
        MAX_DAYS = 31

        def initialize(uow:, check:, organizations:)
          @uow = uow
          @check = check
          @organizations = organizations
        end

        def call(actor, branch_id:, start_date:, days:, product_ids: nil)
          count = Integer(days.to_s, 10)
          raise Domain::ValidationError.field("dias", "entre 1 e #{MAX_DAYS}") unless count.between?(1, MAX_DAYS)

          zone = @uow.run(actor, "availability.read") { |tx, _| @organizations.find(tx, tx.tenant_id!).time_zone }
          dates = (0...count).map { |offset| start_date + offset }
          columns = dates.map do |date|
            window = Domain::Period.new(zone.start_of_day(date), zone.start_of_day(date + 1))
            { date: date, rows: @check.call(actor, branch_id: branch_id, period: window, product_ids: product_ids) }
          end
          { zone: zone, dates: dates, columns: columns }
        rescue ArgumentError
          raise Domain::ValidationError.field("dias", "número inteiro")
        end
      end
    end
  end
end
