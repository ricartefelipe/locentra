# frozen_string_literal: true

require_relative "integration_helper"

class ReservationFlowTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
  end

  def morning = period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z")
  def late_morning = period("2026-03-10T10:00:00Z", "2026-03-10T12:00:00Z")
  def whole_morning = period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z")

  def test_required_chairs_scenario_with_real_database
    chairs = create_product(@actor, sku: "CADEIRA", tracking: "bulk")
    stock(@actor, chairs, @branch, 10)
    reserve(@actor, @customer, @branch, morning, [line(chairs, 5)], mode: "confirm")
    reserve(@actor, @customer, @branch, late_morning, [line(chairs, 5)], mode: "confirm")

    availability = uc(:check_availability).call(@actor, branch_id: @branch.id, period: whole_morning, product_ids: [chairs.id])

    assert_equal 5, availability.first["available"]
    reservation = reserve(@actor, @customer, @branch, whole_morning, [line(chairs, 5)], mode: "confirm")

    assert_equal "confirmed", reservation.status
    error = assert_raises(D::Unavailable) { reserve(@actor, @customer, @branch, whole_morning, [line(chairs, 1)], mode: "confirm") }
    assert_equal 0, error.shortages.first["available"]
  end

  def test_serialized_asset_cannot_be_double_booked_but_adjacent_periods_work
    camera = create_product(@actor, sku: "CAM-01", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    reserve(@actor, @customer, @branch, morning, [line(camera, 1)], mode: "confirm")

    assert_raises(D::Unavailable) { reserve(@actor, @customer, @branch, whole_morning, [line(camera, 1)], mode: "hold") }
    assert_equal "confirmed", reserve(@actor, @customer, @branch, late_morning, [line(camera, 1)], mode: "confirm").status
  end

  def test_preparation_buffers_block_turnaround
    lens = create_product(@actor, sku: "LENTE", tracking: "serialized", buffer_after_minutes: 60)
    register_assets(@actor, lens, @branch, 1)
    reserve(@actor, @customer, @branch, morning, [line(lens, 1)], mode: "confirm")

    assert_raises(D::Unavailable) { reserve(@actor, @customer, @branch, late_morning, [line(lens, 1)]) }
    later = period("2026-03-10T11:00:00Z", "2026-03-10T13:00:00Z")

    assert_equal "held", reserve(@actor, @customer, @branch, later, [line(lens, 1)]).status
  end

  def test_kit_and_direct_rental_share_component_capacity
    camera = create_product(@actor, sku: "CAMERA", tracking: "serialized")
    tripod = create_product(@actor, sku: "TRIPE", tracking: "bulk")
    kit = create_product(@actor, sku: "KIT-FILMAGEM", tracking: "kit", pricing: { "daily_cents" => 25_000 })
    uc(:set_kit_components).call(@actor, kit.id, [{ product_id: camera.id, quantity: 1 }, { product_id: tripod.id, quantity: 1 }])
    register_assets(@actor, camera, @branch, 2)
    stock(@actor, tripod, @branch, 5)

    rows = uc(:check_availability).call(@actor, branch_id: @branch.id, period: morning, product_ids: [kit.id])

    assert_equal 2, rows.first["available"]
    assert_raises(D::Unavailable) { reserve(@actor, @customer, @branch, morning, [line(kit, 2), line(camera, 1)]) }
    reserve(@actor, @customer, @branch, morning, [line(kit, 1), line(camera, 1)], mode: "confirm")

    assert_equal 0, uc(:check_availability).call(@actor, branch_id: @branch.id, period: morning, product_ids: [kit.id]).first["available"]
    tags = owner_query("SELECT asset_id FROM asset_allocations WHERE active").map { |r| r["asset_id"] }

    assert_equal 2, tags.uniq.size, "o mesmo ativo não pode ser alocado duas vezes"
  end

  def test_hold_then_confirm_and_expiration_is_deterministic
    camera = create_product(@actor, sku: "CAM-HOLD", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    hold = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], hold_minutes: 10)

    @clock.advance((9 * 60) + 59)

    assert_equal "confirmed", uc(:confirm_reservation).call(@actor, hold.id).status

    other = reserve(@actor, @customer, @branch, late_morning, [line(camera, 1)], hold_minutes: 10)
    @clock.advance(10 * 60)
    assert_raises(D::HoldExpired) { uc(:confirm_reservation).call(@actor, other.id) }
    assert_equal "expired", uc(:get_reservation).call(@actor, other.id)[:reservation].status
    assert_equal 0,
                 owner_query("SELECT count(*) AS n FROM asset_allocations WHERE reservation_id = $1 AND active", [other.id]).first["n"].to_i
  end

  def test_expired_hold_no_longer_blocks_and_is_released_on_new_allocation
    camera = create_product(@actor, sku: "CAM-EXP", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    stale = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], hold_minutes: 5)
    @clock.advance(6 * 60)

    fresh = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], mode: "confirm")

    assert_equal "confirmed", fresh.status
    assert_equal "expired", uc(:get_reservation).call(@actor, stale.id)[:reservation].status
    assert_expiration_recorded(stale.id, "allocation")
  end

  # Toda expiração publica reservation.expired (webhooks, sincronização financeira) e registra
  # auditoria, qualquer que seja o gatilho.
  def assert_expiration_recorded(id, trigger)
    events = owner_query("SELECT event_type FROM outbox_events WHERE aggregate_id = $1 AND event_type = 'reservation.expired'", [id])
    audit = owner_query("SELECT details->>'trigger' AS t FROM audit_events WHERE resource_id = $1 AND action = 'reservation.expired'", [id])

    assert_equal 1, events.size, "evento reservation.expired (#{trigger})"
    assert_equal([trigger], audit.map { |r| r["t"] })
  end

  def test_expiration_on_confirmation_attempt_publishes_the_event
    camera = create_product(@actor, sku: "CAM-EVT", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    hold = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], hold_minutes: 5)
    @clock.advance(6 * 60)

    assert_raises(D::HoldExpired) { uc(:confirm_reservation).call(@actor, hold.id) }
    assert_expiration_recorded(hold.id, "confirmation_attempt")
  end

  def test_requested_reservation_allocates_on_confirmation_and_rejects_incompatible_one
    camera = create_product(@actor, sku: "CAM-REQ", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    first = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], mode: "request")
    second = reserve(@actor, @customer, @branch, whole_morning, [line(camera, 1)], mode: "request")

    uc(:confirm_reservation).call(@actor, first.id)
    error = assert_raises(D::Unavailable) { uc(:confirm_reservation).call(@actor, second.id) }

    assert_equal "CAM-REQ", error.shortages.first["sku"]
    assert_equal "requested", uc(:get_reservation).call(@actor, second.id)[:reservation].status
  end

  def test_multi_item_reservation_is_all_or_nothing
    camera = create_product(@actor, sku: "CAM-AON", tracking: "serialized")
    chairs = create_product(@actor, sku: "CAD-AON", tracking: "bulk")
    register_assets(@actor, camera, @branch, 1)
    stock(@actor, chairs, @branch, 2)

    assert_raises(D::Unavailable) { reserve(@actor, @customer, @branch, morning, [line(camera, 1), line(chairs, 3)]) }
    assert_equal 0, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i
    assert_equal 0, owner_query("SELECT count(*) AS n FROM asset_allocations").first["n"].to_i
  end

  def test_reschedule_with_conflict_keeps_original_period
    camera = create_product(@actor, sku: "CAM-RES", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    first = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], mode: "confirm")
    reserve(@actor, @customer, @branch, late_morning, [line(camera, 1)], mode: "confirm")

    assert_raises(D::Unavailable) { uc(:reschedule_reservation).call(@actor, first.id, period: period("2026-03-10T09:00:00Z", "2026-03-10T11:00:00Z")) }
    current = uc(:get_reservation).call(@actor, first.id)

    assert_equal morning, current[:reservation].period
    assert_equal(1, current[:allocations][:assets].count { |a| a["active"] })

    moved = uc(:reschedule_reservation).call(@actor, first.id, period: period("2026-03-11T08:00:00Z", "2026-03-11T10:00:00Z"))

    assert_equal t("2026-03-11T08:00:00Z"), moved.period.starts_at
  end

  def test_extension_invading_another_reservation_is_rejected
    camera = create_product(@actor, sku: "CAM-EXT", tracking: "serialized", pricing: { "hourly_cents" => 5_000 })
    register_assets(@actor, camera, @branch, 1)
    first = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], mode: "confirm")
    blocker = reserve(@actor, @customer, @branch, late_morning, [line(camera, 1)], mode: "confirm")

    error = assert_raises(D::Unavailable) { uc(:extend_reservation).call(@actor, first.id, ends_at: t("2026-03-10T11:00:00Z")) }
    assert_equal blocker.code, error.shortages.first["conflict"]

    uc(:cancel_reservation).call(@actor, blocker.id, reason: "cliente desistiu")
    result = uc(:extend_reservation).call(@actor, first.id, ends_at: t("2026-03-10T11:00:00Z"))

    assert_equal 5_000, result[:adjustment].cents
    pricing = uc(:get_reservation).call(@actor, first.id)[:pricing]

    assert_equal 10_000, pricing[:summary]["total_cents"], "a cobrança original é preservada"
    assert_equal([5_000], pricing[:adjustments].map { |a| a["amount_cents"] })
  end

  def test_pricing_snapshot_is_preserved_after_catalog_change
    camera = create_product(@actor, sku: "CAM-PRC", tracking: "serialized", pricing: { "daily_cents" => 12_000 })
    register_assets(@actor, camera, @branch, 1)
    reservation = reserve(@actor, @customer, @branch, period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z"), [line(camera, 1)],
                          mode: "confirm")
    uc(:update_product_pricing).call(@actor, camera.id, pricing: { "daily_cents" => 99_000 })

    details = uc(:get_reservation).call(@actor, reservation.id)

    assert_equal 24_000, details[:pricing][:summary]["total_cents"]
    assert_equal 12_000, details[:items].first["pricing"]["unit_amount_cents"] / 2
  end

  # Snapshot de preços pré-calculado (conversão de orçamento): precisa corresponder exatamente aos
  # itens e ao período da reserva; divergências são recusadas sem gravar nada.
  def test_precalculated_pricing_snapshot_must_match_items_and_period
    camera = create_product(@actor, sku: "CAM-SNP", tracking: "serialized", pricing: { "daily_cents" => 12_000 })
    lens = create_product(@actor, sku: "LEN-SNP", tracking: "serialized", pricing: { "daily_cents" => 3_000 })
    register_assets(@actor, camera, @branch, 2)
    register_assets(@actor, lens, @branch, 1)
    rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")
    priced = @system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      products = @system.services[:allocator].products_for(tx, [camera.id])
      @system.services[:pricer].price(tx, products: products, lines: [line(camera, 1)], period: rental, zone: D::TimeZone.new("America/Sao_Paulo"),
                                          customer_id: @customer.id, now: @clock.now)
    end
    snapshot = { items: priced.items, summary: priced.summary }
    cases = {
      "quantidade" => [rental, [line(camera, 2)], "itens"],
      "produto" => [rental, [line(lens, 1)], "itens"],
      "item a mais" => [rental, [line(camera, 1), line(lens, 1)], "itens"],
      "período" => [period("2026-03-10T08:00:00Z", "2026-03-13T08:00:00Z"), [line(camera, 1)], "período"]
    }
    cases.each do |label, (requested, lines, reason)|
      error = assert_raises(D::ValidationError, label) { reserve(@actor, @customer, @branch, requested, lines, mode: "confirm", pricing_snapshot: snapshot) }

      assert_includes error.errors.fetch("precos").first, reason, label
    end
    assert_equal 0, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i
    reservation = reserve(@actor, @customer, @branch, rental, [line(camera, 1)], mode: "confirm", pricing_snapshot: snapshot)

    assert_equal 24_000, reservation.total.cents
  end

  def test_asset_status_change_relocates_future_reservations
    camera = create_product(@actor, sku: "CAM-MNT", tracking: "serialized")
    first, second = register_assets(@actor, camera, @branch, 2)
    reservation = reserve(@actor, @customer, @branch, morning, [line(camera, 1)], mode: "confirm")
    allocated = owner_query("SELECT asset_id FROM asset_allocations WHERE reservation_id = $1 AND active",
                            [reservation.id]).first["asset_id"]

    uc(:change_asset_status).call(@actor, allocated, status: "in_maintenance", reason: "lente riscada")
    now_allocated = owner_query("SELECT asset_id FROM asset_allocations WHERE reservation_id = $1 AND active",
                                [reservation.id]).first["asset_id"]

    refute_equal allocated, now_allocated
    assert_includes [first.id, second.id], now_allocated
    other = [first.id, second.id].find { |id| id != allocated }
    assert_raises(D::Conflict) { uc(:change_asset_status).call(@actor, other, status: "lost") }
  end

  def test_stock_reduction_cannot_uncover_future_reservations
    chairs = create_product(@actor, sku: "CAD-RED", tracking: "bulk")
    stock(@actor, chairs, @branch, 10)
    reserve(@actor, @customer, @branch, morning, [line(chairs, 8)], mode: "confirm")

    assert_raises(D::Conflict) { uc(:adjust_stock).call(@actor, product_id: chairs.id, branch_id: @branch.id, quantity: 3, kind: "loss") }
    assert_equal 8, uc(:adjust_stock).call(@actor, product_id: chairs.id, branch_id: @branch.id, quantity: 2, kind: "loss").total_quantity
  end

  def test_sweeper_expires_holds_and_records_audit
    chairs = create_product(@actor, sku: "CAD-SWP", tracking: "bulk")
    stock(@actor, chairs, @branch, 3)
    hold = reserve(@actor, @customer, @branch, morning, [line(chairs, 3)], hold_minutes: 5)
    @clock.advance(5 * 60)

    expired = uc(:expire_holds).call(A::Actor.system(organization_id: @org[:organization_id]))

    assert_equal [hold.id], expired
    assert_equal 3,
                 uc(:check_availability).call(@actor, branch_id: @branch.id, period: morning, product_ids: [chairs.id]).first["available"]
    actions = owner_query("SELECT action FROM audit_events WHERE resource_id = $1 ORDER BY occurred_at", [hold.id]).map { |r| r["action"] }

    assert_equal %w[reservation.created reservation.expired], actions
    assert_expiration_recorded(hold.id, "sweeper")
  end

  def test_blocked_customer_and_past_start_are_rejected
    camera = create_product(@actor, sku: "CAM-VAL", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    assert_raises(D::ValidationError) { reserve(@actor, @customer, @branch, period("2026-03-01T08:00:00Z", "2026-03-01T10:00:00Z"), [line(camera, 1)]) }
    uc(:update_customer).call(@actor, @customer.id, status: "blocked")

    assert_raises(D::ValidationError) { reserve(@actor, @customer, @branch, morning, [line(camera, 1)]) }
  end

  def test_reservation_codes_are_sequential_per_organization
    chairs = create_product(@actor, sku: "CAD-COD", tracking: "bulk")
    stock(@actor, chairs, @branch, 10)
    codes = Array.new(2) { reserve(@actor, @customer, @branch, morning, [line(chairs, 1)]).code }

    assert_equal %w[R-000001 R-000002], codes
  end
end
