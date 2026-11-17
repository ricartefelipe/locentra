# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/operations_support"
require_relative "../support/worker_support"

# Manutenção, transferências entre filiais, atrasos com alertas e isolamento entre organizações.
class MaintenanceTransferOverdueTest < DatabaseTest
  include OperationsSupport
  include WorkerHelpers

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-MT", tracking: "serialized")
    @chairs = create_product(@actor, sku: "CAD-MT", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 10)
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def test_maintenance_lifecycle_with_history_cost_and_inspection
    asset = register_assets(@actor, @camera, @branch, 1).first
    assert_raises(D::ValidationError) { uc(:open_maintenance_order).call(@actor, asset_id: asset.id, description: "x") }
    order = uc(:open_maintenance_order).call(@actor, asset_id: asset.id, description: "Limpeza do sensor")

    assert_equal %w[open in_maintenance], [order.status, asset_status(asset.id)]
    assert_equal 0, available(@camera)
    assert_raises(D::InvalidTransition) { uc(:complete_maintenance).call(@actor, order.id, cost: D::Money.new(100)) }
    uc(:start_maintenance).call(@actor, order.id)
    assert_raises(D::ValidationError) { uc(:complete_maintenance).call(@actor, order.id, cost: D::Money.new(-1)) }
    done = uc(:complete_maintenance).call(@actor, order.id, cost: D::Money.new(25_000), requires_inspection: true, notes: "sensor limpo")

    assert_equal [25_000, true], [done.cost.cents, done.requires_inspection]
    assert_equal "in_inspection", asset_status(asset.id)
    assert_equal 0, available(@camera)
    inspection = uc(:list_inspections).call(@actor).first

    assert_equal asset.id, inspection["asset_id"]
    uc(:approve_inspection).call(@actor, inspection["id"])

    assert_equal 1, available(@camera)
    kinds = owner_query("SELECT kind FROM asset_events WHERE asset_id = $1 ORDER BY occurred_at, kind", [asset.id]).map { |r| r["kind"] }

    assert_equal %w[inspection_approved maintenance_completed maintenance_opened maintenance_started registered].sort, kinds.sort
    assert_raises(D::ValidationError, "ordem encerrada é imutável") do
      @system.transactor.call(tenant_id: @org[:organization_id]) { |tx| tx.execute("UPDATE maintenance_orders SET description = 'alterada'") }
    end
    data = uc(:get_maintenance_order).call(@actor, order.id)

    assert_equal asset.tag, data[:labels]["tag"]
    assert_equal 3, data[:events].size
    assert_equal 1, uc(:list_maintenance_orders).call(@actor, filter: "closed").size
    assert_raises(D::ValidationError) { uc(:list_maintenance_orders).call(@actor, filter: "x") }
  end

  def test_manual_maintenance_relocates_or_refuses_future_reservations
    first, second = register_assets(@actor, @camera, @branch, 2)
    reservation = confirmed([line(@camera, 1)], after_rental)
    allocated = owner_query("SELECT asset_id FROM asset_allocations WHERE reservation_id = $1", [reservation.id]).first["asset_id"]
    uc(:open_maintenance_order).call(@actor, asset_id: allocated, description: "Revisão preventiva")
    other = [first.id, second.id].find { |id| id != allocated }

    assert_equal other, owner_query("SELECT asset_id FROM asset_allocations WHERE reservation_id = $1 AND active", [reservation.id]).first["asset_id"]
    error = assert_raises(D::Conflict) { uc(:open_maintenance_order).call(@actor, asset_id: other, description: "Revisão preventiva") }
    assert_equal "asset_committed", error.code
    assert_raises(D::InvalidTransition) { uc(:open_maintenance_order).call(@actor, asset_id: allocated, description: "Duplicada") }
  end

  def test_cancelled_maintenance_restores_previous_state
    asset = register_assets(@actor, @camera, @branch, 1).first
    order = uc(:open_maintenance_order).call(@actor, asset_id: asset.id, description: "Ajuste de foco")
    assert_raises(D::ValidationError) { uc(:cancel_maintenance).call(@actor, order.id, reason: "") }
    uc(:cancel_maintenance).call(@actor, order.id, reason: "aberta por engano")

    assert_equal "available", asset_status(asset.id)
    reservation = confirmed([line(@camera, 1)])
    pick_up(reservation)
    return_all(reservation, outcome: "damaged", notes: "foco desregulado")
    inspection = uc(:list_inspections).call(@actor).first
    rejected = uc(:reject_inspection).call(@actor, inspection["id"], notes: "foco desregulado")[:order]
    uc(:cancel_maintenance).call(@actor, rejected.id, reason: "reparo não necessário")

    assert_equal "in_inspection", asset_status(asset.id), "volta à inspeção de origem"
    assert_equal 1, uc(:list_inspections).call(@actor).size
    assert_raises(D::InvalidTransition) { uc(:start_maintenance).call(@actor, rejected.id) }
  end

  def test_stock_maintenance_blocks_units_without_uncovering_reservations
    confirmed([line(@chairs, 8)], after_rental)

    error = assert_raises(D::Unavailable) do
      uc(:open_maintenance_order).call(@actor, product_id: @chairs.id, branch_id: @branch.id, quantity: 3, description: "Reparo de assentos")
    end
    assert_equal 2, error.shortages.first["available"]
    assert_raises(D::ValidationError) do
      uc(:open_maintenance_order).call(@actor, product_id: @chairs.id, branch_id: @branch.id, quantity: "dois", description: "Reparo")
    end
    order = uc(:open_maintenance_order).call(@actor, product_id: @chairs.id, branch_id: @branch.id, quantity: 2, description: "Reparo de assentos")

    assert_equal 8, available(@chairs, rental_period)
    uc(:cancel_maintenance).call(@actor, order.id, reason: "fornecedor indisponível")

    assert_equal 10, available(@chairs, rental_period)
  end

  def test_asset_transfer_without_duplicity_between_branches
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    south = uc(:create_branch).call(@actor, name: "Filial Sul", code: "SUL")
    asset = register_assets(@actor, @camera, @branch, 1).first
    transfer = uc(:request_transfer).call(@actor, asset_id: asset.id, to_branch_id: north.id, notes: "reforço de frota")

    error = assert_raises(D::Conflict) { uc(:request_transfer).call(@actor, asset_id: asset.id, to_branch_id: south.id) }
    assert_equal "transfer_in_progress", error.code
    assert_raises(D::ValidationError) { uc(:request_transfer).call(@actor, asset_id: asset.id, to_branch_id: @branch.id) }
    uc(:dispatch_transfer).call(@actor, transfer.id)

    assert_equal "in_transit", asset_status(asset.id)
    assert_equal [0, 0, 0], [@branch, north, south].map { |b| available(@camera, branch: b) }, "em trânsito não aparece em nenhuma filial"
    assert_raises(D::InvalidTransition) { uc(:cancel_transfer).call(@actor, transfer.id, reason: "desistência") }
    assert_raises(D::InvalidTransition) { uc(:dispatch_transfer).call(@actor, transfer.id) }
    received = uc(:receive_transfer).call(@actor, transfer.id)

    assert_equal "received", received.status
    assert_equal([0, 1, 0], [@branch, north, south].map { |b| available(@camera, branch: b) })
    assert_equal north.id, owner_query("SELECT branch_id FROM assets WHERE id = $1", [asset.id]).first["branch_id"]
    assert_raises(D::InvalidTransition) { uc(:receive_transfer).call(@actor, transfer.id) }
    event = owner_query("SELECT from_branch_id, to_branch_id FROM asset_events WHERE kind = 'transfer_received'").first

    assert_equal [@branch.id, north.id], event.values
    assert_equal 1, uc(:list_transfers).call(@actor, filter: "closed").size
  end

  def test_transfer_requires_no_future_allocations_and_can_be_cancelled
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    asset = register_assets(@actor, @camera, @branch, 1).first
    reservation = confirmed([line(@camera, 1)], after_rental)
    transfer = uc(:request_transfer).call(@actor, asset_id: asset.id, to_branch_id: north.id)

    error = assert_raises(D::Conflict) { uc(:dispatch_transfer).call(@actor, transfer.id) }
    assert_equal "asset_committed", error.code
    assert_includes error.message, reservation.code
    cancelled = uc(:cancel_transfer).call(@actor, transfer.id, reason: "reserva futura na origem")

    assert_equal "cancelled", cancelled.status
    assert_equal "available", asset_status(asset.id)
    assert_raises(D::NotFound) { uc(:request_transfer).call(@actor, asset_id: asset.id, to_branch_id: SecureRandom.uuid) }
  end

  def test_database_refuses_reservation_allocation_on_asset_in_transit
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    moving, spare = register_assets(@actor, @camera, @branch, 2)
    uc(:dispatch_transfer).call(@actor, uc(:request_transfer).call(@actor, asset_id: moving.id, to_branch_id: north.id).id)
    reservation = confirmed([line(@camera, 1)], after_rental)
    allocation = owner_query("SELECT id, asset_id FROM asset_allocations WHERE reservation_id = $1", [reservation.id]).first

    assert_equal spare.id, allocation["asset_id"]
    assert_raises(A::AllocationConflict, "o gatilho recusa a troca para o ativo em trânsito") do
      @system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
        @system.repos[:availability].reassign_asset_allocation(tx, allocation["id"], moving.id)
      end
    end
    assert_equal spare.id, owner_query("SELECT asset_id FROM asset_allocations WHERE id = $1", [allocation["id"]]).first["asset_id"]
  end

  def test_stock_transfer_moves_quantities_respecting_future_coverage
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    confirmed([line(@chairs, 6)], after_rental)

    assert_raises(D::ValidationError) do
      uc(:request_transfer).call(@actor, product_id: @chairs.id, from_branch_id: @branch.id, to_branch_id: north.id, quantity: 11)
    end
    assert_raises(D::ValidationError) do
      uc(:request_transfer).call(@actor, product_id: @chairs.id, from_branch_id: @branch.id, to_branch_id: north.id, quantity: "x")
    end
    assert_raises(D::NotFound) { uc(:request_transfer).call(@actor, product_id: @chairs.id, from_branch_id: north.id, to_branch_id: @branch.id, quantity: 1) }
    too_many = uc(:request_transfer).call(@actor, product_id: @chairs.id, from_branch_id: @branch.id, to_branch_id: north.id, quantity: 5)
    error = assert_raises(D::Conflict) { uc(:dispatch_transfer).call(@actor, too_many.id) }
    assert_equal "stock_committed", error.code
    uc(:cancel_transfer).call(@actor, too_many.id, reason: "quantidade excessiva")
    transfer = uc(:request_transfer).call(@actor, product_id: @chairs.id, from_branch_id: @branch.id, to_branch_id: north.id, quantity: 4)
    uc(:dispatch_transfer).call(@actor, transfer.id)

    assert_equal [0, 0], [available(@chairs, rental_period, branch: north), 6 - available(@chairs, rental_period)]
    uc(:receive_transfer).call(@actor, transfer.id)

    assert_equal [4, 6], [available(@chairs, rental_period, branch: north), available(@chairs, rental_period)]
    movements = owner_query("SELECT kind, quantity_delta FROM stock_movements WHERE reference_id = $1 ORDER BY quantity_delta", [transfer.id])

    assert_equal [%w[transfer_out -4], %w[transfer_in 4]], movements.map(&:values)
  end

  # Reserva em atraso com um ativo e 6 cadeiras; reservas futuras usam o mesmo ativo e 6 cadeiras.
  def overdue_scenario
    asset = register_assets(@actor, @camera, @branch, 1).first
    late = confirmed([line(@camera, 1), line(@chairs, 6)])
    other = create_customer(@actor, name: "Cliente Futuro", document: "11144477735")
    future = confirmed([line(@camera, 1)], after_rental, customer: other)
    stock_future = confirmed([line(@chairs, 6)], after_rental, customer: other)
    pick_up(late)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    { asset: asset, late: late, future: future, stock_future: stock_future }
  end

  def test_overdue_creates_unique_alerts_identifies_affected_reservations_and_emails_once
    s = overdue_scenario

    assert_equal [s[:late].id], uc(:detect_overdue).call(system_actor)
    assert_equal [s[:late].id], uc(:detect_overdue).call(system_actor), "execuções repetidas não duplicam alertas"
    alerts = owner_query("SELECT kind, reservation_id, related_reservation_id, asset_id, stock_pool_id FROM reservation_alerts ORDER BY kind, reservation_id")

    assert_equal(%w[affected_by_overdue affected_by_overdue overdue], alerts.map { |a| a["kind"] })
    affected = alerts.select { |a| a["kind"] == "affected_by_overdue" }

    assert_equal [s[:future].id, s[:stock_future].id].sort, affected.map { |a| a["reservation_id"] }.sort
    assert(affected.all? { |a| a["related_reservation_id"] == s[:late].id })
    assert_equal s[:asset].id, affected.find { |a| a["reservation_id"] == s[:future].id }["asset_id"]
    since = owner_query("SELECT overdue_since FROM reservations WHERE id = $1", [s[:late].id]).first["overdue_since"]

    assert_equal rental_period.ends_at, Time.parse(since)
    assert_equal 1, count("SELECT count(*) FROM jobs WHERE kind = 'email.send' AND payload->>'template' = 'late_return'")
    assert_equal %w[confirmed confirmed], [reservation_status(s[:future]), reservation_status(s[:stock_future])], "nada é cancelado automaticamente"
    board = uc(:operations_board).call(@actor)

    assert_equal([s[:late].id], board[:overdue].map { |r| r["id"] })
    assert_equal 3, board[:alerts].size
  end

  def test_alert_resolution_is_recorded_and_return_resolves_related_alerts
    s = overdue_scenario
    uc(:detect_overdue).call(system_actor)
    overdue_alert = uc(:operations_board).call(@actor)[:alerts].find { |a| a["kind"] == "overdue" }

    assert_raises(D::ValidationError) { uc(:resolve_alert).call(@actor, overdue_alert["id"], resolution: "") }
    resolved = uc(:resolve_alert).call(@actor, overdue_alert["id"], resolution: "Cliente avisado; devolução amanhã às 9h")

    assert_equal "resolved", resolved.status
    assert_raises(D::InvalidTransition) { uc(:resolve_alert).call(@actor, overdue_alert["id"], resolution: "outra decisão") }
    uc(:detect_overdue).call(system_actor)

    assert_equal 1, count("SELECT count(*) FROM reservation_alerts WHERE kind = 'overdue'"), "alerta resolvido não é recriado"
    assert_equal "Cliente avisado; devolução amanhã às 9h", owner_query("SELECT resolution FROM reservation_alerts WHERE kind = 'overdue'").first["resolution"]
    return_all(s[:late])

    assert_equal 0, count("SELECT count(*) FROM reservation_alerts WHERE status = 'open'"), "devolução resolve os alertas relacionados"
    assert_empty uc(:detect_overdue).call(system_actor)
  end

  def test_extension_clears_overdue_and_resolves_alerts
    reservation = confirmed([line(@chairs, 2)])
    pick_up(reservation)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-05T12:00:00Z"))

    assert_empty uc(:detect_overdue).call(system_actor)
    assert_nil owner_query("SELECT overdue_since FROM reservations WHERE id = $1", [reservation.id]).first["overdue_since"]
    assert_equal "Prazo de devolução estendido", owner_query("SELECT resolution FROM reservation_alerts").first["resolution"]
  end

  def test_worker_tick_detects_overdue_and_sends_late_return_email
    reservation = confirmed([line(@chairs, 2)])
    pick_up(reservation)
    worker_system
    drain
    @mailer.deliveries.clear
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      worker_system.queue.enqueue(tx, "organization.tick", { "bucket" => "teste" })
    end
    drain
    drain

    late = @mailer.deliveries.select { |d| d[:subject].include?("atraso") }

    assert_equal 1, late.size
    assert_includes late.first[:subject], reservation.code
    assert_includes late.first[:text], "04/03/2026 06:00"
  end

  def test_operations_resources_are_isolated_between_organizations
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    asset = register_assets(@actor, @camera, @branch, 1).first
    reservation = confirmed([line(@camera, 1)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    stranger = other[:actor]

    assert_raises(D::NotFound) { uc(:start_pickup).call(stranger, reservation.id) }
    assert_raises(D::NotFound) { uc(:get_pickup).call(stranger, pickup.id) }
    assert_raises(D::NotFound) { uc(:deliver_pickup).call(stranger, pickup.id, picker: { kind: "customer" }) }
    assert_raises(D::NotFound) { uc(:register_return).call(stranger, reservation.id, entries: [{ pickup_line_id: SecureRandom.uuid, outcome: "ok" }]) }
    assert_raises(D::NotFound) { uc(:open_maintenance_order).call(stranger, asset_id: asset.id, description: "Invasão") }
    assert_raises(D::NotFound) { uc(:request_transfer).call(stranger, asset_id: asset.id, to_branch_id: other[:branch].id) }
    uc(:check_pickup).call(@actor, pickup.id, check_entries(@actor, pickup))
    uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })
    return_all(reservation, outcome: "damaged", notes: "lente trincada")
    inspection = uc(:list_inspections).call(@actor).first
    report = uc(:list_damage_reports).call(@actor).first

    assert_raises(D::NotFound) { uc(:approve_inspection).call(stranger, inspection["id"]) }
    assert_raises(D::NotFound) { uc(:get_damage_report).call(stranger, report["id"]) }
    assert_raises(D::NotFound) { uc(:approve_damage_charge).call(stranger, report["id"]) }
    assert_empty uc(:list_inspections).call(stranger)
    assert_empty uc(:operations_board).call(stranger)[:alerts]
    tables = %w[pickups pickup_lines returns return_lines maintenance_orders inspections damage_reports transfers reservation_alerts]
    rls = owner_query("SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = ANY($1::text[])", ["{#{tables.join(",")}}"])

    assert_equal tables.sort, rls.map { |r| r["relname"] }.sort
    assert(rls.all? { |r| r["relrowsecurity"] == "t" && r["relforcerowsecurity"] == "t" })
    visible = @system.transactor.call(tenant_id: other[:organization_id]) { |tx| tx.query_value("SELECT count(*) FROM pickups") }

    assert_equal 0, visible
  end

  def test_operations_require_permissions
    auditor = member("auditor@alfa.test", "auditor")
    reservation = confirmed([line(@chairs, 1)])

    assert_raises(D::AccessDenied) { uc(:start_pickup).call(auditor, reservation.id) }
    assert_raises(D::AccessDenied) { uc(:open_maintenance_order).call(auditor, product_id: @chairs.id, branch_id: @branch.id, quantity: 1, description: "Sem acesso") }
    assert_raises(D::AccessDenied) { uc(:request_transfer).call(auditor, product_id: @chairs.id, from_branch_id: @branch.id, to_branch_id: @branch.id, quantity: 1) }
    assert_kind_of Hash, uc(:operations_board).call(auditor), "leitura do painel liberada a todos os papéis"
  end

  private

  def member(email, role)
    invite = uc(:invite_member).call(@actor, email: email, role: role)
    token = "#{@org[:organization_id]}.convite-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    joined = uc(:accept_invitation).call(token: token, name: "Membro #{role}", password: "senha-muito-segura-7")
    A::Actor.user(user_id: joined[:user_id], organization_id: @org[:organization_id], role: role)
  end
end
