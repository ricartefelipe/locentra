# frozen_string_literal: true

require_relative "../unit_helper"

class MoneyTest < UnitTest
  Money = Locentra::Domain::Money

  def test_arithmetic_keeps_integer_cents
    total = Money.new(1050) + Money.new(250) - Money.new(100)

    assert_equal 1200, total.cents
    assert_equal "12.00", total.to_decimal_string
  end

  def test_rejects_float_cents_and_float_factors
    assert_raises(ArgumentError) { Money.new(10.5) }
    assert_raises(ArgumentError) { Money.new(100) * 1.5 }
  end

  def test_multiplies_by_rational_with_half_up_rounding
    assert_equal 5, (Money.new(10) * Rational(1, 2)).cents
    assert_equal 2, (Money.new(5) * Rational(1, 3)).cents # 1,666.. -> 2
    assert_equal 2, (Money.new(3) * Rational(1, 2)).cents # 1,5 -> 2 (meio para cima)
  end

  def test_half_up_rounding_rule
    assert_equal 2, Money.round_half_up(Rational(3, 2))
    assert_equal(-2, Money.round_half_up(Rational(-3, 2)))
    assert_equal 1, Money.round_half_up(Rational(149, 100))
  end

  def test_percent_in_basis_points
    assert_equal 1500, Money.new(10_000).percent(1500).cents
    assert_equal 33, Money.new(333).percent(1000).cents # 33,3 -> 33
    assert_equal 34, Money.new(335).percent(1000).cents # 33,5 -> 34
  end

  def test_parse_accepts_brazilian_and_decimal_formats
    assert_equal 123_456, Money.parse("1.234,56").cents
    assert_equal 123_456, Money.parse("1234,56").cents
    assert_equal 123_456, Money.parse("1234.56").cents
    assert_equal 1000, Money.parse("10").cents
    assert_equal(-550, Money.parse("-5.50").cents)
  end

  def test_parse_rejects_invalid_values
    ["", "abc", "1.234.56", "10.123", "1e3", "NaN"].each do |value|
      assert_raises(Locentra::Domain::ValidationError, "aceitou #{value.inspect}") { Money.parse(value) }
    end
  end

  def test_rejects_values_beyond_limit
    assert_raises(Locentra::Domain::ValidationError) { Money.new(Money::MAX_CENTS + 1) }
  end

  def test_rejects_mixed_currencies_and_non_money
    assert_raises(ArgumentError) { Money.new(1) + 1 }
    assert_raises(ArgumentError) { Money.new(1, "USD") }
  end

  def test_formats_brl
    assert_equal "R$ 1.234.567,89", Money.new(123_456_789).format_brl
    assert_equal "-R$ 0,05", Money.new(-5).format_brl
    assert_equal({ "amount_cents" => 100, "currency" => "BRL", "formatted" => "R$ 1,00" }, Money.new(100).to_h)
  end

  def test_comparison_and_helpers
    assert_operator Money.new(2), :>, Money.new(1)
    assert_equal Money.new(1), Money.new(2).min(Money.new(1))
    assert_equal Money.new(2), Money.new(2).max(Money.new(1))
    assert_predicate Money.zero, :zero?
    assert_predicate Money.new(-1), :negative?
    assert_equal Money.new(1), -Money.new(-1)
    assert_equal Money.new(3), Money.sum([Money.new(1), Money.new(2)])
    assert_nil(Money.new(1) <=> 1)
    assert_equal Money.new(5), Money.new(-5).abs
    assert_equal [Money.new(1, "BRL")].uniq.size, [Money.new(1), Money.new(1)].uniq.size
  end

  def test_allocate_preserves_total_with_largest_remainder
    shares = Money.new(100).allocate([1, 1, 1])

    assert_equal [34, 33, 33], shares.map(&:cents)
    assert_equal [-34, -33, -33], Money.new(-100).allocate([1, 1, 1]).map(&:cents)
    assert_equal [0, 0], Money.new(10).allocate([0, 0]).map(&:cents)
    assert_raises(ArgumentError) { Money.new(10).allocate([]) }
    assert_raises(ArgumentError) { Money.new(10).allocate([-1]) }
  end

  def test_property_allocation_sums_exactly
    property("rateio preserva o total") do |random|
      cents = random.rand(-1_000_000..1_000_000)
      weights = Array.new(random.rand(1..8)) { random.rand(0..1000) }
      weights[0] = 1 if weights.sum.zero?
      shares = Money.new(cents).allocate(weights)

      assert_equal cents, shares.sum(&:cents)
      shares.zip(weights).each do |share, weight|
        exact = Rational(cents * weight, weights.sum)

        assert_operator (share.cents - exact).abs, :<, 1
      end
    end
  end

  def test_property_percent_never_exceeds_one_cent_of_error
    property("percentual com erro máximo de meio centavo") do |random|
      cents = random.rand(0..10_000_000)
      bps = random.rand(0..10_000)
      exact = Rational(cents * bps, 10_000)

      assert_operator (Money.new(cents).percent(bps).cents - exact).abs, :<=, Rational(1, 2)
    end
  end

  def test_percent_labels_use_integer_arithmetic
    labels = [500, 250, 1234, 1205, 0, 10_000].map { |bps| Domain::Percent.label(bps) }

    assert_equal %w[5% 2,5% 12,34% 12,05% 0% 100%], labels
    assert_equal "2,5", Domain::Percent.value(250)
  end
end
