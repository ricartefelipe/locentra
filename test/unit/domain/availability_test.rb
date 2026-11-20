# frozen_string_literal: true

require_relative "../unit_helper"

class AvailabilityTest < UnitTest
  A = Locentra::Domain::Availability

  def occ(from, to, quantity)
    A::Occupancy.new(period: period(from, to), quantity: quantity)
  end

  def test_required_scenario_ten_chairs_with_consecutive_reservations
    ledger = A::StockLedger.new(capacity: 10, occupancies: [
                                  occ("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z", 5),
                                  occ("2026-03-02T10:00:00Z", "2026-03-02T12:00:00Z", 5)
                                ])
    window = period("2026-03-02T08:00:00Z", "2026-03-02T12:00:00Z")

    assert_equal 5, ledger.peak(window)
    assert_equal 5, ledger.available(window)
    assert ledger.fits?(window, 5)
    refute ledger.fits?(window, 6)
  end

  def test_overlapping_occupancies_add_up_only_when_simultaneous
    ledger = A::StockLedger.new(capacity: 10, occupancies: [
                                  occ("2026-03-02T08:00:00Z", "2026-03-02T11:00:00Z", 4),
                                  occ("2026-03-02T10:00:00Z", "2026-03-02T12:00:00Z", 3),
                                  occ("2026-03-02T11:00:00Z", "2026-03-02T13:00:00Z", 2)
                                ])

    assert_equal 7, ledger.peak(period("2026-03-02T08:00:00Z", "2026-03-02T13:00:00Z"))
    assert_equal 5, ledger.peak(period("2026-03-02T11:00:00Z", "2026-03-02T13:00:00Z"))
    assert_equal 4, ledger.peak(period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z"))
    assert_equal 0, ledger.peak(period("2026-03-02T13:00:00Z", "2026-03-02T15:00:00Z"))
  end

  def test_reserve_returns_new_ledger_and_rejects_overbooking
    ledger = A::StockLedger.new(capacity: 3)
    window = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")
    after = ledger.reserve(window, 2)

    assert_equal 3, ledger.available(window)
    assert_equal 1, after.available(window)
    error = assert_raises(Locentra::Domain::Unavailable) { after.reserve(window, 2) }
    assert_equal 1, error.shortages.first["available"]
  end

  def test_available_never_negative_and_validates_inputs
    ledger = A::StockLedger.new(capacity: 1, occupancies: [occ("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z", 3)])

    assert_equal 0, ledger.available(period("2026-03-02T08:00:00Z", "2026-03-02T09:00:00Z"))
    assert_raises(ArgumentError) { A::StockLedger.new(capacity: -1) }
    assert_raises(ArgumentError) { A::Occupancy.new(period: period("2026-03-02T08:00:00Z", "2026-03-02T09:00:00Z"), quantity: 0) }
    assert_raises(ArgumentError) { A::Occupancy.new(period: "x", quantity: 1) }
  end

  def test_timeline_segments
    window = period("2026-03-02T08:00:00Z", "2026-03-02T12:00:00Z")
    segments = A::Peak.timeline(window, [
                                  occ("2026-03-02T07:00:00Z", "2026-03-02T09:00:00Z", 2),
                                  occ("2026-03-02T10:00:00Z", "2026-03-02T13:00:00Z", 1)
                                ])

    assert_equal [2, 0, 1], segments.map(&:quantity)
    assert_equal window.starts_at, segments.first.period.starts_at
    assert_equal window.ends_at, segments.last.period.ends_at
  end

  def test_asset_schedule_rules
    window = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")
    busy = A::AssetSchedule.new(asset_id: "a", busy: [period("2026-03-02T09:00:00Z", "2026-03-02T11:00:00Z")])
    adjacent = A::AssetSchedule.new(asset_id: "b", busy: [period("2026-03-02T10:00:00Z", "2026-03-02T11:00:00Z")])
    retired = A::AssetSchedule.new(asset_id: "c", allocatable: false)
    in_maintenance = A::AssetSchedule.new(asset_id: "d", operationally_blocked: true)
    back_soon = A::AssetSchedule.new(asset_id: "e", operationally_blocked: true, unavailable_until: t("2026-03-02T08:00:00Z"))
    back_late = A::AssetSchedule.new(asset_id: "f", operationally_blocked: true, unavailable_until: t("2026-03-02T09:00:00Z"))

    refute busy.free?(window)
    assert adjacent.free?(window)
    refute retired.free?(window)
    refute in_maintenance.free?(window)
    assert back_soon.free?(window)
    refute back_late.free?(window)
  end

  def test_asset_picker_is_deterministic_and_never_repeats_units
    window = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")
    schedules = %w[c a b].map { |id| A::AssetSchedule.new(asset_id: id) }

    assert_equal %w[a b], A::AssetPicker.pick(window, schedules, 2)
    assert_equal %w[b c], A::AssetPicker.pick(window, schedules, 5, exclude: ["a"])
    assert_equal 3, A::AssetPicker.available_count(window, schedules)
  end

  def kit_catalog
    {
      "camera" => A::ProductSpec.new(id: "camera", tracking: "serialized"),
      "lente" => A::ProductSpec.new(id: "lente", tracking: "serialized"),
      "tripe" => A::ProductSpec.new(id: "tripe", tracking: "bulk"),
      "kit" => A::ProductSpec.new(id: "kit", tracking: "kit", components: [
                                    { product_id: "camera", quantity: 1 },
                                    { product_id: "lente", quantity: 2 },
                                    { product_id: "tripe", quantity: 1 }
                                  ])
    }
  end

  def test_kit_demand_is_aggregated_with_direct_component_requests
    expander = A::DemandExpander.new(kit_catalog)
    totals = expander.aggregate([{ product_id: "kit", quantity: 2 }, { product_id: "camera", quantity: 1 }])

    assert_equal({ "camera" => 3, "lente" => 4, "tripe" => 2 }, totals)
    demands = expander.expand([{ product_id: "kit", quantity: 1 }])

    assert(demands.all? { |d| d.kit_id == "kit" && d.line_index.zero? })
  end

  def test_kit_competing_with_direct_rental_for_shared_component
    window = period("2026-03-02T08:00:00Z", "2026-03-02T18:00:00Z")
    cameras = [A::AssetSchedule.new(asset_id: "cam-1"), A::AssetSchedule.new(asset_id: "cam-2")]
    totals = A::DemandExpander.new(kit_catalog).aggregate([{ product_id: "kit", quantity: 2 }, { product_id: "camera", quantity: 1 }])

    assert_operator totals["camera"], :>, A::AssetPicker.available_count(window, cameras)
    assert_equal 2, A::AssetPicker.pick(window, cameras, totals["camera"]).uniq.size
  end

  def test_expander_rejects_invalid_lines
    expander = A::DemandExpander.new(kit_catalog)

    assert_raises(Locentra::Domain::ValidationError) { expander.expand([{ product_id: "camera", quantity: 0 }]) }
    assert_raises(Locentra::Domain::NotFound) { expander.expand([{ product_id: "drone", quantity: 1 }]) }
    nested = kit_catalog.merge("kit2" => A::ProductSpec.new(id: "kit2", tracking: "kit", components: [{ product_id: "kit", quantity: 1 }]))
    assert_raises(Locentra::Domain::InvariantViolation) { A::DemandExpander.new(nested).expand([{ product_id: "kit2", quantity: 1 }]) }
    assert_raises(ArgumentError) { A::ProductSpec.new(id: "x", tracking: "rental") }
  end

  def test_kit_rules
    products = kit_catalog

    assert A::KitRules.validate!("novo", [{ product_id: "camera", quantity: 1 }], products)
    assert_raises(Locentra::Domain::ValidationError) { A::KitRules.validate!("novo", [], products) }
    assert_raises(Locentra::Domain::ValidationError) do
      A::KitRules.validate!("novo", [{ product_id: "camera", quantity: 1 }, { product_id: "camera", quantity: 2 }], products)
    end
    assert_raises(Locentra::Domain::ValidationError) { A::KitRules.validate!("camera", [{ product_id: "camera", quantity: 1 }], products) }
    assert_raises(Locentra::Domain::ValidationError) { A::KitRules.validate!("novo", [{ product_id: "kit", quantity: 1 }], products) }
    assert_raises(Locentra::Domain::ValidationError) { A::KitRules.validate!("novo", [{ product_id: "lente", quantity: 0 }], products) }
    assert_raises(Locentra::Domain::NotFound) { A::KitRules.validate!("novo", [{ product_id: "drone", quantity: 1 }], products) }
  end

  # --- Propriedades -------------------------------------------------------------------

  BASE = 1_772_438_400 # 2026-03-02T08:00:00Z
  SLOT = 900

  def random_occupancies(random, count: random.rand(0..12))
    Array.new(count) do
      from = BASE + (random.rand(0..64) * SLOT)
      to = from + (random.rand(1..24) * SLOT)
      A::Occupancy.new(period: Locentra::Domain::Period.new(Time.at(from), Time.at(to)), quantity: random.rand(1..6))
    end
  end

  def random_window(random)
    from = BASE + (random.rand(0..64) * SLOT)
    Locentra::Domain::Period.new(Time.at(from), Time.at(from + (random.rand(1..32) * SLOT)))
  end

  # Ocupação calculada por força bruta em cada instante crítico da janela.
  def brute_force_peak(window, occupancies)
    points = [window.starts_at.to_i] + occupancies.flat_map { |o| [o.period.starts_at.to_i, o.period.ends_at.to_i] }
    points.select { |p| p >= window.starts_at.to_i && p < window.ends_at.to_i }.map do |instant|
      occupancies.sum { |o| o.period.starts_at.to_i <= instant && instant < o.period.ends_at.to_i ? o.quantity : 0 }
    end.max || 0
  end

  def test_property_peak_matches_brute_force
    property("pico por varredura igual à força bruta") do |random|
      occupancies = random_occupancies(random)
      window = random_window(random)

      assert_equal brute_force_peak(window, occupancies), A::Peak.within(window, occupancies)
    end
  end

  def test_property_peak_is_bounded_by_naive_sum_and_monotonic_in_window
    property("pico limitado pela soma e monotônico") do |random|
      occupancies = random_occupancies(random)
      window = random_window(random)
      wider = window.expand(before: random.rand(0..8) * SLOT, after: random.rand(0..8) * SLOT)
      naive = occupancies.select { |o| o.period.overlaps?(window) }.sum(&:quantity)

      assert_operator A::Peak.within(window, occupancies), :<=, naive
      assert_operator A::Peak.within(window, occupancies), :<=, A::Peak.within(wider, occupancies)
    end
  end

  def test_property_accepted_reservations_never_exceed_capacity
    property("reservas aceitas nunca excedem a capacidade") do |random|
      capacity = random.rand(1..20)
      ledger = A::StockLedger.new(capacity: capacity)
      30.times do
        window = random_window(random)
        quantity = random.rand(1..8)
        ledger = ledger.reserve(window, quantity) if ledger.fits?(window, quantity)
      end
      horizon = Locentra::Domain::Period.new(Time.at(BASE), Time.at(BASE + (200 * SLOT)))

      assert_operator brute_force_peak(horizon, ledger.occupancies), :<=, capacity
    end
  end

  def test_property_timeline_maximum_equals_peak
    property("máximo da linha do tempo igual ao pico") do |random|
      occupancies = random_occupancies(random)
      window = random_window(random)
      segments = A::Peak.timeline(window, occupancies)

      assert_equal A::Peak.within(window, occupancies), segments.map(&:quantity).max
      assert_equal(window.duration_seconds, segments.sum { |s| s.period.duration_seconds })
    end
  end

  def test_property_kit_expansion_conserves_quantities
    property("expansão de kits conserva quantidades") do |random|
      catalog = kit_catalog
      lines = Array.new(random.rand(1..5)) { { product_id: catalog.keys.sample(random: random), quantity: random.rand(1..4) } }
      totals = A::DemandExpander.new(catalog).aggregate(lines)
      kits = lines.select { |l| l[:product_id] == "kit" }.sum { |l| l[:quantity] }
      direct = ->(id) { lines.select { |l| l[:product_id] == id }.sum { |l| l[:quantity] } }

      assert_equal direct.call("camera") + kits, totals.fetch("camera", 0)
      assert_equal direct.call("lente") + (2 * kits), totals.fetch("lente", 0)
      assert_equal direct.call("tripe") + kits, totals.fetch("tripe", 0)
      refute totals.key?("kit")
    end
  end
end
