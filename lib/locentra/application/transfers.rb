# frozen_string_literal: true

module Locentra
  module Application
    # Transferências entre filiais. O ativo em trânsito fica indisponível em todas as filiais e só
    # muda de filial no recebimento; estoque sai da origem na saída e entra no destino no recebimento.
    module Transfers
      T = Domain::Transfers

      class RequestTransfer
        def initialize(uow:, transfers:, catalog:, allocations:, organizations:, audit:, clock:, ids:)
          @uow = uow
          @transfers = transfers
          @catalog = catalog
          @allocations = allocations
          @organizations = organizations
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # Ativo por identificador ou pelo patrimônio lido; estoque por produto, filial de origem e quantidade.
        def call(actor, to_branch_id:, asset_id: nil, asset_tag: nil, product_id: nil, from_branch_id: nil, quantity: nil, notes: nil)
          @uow.run(actor, "assets.write") do |tx, current|
            # A filial de destino precisa estar ativa (trava compartilhada contra a desativação); a origem, não.
            destination = Organizations::BranchGuard.active!(@organizations, tx, to_branch_id, field: "destino").id

            asset = target_asset(tx, asset_id, asset_tag)
            source = asset ? for_asset(asset) : for_stock(tx, product_id, from_branch_id, quantity)
            # O código sequencial é obtido por último: o lock do contador dura só até o commit.
            transfer = T::Transfer.build(**source, id: @ids.uuid, organization_id: tx.tenant_id!, to_branch_id: destination,
                                                   requested_at: @clock.now, notes: notes, code: @organizations.next_code(tx, "transfer", "TR"))
            @transfers.insert(tx, transfer, current.audit_actor_id)
            @audit.record(tx, current, "transfer.requested", "transfer", transfer.id, "code" => transfer.code, "asset_id" => transfer.asset_id,
                                                                                      "quantity" => transfer.quantity, "to_branch_id" => destination)
            transfer
          end
        end

        private

        def target_asset(tx, asset_id, asset_tag)
          found = if !asset_id.to_s.empty? then @catalog.find_asset(tx, Domain::Identifier.parse(asset_id, "ativo"))
                  elsif !asset_tag.to_s.strip.empty? then @catalog.find_asset_by_tag(tx, asset_tag.to_s.strip)
                  else return nil
                  end
          found || raise(Domain::NotFound, "ativo")
        end

        def for_asset(asset)
          raise Domain::InvalidTransition.new("ativo", asset.status, "in_transit") unless asset.can_transition_to?("in_transit")

          { product_id: asset.product_id, asset_id: asset.id, from_branch_id: asset.branch_id }
        end

        def for_stock(tx, product_id, from_branch_id, quantity)
          qty = integer!(quantity)
          pool = @allocations.find_pool(tx, Domain::Identifier.parse(product_id, "produto"), Domain::Identifier.parse(from_branch_id, "origem"))
          raise Domain::NotFound, "estoque de origem" unless pool
          raise Domain::ValidationError.field("quantidade", "acima do estoque da origem (#{pool.total_quantity})") if qty > pool.total_quantity

          { product_id: pool.product_id, from_pool_id: pool.id, from_branch_id: pool.branch_id, quantity: qty }
        end

        def integer!(value)
          Integer(value.to_s.strip, 10)
        rescue ArgumentError
          raise Domain::ValidationError.field("quantidade", "número inteiro")
        end
      end

      # Carrega a transferência com lock (ordem única: transferência, depois ativo ou estoque).
      module TransferLocking
        private

        def lock_transfer!(tx, transfer_id)
          @transfers.lock(tx, Domain::Identifier.parse(transfer_id)) || raise(Domain::NotFound, "transferência")
        end
      end

      # Saída: exige que o ativo não tenha alocações futuras ativas na origem; o estoque sai da
      # origem respeitando a cobertura das reservas futuras.
      class DispatchTransfer
        include TransferLocking

        def initialize(uow:, transfers:, catalog:, allocations:, availability:, ledger:, audit:, clock:, ids:)
          @uow = uow
          @transfers = transfers
          @catalog = catalog
          @allocations = allocations
          @availability = availability
          @ledger = ledger
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, transfer_id)
          @uow.run(actor, "assets.write") do |tx, current|
            transfer = lock_transfer!(tx, transfer_id)
            now = @clock.now
            dispatched = transfer.dispatch(now)
            transfer.asset? ? ship_asset(tx, current, transfer, now) : ship_stock(tx, current, transfer, now)
            @transfers.update(tx, dispatched, current.audit_actor_id)
            @audit.record(tx, current, "transfer.dispatched", "transfer", transfer.id, "code" => transfer.code)
            dispatched
          end
        end

        private

        def ship_asset(tx, current, transfer, now)
          asset = @catalog.lock_asset(tx, transfer.asset_id)
          raise Domain::Conflict.new("o ativo mudou de filial após a solicitação", code: "asset_moved") unless asset.branch_id == transfer.from_branch_id

          future = @allocations.active_future_allocations(tx, asset.id, now)
          unless future.empty?
            raise Domain::Conflict.new("o ativo possui alocações futuras na origem: #{future.map { |a| a["label"] }.uniq.join(", ")}",
                                       code: "asset_committed")
          end

          @ledger.move(tx, current, asset, "in_transit", kind: "transfer_dispatched", now: now, reference_type: "transfer",
                                                         reference_id: transfer.id, notes: "Saída da transferência #{transfer.code}")
        end

        def ship_stock(tx, current, transfer, now)
          pool = @allocations.lock_pool(tx, transfer.from_pool_id)
          updated = pool.adjust(-transfer.quantity)
          window = Operations.horizon(now)
          peak = Domain::Availability::Peak.within(window, @availability.stock_occupancies(tx, pool.id, window, now))
          if peak > updated.total_quantity
            raise Domain::Conflict.new("a saída deixaria reservas futuras sem cobertura na origem (pico reservado: #{peak})",
                                       code: "stock_committed")
          end

          @catalog.update_pool_total(tx, updated, now)
          @catalog.insert_stock_movement(tx, "id" => @ids.uuid, "stock_pool_id" => pool.id, "kind" => "transfer_out",
                                             "quantity_delta" => -transfer.quantity, "reason" => "Transferência #{transfer.code}",
                                             "actor_id" => current.audit_actor_id, "reference_type" => "transfer", "reference_id" => transfer.id,
                                             "occurred_at" => now)
        end
      end

      class ReceiveTransfer
        include TransferLocking

        def initialize(uow:, transfers:, catalog:, ledger:, audit:, clock:, ids:)
          @uow = uow
          @transfers = transfers
          @catalog = catalog
          @ledger = ledger
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, transfer_id)
          @uow.run(actor, "assets.write") do |tx, current|
            transfer = lock_transfer!(tx, transfer_id)
            now = @clock.now
            received = transfer.receive(now)
            received = transfer.asset? ? receive_asset(tx, current, received, now) : receive_stock(tx, current, received, now)
            @transfers.update(tx, received, current.audit_actor_id)
            @audit.record(tx, current, "transfer.received", "transfer", transfer.id, "code" => transfer.code)
            received
          end
        end

        private

        def receive_asset(tx, current, transfer, now)
          asset = @catalog.lock_asset(tx, transfer.asset_id)
          @ledger.move(tx, current, asset, "available", kind: "transfer_received", now: now, reference_type: "transfer", reference_id: transfer.id,
                                                        branch_id: transfer.to_branch_id, notes: "Recebimento da transferência #{transfer.code}")
          transfer
        end

        def receive_stock(tx, current, transfer, now)
          pool = @catalog.lock_or_create_pool(tx, @ids.uuid, transfer.product_id, transfer.to_branch_id, now)
          @catalog.update_pool_total(tx, pool.adjust(transfer.quantity), now)
          @catalog.insert_stock_movement(tx, "id" => @ids.uuid, "stock_pool_id" => pool.id, "kind" => "transfer_in", "quantity_delta" => transfer.quantity,
                                             "reason" => "Transferência #{transfer.code}", "actor_id" => current.audit_actor_id,
                                             "reference_type" => "transfer", "reference_id" => transfer.id, "occurred_at" => now)
          transfer.with(to_pool_id: pool.id)
        end
      end

      class CancelTransfer
        include TransferLocking

        def initialize(uow:, transfers:, audit:, clock:)
          @uow = uow
          @transfers = transfers
          @audit = audit
          @clock = clock
        end

        def call(actor, transfer_id, reason:)
          @uow.run(actor, "assets.write") do |tx, current|
            transfer = lock_transfer!(tx, transfer_id)
            cancelled = transfer.cancel(reason, @clock.now)
            @transfers.update(tx, cancelled, current.audit_actor_id)
            @audit.record(tx, current, "transfer.cancelled", "transfer", transfer.id, "code" => transfer.code, "reason" => cancelled.cancellation_reason)
            cancelled
          end
        end
      end

      class ListTransfers
        FILTERS = %w[active closed all].freeze

        def initialize(uow:, transfers:)
          @uow = uow
          @transfers = transfers
        end

        def call(actor, filter: "active")
          raise Domain::ValidationError.field("situacao", "inválida") unless FILTERS.include?(filter)

          @uow.run(actor, "catalog.read") { |tx, _| @transfers.list(tx, filter: filter) }
        end
      end
    end
  end
end
