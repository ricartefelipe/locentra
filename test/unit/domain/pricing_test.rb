# frozen_string_literal: true

require_relative "../unit_helper"

class PricingTest < UnitTest
  P = Locentra::Domain::Pricing
  SP = Locentra::Domain::TimeZone.new("America/Sao_Paulo")

  def table(hash) = P::PriceTable.from_h(hash)

  def price(hash, from, to, zone: SP)
    P::Calculator.unit_price(table(hash), period(from, to), zone)
  end

  def test_hourly_rounding_grace_and_daily_cap
    rates = { "hourly_cents" => 1000, "daily_cents" => 5000, "rounding_minutes" => 60, "grace_minutes" => 10 }

    assert_equal 2000, price(rates, "2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z").amount.cents
    assert_equal 2000, price(rates, "2026-03-02T08:00:00Z", "2026-03-02T10:10:00Z").amount.cents, "tolerância"
    assert_equal 3000, price(rates, "2026-03-02T08:00:00Z", "2026-03-02T10:11:00Z").amount.cents
    assert_equal 5000, price(rates, "2026-03-02T08:00:00Z", "2026-03-02T17:00:00Z").amount.cents, "teto de uma diária"
    half = { "hourly_cents" => 1000, "rounding_minutes" => 30 }

    assert_equal 1500, price(half, "2026-03-02T08:00:00Z", "2026-03-02T09:20:00Z").amount.cents
  end

  def test_minimum_period_is_charged
    rates = { "hourly_cents" => 1000, "minimum_minutes" => 240 }
    quote = price(rates, "2026-03-02T08:00:00Z", "2026-03-02T09:00:00Z")

    assert_equal 4000, quote.amount.cents
    assert_equal "4 horas", quote.description
  end

  def test_rolling_24h_daily_counts_blocks_from_pickup
    rates = { "daily_cents" => 10_000, "grace_minutes" => 60 }

    assert_equal 10_000, price(rates, "2026-03-02T18:00:00Z", "2026-03-03T18:00:00Z").amount.cents
    assert_equal 10_000, price(rates, "2026-03-02T18:00:00Z", "2026-03-03T18:59:00Z").amount.cents, "dentro da tolerância"
    assert_equal 20_000, price(rates, "2026-03-02T18:00:00Z", "2026-03-03T19:01:00Z").amount.cents
  end

  def test_calendar_day_counts_local_dates_touched
    rates = { "daily_cents" => 10_000, "daily_mode" => "calendar_day" }
    # 18:00 de segunda a 09:00 de terça (horário de São Paulo) toca duas datas locais.
    quote = price(rates, "2026-03-02T21:00:00Z", "2026-03-03T12:00:00Z")

    assert_equal 20_000, quote.amount.cents
    assert_equal "2 dias de calendário", quote.description
    rolling = price(rates.merge("daily_mode" => "rolling_24h"), "2026-03-02T21:00:00Z", "2026-03-03T12:00:00Z")

    assert_equal 10_000, rolling.amount.cents, "a mesma locação em 24h conta uma diária"
  end

  def test_calendar_day_grace_after_midnight
    rates = { "daily_cents" => 10_000, "daily_mode" => "calendar_day", "grace_minutes" => 30 }

    assert_equal 10_000, price(rates, "2026-03-02T11:00:00Z", "2026-03-03T03:20:00Z").amount.cents
  end

  def test_weekly_combination_caps_remaining_days
    rates = { "daily_cents" => 10_000, "weekly_cents" => 50_000 }

    assert_equal 50_000, price(rates, "2026-03-02T08:00:00Z", "2026-03-09T08:00:00Z").amount.cents
    assert_equal 70_000, price(rates, "2026-03-02T08:00:00Z", "2026-03-11T08:00:00Z").amount.cents
    capped = price(rates, "2026-03-02T08:00:00Z", "2026-03-15T08:00:00Z")

    assert_equal 100_000, capped.amount.cents
    assert_includes capped.description, "teto"
    assert_equal 100_000, price({ "weekly_cents" => 50_000 }, "2026-03-02T08:00:00Z", "2026-03-10T08:00:00Z").amount.cents
  end

  def test_dst_transition_day_is_handled_in_local_calendar
    ny = Locentra::Domain::TimeZone.new("America/New_York")
    rates = { "daily_cents" => 10_000, "daily_mode" => "calendar_day" }
    # 2026-03-08 tem 23 horas em Nova York; continua sendo um único dia de calendário.
    quote = P::Calculator.unit_price(table(rates), Locentra::Domain::Period.new(ny.start_of_day(Date.new(2026, 3, 8)), ny.start_of_day(Date.new(2026, 3, 9))),
                                     ny)

    assert_equal 10_000, quote.amount.cents
    assert_equal 23 * 3600, ny.start_of_day(Date.new(2026, 3, 9)) - ny.start_of_day(Date.new(2026, 3, 8))
  end

  def test_line_quantity_tiers_and_negotiated_discount
    t = table("daily_cents" => 1000, "quantity_tiers" => [{ "min_quantity" => 10, "discount_bps" => 1000 }, { "min_quantity" => 50, "discount_bps" => 2000 }])
    line = P::Line.price(table: t, period: period("2026-03-02T08:00:00Z", "2026-03-03T08:00:00Z"), zone: SP, quantity: 12, negotiated_bps: 500)

    assert_equal 12_000, line["gross_cents"]
    assert_equal 1_200, line["tier_discount_cents"]
    assert_equal 540, line["negotiated_discount_cents"]
    assert_equal 10_260, line["total_cents"]
  end

  def test_totals_with_coupon_manual_discount_fees_and_role_limit
    lines = [{ "total_cents" => 10_000 }, { "total_cents" => 5_000 }]
    coupon = P::Coupon.new(code: "BEMVINDO", kind: "percent", value: 1000, valid_from: nil, valid_until: nil, max_redemptions: nil,
                           redemptions: 0, min_subtotal_cents: 0, active: true)
    fee = P::Totals.fee!("Entrega", Locentra::Domain::Money.new(2_500))
    totals = P::Totals.compose(lines: lines, fees: [fee], coupon: coupon, manual_discount_bps: 500, discount_limit_bps: 500, now: Time.now.utc)

    assert_equal 15_000, totals["subtotal_cents"]
    assert_equal 1_500, totals["coupon_discount_cents"]
    assert_equal 675, totals["manual_discount_cents"]
    assert_equal 15_325, totals["total_cents"]
    assert_raises(Locentra::Domain::AccessDenied) { P::Totals.compose(lines: lines, manual_discount_bps: 600, discount_limit_bps: 500) }
    assert_raises(Locentra::Domain::ValidationError) { P::Totals.fee!("x", Locentra::Domain::Money.zero) }
  end

  def test_coupon_rules
    base = { code: "X", kind: "fixed", value: 3000, valid_from: t("2026-03-01T00:00:00Z"), valid_until: t("2026-03-10T00:00:00Z"),
             max_redemptions: 2, redemptions: 1, min_subtotal_cents: 1000, active: true }
    coupon = P::Coupon.new(**base)
    subtotal = Locentra::Domain::Money.new(2000)

    assert coupon.applicable?(subtotal, t("2026-03-05T00:00:00Z"))
    assert_equal 2000, coupon.discount(subtotal).cents, "desconto fixo limitado ao subtotal"
    refute coupon.applicable?(subtotal, t("2026-03-10T00:00:00Z"))
    refute P::Coupon.new(**base, redemptions: 2).applicable?(subtotal, t("2026-03-05T00:00:00Z"))
    refute coupon.applicable?(Locentra::Domain::Money.new(500), t("2026-03-05T00:00:00Z"))
    assert_raises(Locentra::Domain::ValidationError) do
      P::Totals.compose(lines: [{ "total_cents" => 100 }], coupon: P::Coupon.new(**base, active: false), now: t("2026-03-05T00:00:00Z"))
    end
  end

  def test_late_fee_uses_snapshot_and_grace
    t1 = table("hourly_cents" => 1000, "daily_cents" => 6000, "grace_minutes" => 15, "late_fee_multiplier_bps" => 15_000)
    scheduled = t("2026-03-02T18:00:00Z")

    assert_equal 0, P::LateFee.calculate(table: t1, scheduled_end: scheduled, returned_at: scheduled + 900, quantity: 1, zone: SP).cents
    assert_equal 3000, P::LateFee.calculate(table: t1, scheduled_end: scheduled, returned_at: scheduled + 7200, quantity: 1, zone: SP).cents
    assert_equal 18_000, P::LateFee.calculate(table: t1, scheduled_end: scheduled, returned_at: scheduled + (30 * 3600), quantity: 1, zone: SP).cents
  end

  def test_extension_adjustment_preserves_original_charge
    t1 = table("daily_cents" => 10_000)
    original = P::Line.price(table: t1, period: period("2026-03-02T08:00:00Z", "2026-03-03T08:00:00Z"), zone: SP, quantity: 2)
    delta, repriced = P::Extension.adjustment(line_snapshot: original, new_period: period("2026-03-02T08:00:00Z", "2026-03-04T08:00:00Z"), zone: SP)

    assert_equal 20_000, original["total_cents"]
    assert_equal 40_000, repriced["total_cents"]
    assert_equal 20_000, delta.cents
  end

  def test_price_table_validation
    assert_raises(Locentra::Domain::ValidationError) { table("daily_mode" => "lunar") }
    assert_raises(Locentra::Domain::ValidationError) { table("hourly_cents" => "-1") }
    assert_raises(Locentra::Domain::ValidationError) { table("hourly_cents" => "1.5") }
    assert_raises(Locentra::Domain::ValidationError) { table("rounding_minutes" => "20") }
    assert_raises(Locentra::Domain::ValidationError) { table("quantity_tiers" => [{ "min_quantity" => 5, "discount_bps" => 100 }, { "min_quantity" => 5, "discount_bps" => 200 }]) }
    assert_raises(Locentra::Domain::ValidationError) { P::Rules.new.normalize({ "grace_minutes" => 10 }) }
    assert_equal({},
                 P::Rules.new.normalize({}).except("daily_mode", "minimum_minutes", "rounding_minutes", "grace_minutes", "late_fee_multiplier_bps",
                                                   "quantity_tiers"))
    assert_raises(Locentra::Domain::ValidationError) { P::Calculator.unit_price(table({}), period("2026-03-02T08:00:00Z", "2026-03-03T08:00:00Z"), SP) }
  end

  def test_property_prices_are_monotonic_in_duration
    property("preço não diminui com período maior") do |random|
      rates = { "hourly_cents" => random.rand(100..5000), "daily_cents" => random.rand(5000..20_000), "weekly_cents" => random.rand(20_000..90_000),
                "daily_mode" => %w[rolling_24h calendar_day].sample(random: random), "grace_minutes" => random.rand(0..30) }
      start = t("2026-03-02T08:00:00Z")
      a = random.rand(1..400) * 1800
      b = a + (random.rand(0..200) * 1800)
      short = P::Calculator.unit_price(table(rates), Locentra::Domain::Period.new(start, start + a), SP).amount.cents
      long = P::Calculator.unit_price(table(rates), Locentra::Domain::Period.new(start, start + b), SP).amount.cents

      assert_operator short, :<=, long, "#{a}s=#{short} > #{b}s=#{long}"
      assert_operator short, :>=, 0
    end
  end

  def test_property_line_totals_never_negative_and_consistent
    property("totais de linha consistentes") do |random|
      tiers = [{ "min_quantity" => random.rand(2..20), "discount_bps" => random.rand(1..9000) }]
      t1 = table("daily_cents" => random.rand(1..100_000), "quantity_tiers" => tiers)
      qty = random.rand(1..60)
      line = P::Line.price(table: t1, period: period("2026-03-02T08:00:00Z", "2026-03-04T08:00:00Z"), zone: SP, quantity: qty,
                           negotiated_bps: random.rand(0..9000))

      assert_equal line["gross_cents"] - line["tier_discount_cents"] - line["negotiated_discount_cents"], line["total_cents"]
      assert_operator line["total_cents"], :>=, 0
    end
  end
end
