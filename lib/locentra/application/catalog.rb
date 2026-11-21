# frozen_string_literal: true

module Locentra
  module Application
    module Catalog
      class CreateProduct
        def initialize(uow:, catalog:, pricing_rules:, audit:, clock:, ids:)
          @uow = uow
          @catalog = catalog
          @pricing_rules = pricing_rules
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, attrs)
          @uow.run(actor, "catalog.write") do |tx, current|
            product = Domain::Catalog::Product.build(
              id: @ids.uuid, organization_id: tx.tenant_id!, sku: attrs[:sku], name: attrs[:name], tracking: attrs[:tracking].to_s,
              description: attrs[:description], category: attrs[:category],
              buffer_before_minutes: attrs.fetch(:buffer_before_minutes, 0), buffer_after_minutes: attrs.fetch(:buffer_after_minutes, 0),
              deposit: attrs.fetch(:deposit, Domain::Money.zero), replacement_cost: attrs.fetch(:replacement_cost, Domain::Money.zero),
              pricing: @pricing_rules.normalize(attrs.fetch(:pricing, {}))
            )
            raise Domain::Conflict.new("SKU já cadastrado", code: "duplicate_sku") if @catalog.sku_taken?(tx, product.sku)

            @catalog.insert_product(tx, product, @clock.now)
            @audit.record(tx, current, "product.created", "product", product.id, "sku" => product.sku, "tracking" => product.tracking)
            product
          end
        end
      end

      class UpdateProductPricing
        def initialize(uow:, catalog:, pricing_rules:, audit:, clock:)
          @uow = uow
          @catalog = catalog
          @pricing_rules = pricing_rules
          @audit = audit
          @clock = clock
        end

        def call(actor, product_id, pricing:, deposit: nil)
          @uow.run(actor, "catalog.write") do |tx, current|
            product = @catalog.lock_product(tx, Domain::Identifier.parse(product_id)) || raise(Domain::NotFound, "produto")
            updated = product.with(pricing: @pricing_rules.normalize(pricing), deposit: deposit || product.deposit)
            @catalog.update_product_pricing(tx, updated, @clock.now)
            @audit.record(tx, current, "product.pricing_updated", "product", product.id, "pricing" => updated.pricing)
            updated
          end
        end
      end

      # Define a composição do kit. Componentes devem ser físicos; kits não são aninhados.
      class SetKitComponents
        def initialize(uow:, catalog:, audit:)
          @uow = uow
          @catalog = catalog
          @audit = audit
        end

        def call(actor, kit_id, components)
          @uow.run(actor, "catalog.write") do |tx, current|
            kit = @catalog.lock_product(tx, Domain::Identifier.parse(kit_id)) || raise(Domain::NotFound, "kit")
            raise Domain::ValidationError.field("produto", "não é um kit") unless kit.kit?

            list = components.map do |c|
              { product_id: Domain::Identifier.parse(c[:product_id], "componente"), quantity: Integer(c[:quantity].to_s, 10) }
            rescue ArgumentError
              raise Domain::ValidationError.field("componentes", "quantidade inválida")
            end
            specs = @catalog.specs_by_id(tx, list.map { |c| c[:product_id] })
            Domain::Availability::KitRules.validate!(kit.id, list, specs)
            @catalog.replace_kit_components(tx, kit.id, list.map { |c| c.merge(tracking: specs.fetch(c[:product_id]).tracking) })
            @audit.record(tx, current, "product.kit_updated", "product", kit.id, "components" => list.map { |c| c.transform_keys(&:to_s) })
            list
          end
        end
      end

      class RegisterAsset
        def initialize(uow:, catalog:, organizations:, limits:, audit:, clock:, ids:)
          @uow = uow
          @catalog = catalog
          @organizations = organizations
          @limits = limits
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, attrs)
          @uow.run(actor, "assets.write") do |tx, current|
            product = @catalog.find_product(tx,
                                            Domain::Identifier.parse(attrs[:product_id], "produto")) || raise(Domain::NotFound, "produto")
            raise Domain::ValidationError.field("produto", "produto não é rastreado individualmente") unless product.serialized?

            # Filial ativa, travada antes da assinatura (ordem filial → assinatura).
            branch_id = Organizations::BranchGuard.active!(@organizations, tx, attrs[:branch_id], field: "filial").id
            @limits.ensure!(tx, :assets)
            asset = Domain::Catalog::Asset.build(
              id: @ids.uuid, organization_id: tx.tenant_id!, product_id: product.id, branch_id: branch_id, tag: attrs[:tag],
              serial_number: attrs[:serial_number], condition: attrs.fetch(:condition, "good").to_s,
              acquisition_cost: attrs.fetch(:acquisition_cost, Domain::Money.zero), acquired_on: attrs[:acquired_on], notes: attrs[:notes]
            )
            raise Domain::Conflict.new("patrimônio já cadastrado", code: "duplicate_tag") if @catalog.tag_taken?(tx, asset.tag)

            now = @clock.now
            @catalog.insert_asset(tx, asset, now)
            @catalog.insert_asset_event(tx, "id" => @ids.uuid, "asset_id" => asset.id, "kind" => "registered", "to_status" => asset.status,
                                            "to_branch_id" => branch_id, "actor_id" => current.audit_actor_id, "occurred_at" => now)
            @audit.record(tx, current, "asset.registered", "asset", asset.id, "tag" => asset.tag)
            asset
          end
        end
      end

      # Entrada, baixa, perda ou ajuste de estoque quantitativo. Reduções não podem deixar
      # reservas futuras sem cobertura. Entradas (e ajustes positivos) exigem filial ativa; baixa, perda e
      # ajuste negativo valem também em filial inativa (o estoque continua vinculado a ela).
      class AdjustStock
        KINDS = { "acquisition" => 1, "adjustment" => 0, "write_off" => -1, "loss" => -1 }.freeze

        def initialize(uow:, catalog:, organizations:, availability:, limits:, audit:, clock:, ids:)
          @uow = uow
          @catalog = catalog
          @organizations = organizations
          @availability = availability
          @limits = limits
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, product_id:, branch_id:, quantity:, kind:, reason: nil)
          raise Domain::ValidationError.field("tipo", "movimento inválido") unless KINDS.key?(kind)

          delta = Integer(quantity.to_s, 10)
          delta = -delta.abs if KINDS[kind].negative?
          delta = delta.abs if KINDS[kind].positive?
          raise Domain::ValidationError.field("quantidade", "diferente de zero") if delta.zero?

          @uow.run(actor, "assets.write") do |tx, current|
            product = @catalog.find_product(tx, Domain::Identifier.parse(product_id, "produto")) || raise(Domain::NotFound, "produto")
            raise Domain::ValidationError.field("produto", "produto não é de estoque quantitativo") unless product.bulk?

            branch = stock_branch!(tx, branch_id, delta)
            @limits.ensure!(tx, :assets, adding: delta) if delta.positive?
            now = @clock.now
            pool = @catalog.lock_or_create_pool(tx, @ids.uuid, product.id, branch, now)
            updated = pool.adjust(delta)
            ensure_coverage!(tx, updated, now) if delta.negative?
            @catalog.update_pool_total(tx, updated, now)
            @catalog.insert_stock_movement(tx, "id" => @ids.uuid, "stock_pool_id" => pool.id, "kind" => kind, "quantity_delta" => delta,
                                               "reason" => Domain::Organizations::Text.optional(reason, max: 300), "actor_id" => current.audit_actor_id,
                                               "occurred_at" => now)
            @audit.record(tx, current, "stock.adjusted", "stock_pool", pool.id, "kind" => kind, "delta" => delta,
                                                                                "total" => updated.total_quantity)
            updated
          end
        rescue ArgumentError
          raise Domain::ValidationError.field("quantidade", "número inteiro")
        end

        private

        def stock_branch!(tx, branch_id, delta)
          return Organizations::BranchGuard.active!(@organizations, tx, branch_id, field: "filial").id if delta.positive?

          branch = Domain::Identifier.parse(branch_id, "filial")
          raise Domain::NotFound.new("filial", feminine: true) unless @catalog.branch_exists?(tx, branch)

          branch
        end

        def ensure_coverage!(tx, pool, now)
          horizon = Domain::Period.new(now, now + (366 * 86_400))
          peak = Domain::Availability::Peak.within(horizon, @availability.stock_occupancies(tx, pool.id, horizon, now))
          return if peak <= pool.total_quantity

          raise Domain::Conflict.new("redução deixaria reservas futuras sem cobertura (pico reservado: #{peak})", code: "stock_committed")
        end
      end

      # Mudança de situação operacional (manutenção, perda, baixa, retorno). Reservas futuras do
      # ativo são realocadas para outra unidade; sem substituto, a operação é recusada e as
      # reservas afetadas são informadas para decisão.
      class ChangeAssetStatus
        TARGETS = %w[available in_maintenance in_inspection lost retired].freeze
        # Situações controladas pelos fluxos de operação: a mudança manual não pode contorná-los.
        MANAGED = { "checked_out" => "registre a devolução da reserva", "in_transit" => "registre o recebimento da transferência" }.freeze
        HOLDS = { "inspection" => "decida a inspeção pendente", "maintenance" => "conclua ou cancele a ordem de manutenção" }.freeze

        def initialize(uow:, catalog:, availability:, allocator:, audit:, clock:, ids:)
          @uow = uow
          @catalog = catalog
          @availability = availability
          @allocator = allocator
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, asset_id, status:, reason: nil, unavailable_until: nil)
          raise Domain::ValidationError.field("situacao", "situação inválida") unless TARGETS.include?(status)

          @uow.run(actor, "assets.write") do |tx, current|
            asset = @catalog.lock_asset(tx, Domain::Identifier.parse(asset_id)) || raise(Domain::NotFound, "ativo")
            guard_operational!(tx, asset)
            now = @clock.now
            updated = asset.transition_to(status, unavailable_until: unavailable_until)
            @catalog.update_asset_status(tx, updated, now)
            relocate_future!(tx, updated, now) unless updated.allocatable? && !updated.operationally_blocked?
            @catalog.insert_asset_event(tx, "id" => @ids.uuid, "asset_id" => asset.id, "kind" => "status_changed", "from_status" => asset.status,
                                            "to_status" => status, "actor_id" => current.audit_actor_id,
                                            "notes" => Domain::Organizations::Text.optional(reason, max: 500), "occurred_at" => now)
            @audit.record(tx, current, "asset.status_changed", "asset", asset.id, "from" => asset.status, "to" => status)
            updated
          end
        end

        private

        def guard_operational!(tx, asset)
          flow = MANAGED[asset.status] || HOLDS[@catalog.operational_hold(tx, asset.id)]
          raise Domain::Conflict.new("situação controlada pela operação: #{flow}", code: "asset_in_operation") if flow
        end

        def relocate_future!(tx, asset, now)
          pending = @availability.future_reservation_allocations(tx, asset.id, now)
          pending.select! { |a| asset.unavailable_until.nil? || a["starts_at"] < asset.unavailable_until }
          unresolved = pending.reject do |allocation|
            context = { products: @allocator.products_for(tx, [allocation["product_id"]]) }
            rental = Domain::Period.new(allocation["rental_starts_at"], allocation["rental_ends_at"])
            @allocator.reassign(tx, context, allocation, asset.branch_id, rental, now)
          end
          return if unresolved.empty?

          codes = unresolved.map { |a| a["reservation_code"] }.uniq.join(", ")
          raise Domain::Conflict.new("ativo possui reservas sem unidade substituta: #{codes}", code: "asset_committed")
        end
      end

      # Bloqueio manual de ativo ou de unidades de estoque (preparação, manutenção programada).
      class BlockAvailability
        def initialize(uow:, catalog:, availability:, audit:, clock:, ids:)
          @uow = uow
          @catalog = catalog
          @availability = availability
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, period:, reason:, asset_id: nil, stock_pool_id: nil, quantity: nil)
          @uow.run(actor, "maintenance.write") do |tx, current|
            now = @clock.now
            base = { "id" => @ids.uuid, "organization_id" => tx.tenant_id!, "kind" => "block", "period" => period,
                     "reason" => Domain::Organizations::Text.required(reason, "motivo", max: 300), "created_by" => current.audit_actor_id, "created_at" => now }
            if asset_id
              asset = @catalog.find_asset(tx, Domain::Identifier.parse(asset_id)) || raise(Domain::NotFound, "ativo")
              begin
                tx.savepoint do
                  @availability.insert_asset_allocation(tx, base.merge("asset_id" => asset.id, "product_id" => asset.product_id))
                end
              rescue AllocationConflict
                raise Domain::Unavailable, [{ "asset_id" => asset.id, "tag" => asset.tag }]
              end
            else
              block_stock(tx, base, stock_pool_id, quantity, now)
            end
            @audit.record(tx, current, "availability.blocked", asset_id ? "asset" : "stock_pool", asset_id || stock_pool_id,
                          "period" => period.to_h, "reason" => base["reason"])
            base
          end
        end

        private

        def block_stock(tx, base, stock_pool_id, quantity, now)
          qty = Integer(quantity.to_s, 10)
          pool = @availability.lock_pool_by_id(tx, Domain::Identifier.parse(stock_pool_id, "estoque")) || raise(Domain::NotFound, "estoque")
          ledger = Domain::Availability::StockLedger.new(capacity: pool["total_quantity"],
                                                         occupancies: @availability.stock_occupancies(tx, pool["id"], base["period"], now))
          unless ledger.fits?(
            base["period"], qty
          )
            raise Domain::Unavailable,
                  [{ "stock_pool_id" => pool["id"], "available" => ledger.available(base["period"]) }]
          end

          @availability.insert_stock_allocation(tx,
                                                base.merge("stock_pool_id" => pool["id"], "product_id" => pool["product_id"],
                                                           "quantity" => qty))
        rescue ArgumentError
          raise Domain::ValidationError.field("quantidade", "número inteiro")
        end
      end

      class ListProducts
        def initialize(uow:, catalog:)
          @uow = uow
          @catalog = catalog
        end

        def call(actor, search: nil, tracking: nil, limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          @uow.run(actor, "catalog.read") do |tx, _|
            items, total = @catalog.search_products(tx, search: search.to_s.strip[0, 100], tracking: tracking, limit: lim, offset: off)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetProduct
        def initialize(uow:, catalog:)
          @uow = uow
          @catalog = catalog
        end

        def call(actor, product_id)
          @uow.run(actor, "catalog.read") do |tx, _|
            product = @catalog.find_product(tx, Domain::Identifier.parse(product_id)) || raise(Domain::NotFound, "produto")
            { product: product, components: @catalog.kit_components(tx, product.id), assets: @catalog.assets_for_product(tx, product.id),
              pools: @catalog.pools_for_product(tx, product.id) }
          end
        end
      end

      class GetAsset
        def initialize(uow:, catalog:, availability:)
          @uow = uow
          @catalog = catalog
          @availability = availability
        end

        def call(actor, asset_id)
          details(actor) { |tx| @catalog.find_asset(tx, Domain::Identifier.parse(asset_id)) }
        end

        # Ativo pelo patrimônio ou pelo identificador, com as mesmas permissões.
        def by_reference(actor, reference)
          text = reference.to_s.strip
          raise Domain::ValidationError.field("ativo", "informe o patrimônio ou o identificador") if text.empty?

          details(actor) { |tx| Domain::Identifier.valid?(text) ? @catalog.find_asset(tx, text.downcase) : @catalog.find_asset_by_tag(tx, text) }
        end

        private

        # `hold`: inspeção pendente ou ordem de manutenção ativa que controla a situação física.
        def details(actor)
          @uow.run(actor, "catalog.read") do |tx, _|
            asset = yield(tx) || raise(Domain::NotFound, "ativo")
            { asset: asset, product: @catalog.find_product(tx, asset.product_id), events: @catalog.asset_events(tx, asset.id),
              allocations: @availability.asset_allocations(tx, asset.id), hold: @catalog.operational_hold(tx, asset.id) }
          end
        end
      end
    end
  end
end
