# frozen_string_literal: true

module Locentra
  module Application
    # Serviços compartilhados pela operação: retirada, devolução, inspeção, manutenção e transferência.
    # Todos recebem a transação aberta pelo caso de uso chamador.
    module Operations
      # Horizonte usado para verificar cobertura de reservas futuras de estoque.
      HORIZON_SECONDS = 366 * 86_400

      def self.horizon(now) = Domain::Period.new(now, now + HORIZON_SECONDS)

      # Mudança de situação do ativo com histórico em asset_events.
      class AssetLedger
        def initialize(catalog:, ids:)
          @catalog = catalog
          @ids = ids
        end

        def move(tx, actor, asset, target, kind:, now:, reference_type:, reference_id:, notes: nil, branch_id: nil)
          updated = asset.transition_to(target)
          updated = updated.with(branch_id: branch_id) if branch_id
          @catalog.update_asset_status(tx, updated, now)
          record(tx, actor, asset, kind: kind, now: now, reference_type: reference_type, reference_id: reference_id, notes: notes,
                                   to_status: target, to_branch_id: updated.branch_id)
          updated
        end

        # Evento sem mudança de situação (por exemplo, início de manutenção).
        def note(tx, actor, asset, kind:, now:, reference_type:, reference_id:, notes: nil)
          record(tx, actor, asset, kind: kind, now: now, reference_type: reference_type, reference_id: reference_id, notes: notes,
                                   to_status: asset.status, to_branch_id: asset.branch_id)
        end

        private

        def record(tx, actor, asset, kind:, now:, reference_type:, reference_id:, notes:, to_status:, to_branch_id:)
          @catalog.insert_asset_event(tx, "id" => @ids.uuid, "asset_id" => asset.id, "kind" => kind, "from_status" => asset.status,
                                          "to_status" => to_status, "from_branch_id" => asset.branch_id, "to_branch_id" => to_branch_id,
                                          "actor_id" => actor&.audit_actor_id, "reference_type" => reference_type, "reference_id" => reference_id,
                                          "notes" => Domain::Organizations::Text.optional(notes, max: 500), "occurred_at" => now)
        end
      end

      # Alertas deduplicados pela chave da situação.
      class AlertBook
        def initialize(alerts:, clock:, ids:)
          @alerts = alerts
          @clock = clock
          @ids = ids
        end

        # Retorna verdadeiro quando o alerta foi criado agora.
        def raise_alert(tx, reservation_id:, kind:, key:, related_reservation_id: nil, asset_id: nil, stock_pool_id: nil, details: {})
          @alerts.insert(tx, "id" => @ids.uuid, "reservation_id" => reservation_id, "kind" => kind, "related_reservation_id" => related_reservation_id,
                             "asset_id" => asset_id, "stock_pool_id" => stock_pool_id, "dedup_key" => key, "details" => details,
                             "created_at" => @clock.now)
        end

        # Reservas futuras que perderam o item: alerta "item indisponível" para decisão da equipe.
        def unavailable(tx, reservation_ids, resource_id:, source_id:, details:, related_reservation_id: nil, asset_id: nil, stock_pool_id: nil)
          reservation_ids.each do |reservation_id|
            raise_alert(tx, reservation_id: reservation_id, kind: "asset_unavailable",
                            key: Domain::Alerts::Keys.unavailable(reservation_id, resource_id, source_id),
                            related_reservation_id: related_reservation_id, asset_id: asset_id, stock_pool_id: stock_pool_id, details: details)
          end
        end
      end

      # Reservas futuras de um ativo que deixou de estar disponível são realocadas para outra unidade
      # livre; as que não têm substituto são devolvidas ao chamador (que recusa ou alerta).
      class AssetRelocation
        def initialize(availability:, allocator:)
          @availability = availability
          @allocator = allocator
        end

        def relocate(tx, asset, now)
          @availability.future_reservation_allocations(tx, asset.id, now).reject do |allocation|
            context = { products: @allocator.products_for(tx, [allocation["product_id"]]) }
            rental = Domain::Period.new(allocation["rental_starts_at"], allocation["rental_ends_at"])
            @allocator.reassign(tx, context, allocation, asset.branch_id, rental, now)
          end
        end
      end

      # Reservas futuras (bloqueio temporário válido ou confirmadas) cuja ocupação de estoque ultrapassa
      # a capacidade efetiva em algum trecho do horizonte.
      class StockCoverage
        FUTURE = %w[held confirmed].freeze

        def initialize(allocations:)
          @allocations = allocations
        end

        def affected(tx, pool_id, capacity, now, outstanding: 0, exclude: [])
          window = Operations.horizon(now)
          occupancies = @allocations.pool_occupancies(tx, pool_id, window, now).reject { |o| exclude.include?(o[:reservation_id]) }
          statuses = occupancies.to_h { |o| [o[:reservation_id], o[:reservation_status]] }
          Domain::Alerts::StockShortfall.affected(capacity: capacity, outstanding: outstanding, occupancies: occupancies, window: window)
                                        .select { |id| FUTURE.include?(statuses[id]) }
        end
      end

      # Abertura de ordens de manutenção e de inspeções, e bloqueios de estoque associados.
      class MaintenanceDesk
        M = Domain::Maintenance

        def initialize(orders:, inspections:, allocations:, organizations:, ids:)
          @orders = orders
          @inspections = inspections
          @allocations = allocations
          @organizations = organizations
          @ids = ids
        end

        def open_order(tx, actor, product_id:, branch_id:, description:, now:, asset_id: nil, pool_id: nil, quantity: 1,
                       block_allocation_id: nil, inspection_id: nil, previous_status: nil)
          order = M::Order.build(id: @ids.uuid, organization_id: tx.tenant_id!, code: @organizations.next_code(tx, "maintenance_order", "OM"),
                                 product_id: product_id, branch_id: branch_id, description: description, opened_at: now, asset_id: asset_id,
                                 stock_pool_id: pool_id, quantity: quantity, block_allocation_id: block_allocation_id,
                                 inspection_id: inspection_id, previous_status: previous_status)
          @orders.insert(tx, order, actor&.audit_actor_id)
          @allocations.rename_block(tx, block_allocation_id, "Manutenção #{order.code}") if block_allocation_id
          order
        end

        def open_inspection(tx, product_id:, branch_id:, reason:, now:, asset_id: nil, pool_id: nil, quantity: 1, block_allocation_id: nil,
                            reservation_id: nil, return_line_id: nil, source_order_id: nil)
          inspection = M::Inspection.build(id: @ids.uuid, organization_id: tx.tenant_id!, product_id: product_id, branch_id: branch_id,
                                           reason: reason, created_at: now, asset_id: asset_id, stock_pool_id: pool_id, quantity: quantity,
                                           block_allocation_id: block_allocation_id, reservation_id: reservation_id,
                                           return_line_id: return_line_id, source_maintenance_order_id: source_order_id)
          @inspections.insert(tx, inspection)
          @allocations.rename_block(tx, block_allocation_id, "Inspeção: #{inspection.reason}"[0, 300]) if block_allocation_id
          inspection
        end

        # Bloqueio [now, ∞) de unidades de estoque, encerrado somente na liberação.
        def block_stock(tx, actor, pool, quantity, reason, now)
          id = @ids.uuid
          @allocations.insert_open_stock_block(tx, "id" => id, "stock_pool_id" => pool.id, "product_id" => pool.product_id, "reason" => reason,
                                                   "quantity" => quantity, "starts_at" => now, "created_by" => actor&.audit_actor_id,
                                                   "created_at" => now)
          id
        end
      end
    end
  end
end
