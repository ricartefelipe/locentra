# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/operations_support"

# Retirada, devolução, inspeção, avarias e multa por atraso com PostgreSQL real.
class FulfillmentFlowTest < DatabaseTest
  include OperationsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-OP", tracking: "serialized", replacement_cost: D::Money.new(500_000), buffer_after_minutes: 60)
    @cameras = register_assets(@actor, @camera, @branch, 3)
    @chairs = create_product(@actor, sku: "CAD-OP", tracking: "bulk", pricing: { "daily_cents" => 500 }, replacement_cost: D::Money.new(8_000))
    stock(@actor, @chairs, @branch, 10)
  end

  def test_pickup_separation_check_swap_and_delivery
    reservation = confirmed([line(@camera, 2), line(@chairs, 4)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)

    assert_equal pickup.id, uc(:start_pickup).call(@actor, reservation.id).id, "separação repetida devolve a retirada em andamento"
    lines = uc(:get_pickup).call(@actor, pickup.id)[:lines]

    assert_equal 3, lines.size
    asset_lines = lines.select { |l| l["asset_id"] }
    stock_line = lines.find { |l| l["stock_pool_id"] }
    allocated = asset_lines.map { |l| l["allocated_tag"] }
    free = (@cameras.map(&:tag) - allocated).first

    error = assert_raises(D::ValidationError) do
      uc(:check_pickup).call(@actor, pickup.id, [{ line_id: asset_lines[0]["id"], tag: "CAD-INEXISTENTE" },
                                                 { line_id: asset_lines[1]["id"], tag: allocated[0] }])
    end
    assert_match(/não encontrado/, error.message)
    assert_match(/já está alocado/, error.message, "trocar para unidade alocada em outra linha é recusado")

    uc(:check_pickup).call(@actor, pickup.id, [{ line_id: asset_lines[0]["id"], tag: allocated[0] },
                                               { line_id: asset_lines[1]["id"], tag: free.downcase }, { line_id: stock_line["id"], quantity: "3" }])
    delivered = uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })

    assert_equal "delivered", delivered.status
    assert_equal "customer", delivered.picker.kind
    assert_equal "in_progress", reservation_status(reservation)
    tags = [allocated[0], free]
    out = owner_query("SELECT tag, status FROM assets WHERE status = 'checked_out' ORDER BY tag").map { |r| r["tag"] }

    assert_equal tags.sort, out
    assert_equal 2, count("SELECT count(*) FROM asset_events WHERE kind = 'checked_out' AND reference_id = $1", [pickup.id])
    assert_equal 3, count("SELECT quantity FROM stock_allocations WHERE reservation_id = $1 AND active", [reservation.id]),
                 "a quantidade não conferida é liberada"
    final = uc(:get_pickup).call(@actor, pickup.id)[:lines].find { |l| l["stock_pool_id"] }

    assert_equal %w[partial 3], [final["status"], final["delivered_quantity"].to_s]
    assert_equal "não conferido na retirada", final["release_reason"]
    assert_equal 1, count("SELECT count(*) FROM outbox_events WHERE event_type = 'reservation.picked_up'")
  end

  def test_unchecked_items_are_released_and_pickup_requires_checked_item
    reservation = confirmed([line(@camera, 1), line(@chairs, 2)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)

    assert_raises(D::ValidationError) { uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" }) }
    camera_line = uc(:get_pickup).call(@actor, pickup.id)[:lines].find { |l| l["asset_id"] }
    uc(:check_pickup).call(@actor, pickup.id, [{ line_id: camera_line["id"], tag: camera_line["allocated_tag"] }])
    uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })

    assert_equal 0, count("SELECT count(*) FROM stock_allocations WHERE reservation_id = $1 AND active", [reservation.id])
    assert_equal(["not_delivered"], owner_query("SELECT status FROM pickup_lines WHERE stock_pool_id IS NOT NULL").map { |r| r["status"] })
    assert_equal 10, available(@chairs, rental_period)
  end

  def later_rental = period("2026-03-10T09:00:00Z", "2026-03-12T09:00:00Z")
  def gap_window = period("2026-03-04T09:00:00Z", "2026-03-06T09:00:00Z")

  def allocation_starts(table, reservation)
    owner_query("SELECT lower(period) AS s FROM #{table} WHERE reservation_id = $1 AND active", [reservation.id]).map { |row| Time.parse(row["s"]) }
  end

  def single_lens
    lens = create_product(@actor, sku: "LEN-OP", tracking: "serialized")
    register_assets(@actor, lens, @branch, 1)
    lens
  end

  def test_early_pickup_occupies_the_items_from_delivery_until_the_reservation_starts
    lens = single_lens
    reservation = confirmed([line(lens, 1), line(@chairs, 6)], later_rental)
    confirmed([line(@chairs, 4)], gap_window)

    assert_equal [1, 6], [available(lens, gap_window), available(@chairs, gap_window)]
    pick_up(reservation)

    assert_equal [0, 0], [available(lens, gap_window), available(@chairs, gap_window)], "o que está com o cliente não é oferecido no intervalo"
    assert_raises(D::Unavailable) { confirmed([line(lens, 1)], gap_window) }
    assert_equal [[@clock.now], [@clock.now]], [allocation_starts("asset_allocations", reservation), allocation_starts("stock_allocations", reservation)]
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-13T09:00:00Z"))

    assert_equal [[@clock.now], [@clock.now]], [allocation_starts("asset_allocations", reservation), allocation_starts("stock_allocations", reservation)],
                 "a extensão não adia o início antecipado"
    assert_equal [0, 0], [available(lens, gap_window), available(@chairs, gap_window)]
  end

  def test_early_pickup_is_refused_when_the_interval_before_the_start_is_committed
    lens = single_lens
    reservation = confirmed([line(lens, 1)], later_rental)
    blocker = confirmed([line(lens, 1)], gap_window)
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    uc(:check_pickup).call(@actor, pickup.id, check_entries(@actor, pickup))

    error = assert_raises(D::Conflict) { uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" }) }
    assert_equal "early_pickup_unavailable", error.code
    assert_includes error.message, blocker.code
    assert_equal "confirmed", reservation_status(reservation)
    chairs = confirmed([line(@chairs, 6)], later_rental)
    confirmed([line(@chairs, 5)], gap_window)
    pickup = uc(:start_pickup).call(@actor, chairs.id)
    uc(:check_pickup).call(@actor, pickup.id, check_entries(@actor, pickup))

    error = assert_raises(D::Unavailable) { uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" }) }
    assert_equal [6, 5], error.shortages.first.values_at("requested", "available")
    assert_equal [t("2026-03-10T09:00:00Z")], allocation_starts("stock_allocations", chairs)
    @clock.travel_to(t("2026-03-06T09:00:00Z"))
    uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })

    assert_equal [@clock.now], allocation_starts("stock_allocations", chairs), "fora do intervalo comprometido a entrega antecipada é aceita"
  end

  def test_check_rejects_wrong_product_other_branch_and_unavailable_unit
    other_branch = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    elsewhere = register_assets(@actor, @camera, other_branch, 1, prefix: "CAM-NORTE").first
    lens = create_product(@actor, sku: "LENTE-OP", tracking: "serialized")
    lens_asset = register_assets(@actor, lens, @branch, 1).first
    reservation = confirmed([line(@camera, 1)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    line_id = uc(:get_pickup).call(@actor, pickup.id)[:lines].first["id"]
    maintenance = @cameras.find { |a| a.id != owner_query("SELECT asset_id FROM asset_allocations WHERE active").first["asset_id"] }
    uc(:change_asset_status).call(@actor, maintenance.id, status: "in_maintenance", reason: "teste")

    [lens_asset.tag, elsewhere.tag, maintenance.tag, ""].each do |tag|
      assert_raises(D::ValidationError) { uc(:check_pickup).call(@actor, pickup.id, [{ line_id: line_id, tag: tag }]) }
    end
    assert_raises(D::ValidationError) { uc(:check_pickup).call(@actor, pickup.id, [{ line_id: line_id, quantity: 1 }]) }
    assert_raises(D::ValidationError) { uc(:check_pickup).call(@actor, pickup.id, []) }
  end

  def test_picker_must_be_individual_customer_or_authorized_contact
    company = create_customer(@actor, name: "Produtora Ltda", document: "11222333000181", kind: "company")
    unauthorized = uc(:add_contact).call(@actor, company.id, { name: "Sem Autorização" })
    authorized = uc(:add_contact).call(@actor, company.id, { name: "Retirante", document: "11144477735", authorized_pickup: true })
    reservation = confirmed([line(@camera, 1)], customer: company)
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    uc(:check_pickup).call(@actor, pickup.id, check_entries(@actor, pickup))

    assert_raises(D::ValidationError) { uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" }) }
    assert_raises(D::ValidationError) { uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "contact", contact_id: unauthorized.id }) }
    assert_raises(D::ValidationError) { uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "contact", contact_id: @customer.id }) }
    assert_raises(D::ValidationError) { uc(:deliver_pickup).call(@actor, pickup.id, picker: {}) }
    delivered = uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "contact", contact_id: authorized.id })

    assert_equal ["Retirante", "111.444.777-35"], [delivered.picker.name, delivered.picker.formatted_document]
    assert_equal "11144477735", owner_query("SELECT picker_document FROM pickups").first["picker_document"]
  end

  def test_duplicate_pickup_is_rejected_sequentially_and_by_constraints
    reservation = confirmed([line(@camera, 1)])
    delivered = pick_up(reservation)

    error = assert_raises(D::Conflict) { uc(:deliver_pickup).call(@actor, delivered.id, picker: { kind: "customer" }) }
    assert_equal "already_picked_up", error.code
    assert_raises(D::InvalidTransition) { uc(:start_pickup).call(@actor, reservation.id) }
    assert_raises(D::Conflict) { uc(:cancel_pickup).call(@actor, delivered.id, reason: "engano") }
    assert_equal 1, count("SELECT count(*) FROM asset_events WHERE kind = 'checked_out'")
    allocation = owner_query("SELECT id, asset_id, reservation_item_id, product_id FROM asset_allocations").first
    assert_raises(PG::UniqueViolation) do
      owner_query(<<~SQL, [SecureRandom.uuid, @org[:organization_id], reservation.id, @branch.id])
        INSERT INTO pickups (id, organization_id, reservation_id, branch_id, started_at) VALUES ($1, $2, $3, $4, now())
      SQL
    end
    pickup_id = owner_query("SELECT id FROM pickups").first["id"]
    assert_raises(PG::UniqueViolation) do
      owner_query(<<~SQL, [SecureRandom.uuid, @org[:organization_id], pickup_id, reservation.id, allocation["reservation_item_id"], allocation["product_id"], allocation["id"], allocation["asset_id"]])
        INSERT INTO pickup_lines (id, organization_id, pickup_id, reservation_id, reservation_item_id, product_id, asset_allocation_id, asset_id, expected_quantity)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 1)
      SQL
    end
  end

  def test_cancelled_pickup_allows_new_separation
    reservation = confirmed([line(@camera, 1)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)

    assert_raises(D::ValidationError) { uc(:cancel_pickup).call(@actor, pickup.id, reason: "") }
    cancelled = uc(:cancel_pickup).call(@actor, pickup.id, reason: "cliente pediu outro horário")

    assert_equal "cancelled", cancelled.status
    assert_raises(D::InvalidTransition) { uc(:check_pickup).call(@actor, pickup.id, check_entries(@actor, pickup)) }
    fresh = uc(:start_pickup).call(@actor, reservation.id)

    refute_equal pickup.id, fresh.id
    uc(:check_pickup).call(@actor, fresh.id, check_entries(@actor, fresh))

    assert_equal "delivered", uc(:deliver_pickup).call(@actor, fresh.id, picker: { kind: "customer" }).status
    assert_equal %w[cancelled delivered], owner_query("SELECT status FROM pickups ORDER BY started_at, status").map { |r| r["status"] }.sort
  end

  def test_partial_return_keeps_reservation_in_progress_then_total_completes
    reservation = confirmed([line(@camera, 2), line(@chairs, 5)])
    pick_up(reservation)
    lines = pending_lines(reservation)
    camera_line = lines.find { |l| l["asset_id"] }
    chairs_line = lines.find { |l| l["stock_pool_id"] }

    first = uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: camera_line["id"], outcome: "ok" },
                                                                        { pickup_line_id: chairs_line["id"], outcome: "ok", quantity: 2 }])

    refute first["completes_reservation"]
    assert_equal "in_progress", reservation_status(reservation)
    assert_equal "available", asset_status(camera_line["asset_id"])
    assert_equal 3, count("SELECT quantity FROM stock_allocations WHERE reservation_id = $1 AND active", [reservation.id])
    assert_equal 1, count("SELECT count(*) FROM asset_allocations WHERE kind = 'block' AND reason = 'Preparação após devolução' AND active")
    error = assert_raises(D::Conflict) do
      uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: chairs_line["id"], outcome: "ok", quantity: 4 }])
    end
    assert_equal "already_returned", error.code
    final = return_all(reservation)

    assert final["completes_reservation"]
    assert_equal "completed", reservation_status(reservation)
    assert_equal 2, count("SELECT count(*) FROM returns WHERE reservation_id = $1", [reservation.id])
    assert_equal 2, count("SELECT count(*) FROM outbox_events WHERE event_type = 'reservation.returned'")
    assert_raises(D::InvalidTransition) { uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: camera_line["id"], outcome: "ok" }]) }
  end

  def test_duplicate_asset_return_is_rejected_sequentially_and_by_constraint
    reservation = confirmed([line(@camera, 2)])
    pick_up(reservation)
    first, second = pending_lines(reservation)
    receipt = uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: first["id"], outcome: "ok" }])

    error = assert_raises(D::Conflict) { uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: first["id"], outcome: "ok" }]) }
    assert_equal "already_returned", error.code
    assert_raises(D::ValidationError) do
      uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: second["id"], outcome: "ok", quantity: 2 }])
    end
    assert_raises(D::NotFound) { uc(:register_return).call(@actor, reservation.id, entries: [{ pickup_line_id: SecureRandom.uuid, outcome: "ok" }]) }
    assert_raises(D::ValidationError) { uc(:register_return).call(@actor, reservation.id, entries: []) }
    row = owner_query("SELECT * FROM return_lines").first
    assert_raises(PG::UniqueViolation) do
      owner_query(<<~SQL, [SecureRandom.uuid, @org[:organization_id], receipt["id"], first["id"], row["reservation_item_id"], row["product_id"], row["asset_id"]])
        INSERT INTO return_lines (id, organization_id, return_id, pickup_line_id, reservation_item_id, product_id, asset_id, outcome, quantity, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'ok', 1, now())
      SQL
    end
    assert_equal 1, count("SELECT returned_quantity FROM pickup_lines WHERE id = $1", [first["id"]])
  end

  def test_returns_are_immutable_for_the_application_role
    reservation = confirmed([line(@camera, 1)])
    pick_up(reservation)
    return_all(reservation)

    assert_raises(D::AccessDenied) do
      @system.transactor.call(tenant_id: @org[:organization_id]) { |tx| tx.execute("UPDATE returns SET notes = 'alterado'") }
    end
    assert_raises(D::AccessDenied) do
      @system.transactor.call(tenant_id: @org[:organization_id]) { |tx| tx.execute("DELETE FROM return_lines") }
    end
    assert_raises(D::ValidationError, "linha entregue não pode ter acumulados reduzidos") do
      @system.transactor.call(tenant_id: @org[:organization_id]) { |tx| tx.execute("UPDATE pickup_lines SET returned_quantity = 0") }
    end
  end

  def test_inspection_blocks_availability_until_released
    reservation = confirmed([line(@camera, 3), line(@chairs, 10)])
    pick_up(reservation)
    return_all(reservation, requires_inspection: true)

    assert_equal "completed", reservation_status(reservation)
    assert_equal 0, available(@camera), "ativos em inspeção ficam indisponíveis"
    assert_equal 0, available(@chairs), "estoque em inspeção fica bloqueado"
    assert_equal 0, available(@chairs, period("2027-02-01T09:00:00Z", "2027-02-02T09:00:00Z")), "bloqueio sem fim definido"
    pending = uc(:list_inspections).call(@actor)

    assert_equal 4, pending.size
    stock_inspection = pending.find { |i| i["stock_pool_id"] }
    @clock.advance(3600)
    uc(:approve_inspection).call(@actor, stock_inspection["id"], notes: "conferido")

    assert_equal 10, available(@chairs)
    assert_raises(D::InvalidTransition) { uc(:approve_inspection).call(@actor, stock_inspection["id"]) }
    pending.select { |i| i["asset_id"] }.each { |i| uc(:approve_inspection).call(@actor, i["id"]) }

    assert_equal 3, available(@camera)
    assert_empty uc(:list_inspections).call(@actor)
    assert_equal 4, uc(:list_inspections).call(@actor, status: "decided").size
    assert_raises(D::ValidationError) { uc(:list_inspections).call(@actor, status: "todas") }
    block = owner_query("SELECT active, upper(period) AS ends_at FROM stock_allocations WHERE kind = 'block'").first

    assert_equal "f", block["active"]
    assert_equal @clock.now, Time.parse(block["ends_at"])
  end

  def test_damage_makes_item_unavailable_and_rejection_opens_maintenance
    reservation = confirmed([line(@camera, 1), line(@chairs, 2)])
    pick_up(reservation)
    lines = pending_lines(reservation)
    asset_id = lines.find { |l| l["asset_id"] }["asset_id"]
    assert_raises(D::ValidationError) { return_all(reservation, outcome: "damaged") }
    return_all(reservation, outcome: "damaged", notes: "tela trincada")

    assert_equal "in_inspection", asset_status(asset_id)
    assert_equal 2, available(@camera)
    assert_equal 8, available(@chairs)
    assert_equal 2, uc(:list_damage_reports).call(@actor).size
    inspection = uc(:list_inspections).call(@actor).find { |i| i["asset_id"] }
    assert_raises(D::ValidationError) { uc(:reject_inspection).call(@actor, inspection["id"], notes: "") }
    result = uc(:reject_inspection).call(@actor, inspection["id"], notes: "display danificado", description: "Troca do display")

    assert_equal "rejected", result[:inspection].status
    assert_equal "in_maintenance", asset_status(asset_id)
    assert_equal 2, available(@camera)
    order = result[:order]

    assert_equal ["OM-000001", "Troca do display"], [order.code, order.description]
    assert_raises(D::InvalidTransition) { uc(:reject_inspection).call(@actor, inspection["id"], notes: "de novo") }
    stock_inspection = uc(:list_inspections).call(@actor).first
    stock_order = uc(:reject_inspection).call(@actor, stock_inspection["id"], notes: "assento solto")[:order]

    assert_equal 8, available(@chairs), "estoque continua bloqueado na manutenção"
    uc(:start_maintenance).call(@actor, stock_order.id)
    uc(:complete_maintenance).call(@actor, stock_order.id, cost: D::Money.new(1_500))

    assert_equal 10, available(@chairs)
  end

  def test_late_return_records_late_fee_with_snapshot_table
    reservation = confirmed([line(@camera, 1), line(@chairs, 3)])
    uc(:update_product_pricing).call(@actor, @chairs.id, pricing: { "daily_cents" => 99_900 })
    pick_up(reservation)
    @clock.travel_to(t("2026-03-04T15:00:00Z"))
    receipt = return_all(reservation)

    fees = owner_query("SELECT amount_cents, details FROM reservation_adjustments WHERE kind = 'late_fee' ORDER BY amount_cents")
    table = owner_query("SELECT pricing FROM reservation_items WHERE product_id = $1", [@chairs.id]).first["pricing"]
    expected = D::Pricing::LateFee.calculate(table: D::Pricing::PriceTable.from_h(JSON.parse(table)["table"]), scheduled_end: rental_period.ends_at,
                                             returned_at: @clock.now, quantity: 3, zone: D::TimeZone.new("America/Sao_Paulo"))

    assert_equal([1_500, 10_000], fees.map { |f| f["amount_cents"].to_i })
    assert_equal expected.cents, fees.first["amount_cents"].to_i
    assert_equal 11_500, receipt["late_fee_cents"]
    assert_equal 2, uc(:get_return).call(@actor, receipt["id"])[:late_fees].size
  end

  def test_return_before_scheduled_end_has_no_late_fee
    reservation = confirmed([line(@chairs, 3)])
    pick_up(reservation)
    receipt = return_all(reservation)

    assert_equal 0, receipt["late_fee_cents"]
    assert_equal 0, count("SELECT count(*) FROM reservation_adjustments WHERE kind = 'late_fee'")
  end
end
