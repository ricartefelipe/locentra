# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"
require_relative "../support/operations_support"

# Retiradas, devoluções, transferências e cobranças disputadas por transações em conexões separadas,
# sincronizadas por barreiras (sem espera por tempo).
class FulfillmentRaceTest < DatabaseTest
  include OperationsSupport

  OPS = Locentra::Application::Operations

  # Repositório de reservas sem lock de linha: simula um caminho que não bloqueia a reserva, para
  # verificar que as constraints do banco impedem a duplicidade mesmo assim.
  class UnlockedReservations
    def initialize(target) = @target = target
    def lock(tx, id) = @target.find(tx, id)
    def method_missing(name, ...) = @target.public_send(name, ...)
    def respond_to_missing?(name, include_private = false) = @target.respond_to?(name, include_private)
  end

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-RACE", tracking: "serialized")
    @cameras = register_assets(@actor, @camera, @branch, 2)
    @chairs = create_product(@actor, sku: "CAD-RACE", tracking: "bulk")
    stock(@actor, @chairs, @branch, 10)
  end

  def repo(name) = @system.repos[name]
  def ledger = OPS::AssetLedger.new(catalog: repo(:catalog), ids: @system.ids)

  def start_use_case(reservations)
    A::Fulfillment::StartPickup.new(uow: @system.uow, reservations: reservations, fulfillment: repo(:fulfillment), audit: @system.services[:audit],
                                    clock: @clock, ids: @system.ids)
  end

  def deliver_use_case(reservations)
    A::Fulfillment::DeliverPickup.new(uow: @system.uow, reservations: reservations, fulfillment: repo(:fulfillment),
                                      allocations: repo(:operational_allocations), customers: repo(:customers), catalog: repo(:catalog),
                                      ledger: ledger, audit: @system.services[:audit], events: @system.services[:events], clock: @clock)
  end

  def return_use_case(reservations)
    allocations = repo(:operational_allocations)
    A::Returns::RegisterReturn.new(
      uow: @system.uow, reservations: reservations, fulfillment: repo(:fulfillment), allocations: allocations, availability: repo(:availability),
      catalog: repo(:catalog), organizations: repo(:organizations),
      desk: OPS::MaintenanceDesk.new(orders: repo(:maintenance_orders), inspections: repo(:inspections), allocations: allocations,
                                     organizations: repo(:organizations), ids: @system.ids),
      damage_reports: repo(:damage_reports), ledger: ledger,
      relocation: OPS::AssetRelocation.new(availability: repo(:availability), allocator: @system.services[:allocator]),
      coverage: OPS::StockCoverage.new(allocations: allocations),
      alert_book: OPS::AlertBook.new(alerts: repo(:alerts), clock: @clock, ids: @system.ids), alerts: repo(:alerts),
      audit: @system.services[:audit], events: @system.services[:events], clock: @clock, ids: @system.ids
    )
  end

  # Executa os blocos em threads simultâneas e devolve [:ok, valor] ou [:erro, exceção] de cada uma.
  def race(*blocks)
    blocks.map do |block|
      Thread.new do
        [:ok, block.call]
      rescue D::Error => e
        [:error, e]
      end
    end.map(&:value)
  end

  def outcomes(results) = results.map(&:first).sort

  def checked_pickup(reservation)
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    uc(:check_pickup).call(@actor, pickup.id, check_entries(@actor, pickup))
    pickup
  end

  def test_concurrent_deliveries_of_the_same_pickup_hand_over_once
    reservation = confirmed([line(@camera, 1)])
    pickup = checked_pickup(reservation)
    barrier = Barrier.new(2)
    use_case = deliver_use_case(PausingProxy.new(repo(:reservations), :lock, barrier))

    results = race(-> { use_case.call(@actor, pickup.id, picker: { kind: "customer" }) },
                   -> { use_case.call(@actor, pickup.id, picker: { kind: "customer" }) })

    assert_equal %i[error ok], outcomes(results)
    error = results.find { |r| r.first == :error }.last

    assert_kind_of D::Conflict, error
    assert_equal "already_picked_up", error.code
    assert_equal 1, count("SELECT count(*) FROM asset_events WHERE kind = 'checked_out'")
    assert_equal 1, count("SELECT count(*) FROM outbox_events WHERE event_type = 'reservation.picked_up'")
    assert_equal "in_progress", reservation_status(reservation)
  end

  def test_concurrent_separation_creates_a_single_pickup
    reservation = confirmed([line(@camera, 1), line(@chairs, 3)])
    barrier = Barrier.new(2)
    use_case = start_use_case(PausingProxy.new(repo(:reservations), :lock, barrier))

    results = race(-> { use_case.call(@actor, reservation.id).id }, -> { use_case.call(@actor, reservation.id).id })

    assert_equal %i[ok ok], outcomes(results)
    assert_equal 1, results.map(&:last).uniq.size, "a segunda separação devolve a retirada em andamento"
    assert_equal 1, count("SELECT count(*) FROM pickups")
    assert_equal 2, count("SELECT count(*) FROM pickup_lines")
  end

  def test_unique_indexes_block_duplicate_pickup_even_without_reservation_lock
    reservation = confirmed([line(@camera, 1)])
    barrier = Barrier.new(2)
    fulfillment = PausingProxy.new(repo(:fulfillment), :open_pickup_for, barrier, after: true)
    use_case = A::Fulfillment::StartPickup.new(uow: @system.uow, reservations: UnlockedReservations.new(repo(:reservations)),
                                               fulfillment: fulfillment, audit: @system.services[:audit], clock: @clock, ids: @system.ids)

    results = race(-> { use_case.call(@actor, reservation.id) }, -> { use_case.call(@actor, reservation.id) })

    assert_equal %i[error ok], outcomes(results)
    assert_kind_of D::Conflict, results.find { |r| r.first == :error }.last
    assert_equal 1, count("SELECT count(*) FROM pickups")
  end

  def test_concurrent_returns_of_the_same_asset_register_once
    reservation = confirmed([line(@camera, 2)])
    pick_up(reservation)
    target = pending_lines(reservation).first
    barrier = Barrier.new(2)
    use_case = return_use_case(PausingProxy.new(repo(:reservations), :lock, barrier))
    entries = [{ pickup_line_id: target["id"], outcome: "ok" }]

    results = race(-> { use_case.call(@actor, reservation.id, entries: entries) }, -> { use_case.call(@actor, reservation.id, entries: entries) })

    assert_equal %i[error ok], outcomes(results)
    assert_equal "already_returned", results.find { |r| r.first == :error }.last.code
    assert_equal 1, count("SELECT count(*) FROM return_lines")
    assert_equal 1, count("SELECT returned_quantity FROM pickup_lines WHERE id = $1", [target["id"]])
    assert_equal 1, count("SELECT count(*) FROM asset_events WHERE kind = 'returned'")
    assert_equal "in_progress", reservation_status(reservation)
  end

  def test_concurrent_stock_returns_never_exceed_delivered_quantity
    reservation = confirmed([line(@chairs, 5)])
    pick_up(reservation)
    target = pending_lines(reservation).first
    barrier = Barrier.new(2)
    use_case = return_use_case(PausingProxy.new(repo(:reservations), :lock, barrier))
    ok = [{ pickup_line_id: target["id"], outcome: "ok", quantity: 3 }]
    missing = [{ pickup_line_id: target["id"], outcome: "missing", quantity: 3, notes: "não devolvidas" }]

    results = race(-> { use_case.call(@actor, reservation.id, entries: ok) }, -> { use_case.call(@actor, reservation.id, entries: missing) })

    assert_equal %i[error ok], outcomes(results)
    line = owner_query("SELECT returned_quantity, missing_quantity, delivered_quantity FROM pickup_lines WHERE id = $1", [target["id"]]).first

    assert_equal 3, line["returned_quantity"].to_i + line["missing_quantity"].to_i
    assert_operator line["returned_quantity"].to_i + line["missing_quantity"].to_i, :<=, line["delivered_quantity"].to_i
    assert_equal 1, count("SELECT count(*) FROM returns")
  end

  def test_concurrent_transfer_requests_for_the_same_asset_keep_a_single_destination
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    south = uc(:create_branch).call(@actor, name: "Filial Sul", code: "SUL")
    asset = @cameras.first
    barrier = Barrier.new(2)
    use_case = A::Transfers::RequestTransfer.new(uow: @system.uow, transfers: repo(:transfers),
                                                 catalog: PausingProxy.new(repo(:catalog), :find_asset, barrier, after: true),
                                                 allocations: repo(:operational_allocations), organizations: repo(:organizations),
                                                 audit: @system.services[:audit], clock: @clock, ids: @system.ids)

    results = race(-> { use_case.call(@actor, asset_id: asset.id, to_branch_id: north.id) },
                   -> { use_case.call(@actor, asset_id: asset.id, to_branch_id: south.id) })

    assert_equal %i[error ok], outcomes(results)
    assert_equal "transfer_in_progress", results.find { |r| r.first == :error }.last.code
    assert_equal 1, count("SELECT count(*) FROM transfers WHERE asset_id = $1 AND status = 'requested'", [asset.id])
  end

  def test_concurrent_charge_approvals_record_a_single_adjustment
    reservation = confirmed([line(@camera, 1)])
    pick_up(reservation)
    return_all(reservation, outcome: "damaged", notes: "visor quebrado")
    report = uc(:list_damage_reports).call(@actor).first
    uc(:revise_damage_report).call(@actor, report["id"], description: "visor quebrado", severity: "severe", estimated_cost: D::Money.new(9_000))
    uc(:upload_attachment).call(@actor, owner_type: "damage_report", owner_id: report["id"], filename: "visor.pdf", bytes: "%PDF-1.4\n%visor\n")
    barrier = Barrier.new(2)
    use_case = A::Inspections::ApproveDamageCharge.new(uow: @system.uow, damage_reports: PausingProxy.new(repo(:damage_reports), :lock, barrier),
                                                       reservations: repo(:reservations), audit: @system.services[:audit], clock: @clock,
                                                       ids: @system.ids)

    results = race(-> { use_case.call(@actor, report["id"]) }, -> { use_case.call(@actor, report["id"]) })

    assert_equal %i[error ok], outcomes(results)
    assert_kind_of D::InvalidTransition, results.find { |r| r.first == :error }.last
    assert_equal 1, count("SELECT count(*) FROM reservation_adjustments WHERE kind = 'damage'")
  end
end
