# frozen_string_literal: true

require_relative "../unit_helper"

class PeriodTest < UnitTest
  Period = Locentra::Domain::Period

  def test_half_open_intervals_do_not_overlap_when_adjacent
    morning = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")
    late_morning = period("2026-03-02T10:00:00Z", "2026-03-02T12:00:00Z")

    refute morning.overlaps?(late_morning)
    refute late_morning.overlaps?(morning)
    assert_includes morning, t("2026-03-02T08:00:00Z")
    refute_includes morning, t("2026-03-02T10:00:00Z")
  end

  def test_overlap_intersection_and_cover
    a = period("2026-03-02T08:00:00Z", "2026-03-02T12:00:00Z")
    b = period("2026-03-02T10:00:00Z", "2026-03-02T14:00:00Z")

    assert a.overlaps?(b)
    assert_equal period("2026-03-02T10:00:00Z", "2026-03-02T12:00:00Z"), a.intersection(b)
    assert a.cover?(period("2026-03-02T09:00:00Z", "2026-03-02T11:00:00Z"))
    refute a.cover?(b)
    assert_nil a.intersection(period("2026-03-03T00:00:00Z", "2026-03-03T01:00:00Z"))
  end

  def test_rejects_empty_or_inverted_periods
    assert_raises(Locentra::Domain::ValidationError) { period("2026-03-02T10:00:00Z", "2026-03-02T10:00:00Z") }
    assert_raises(Locentra::Domain::ValidationError) { period("2026-03-02T10:00:00Z", "2026-03-02T09:00:00Z") }
    assert_raises(ArgumentError) { Period.new("2026-03-02", t("2026-03-02T09:00:00Z")) }
  end

  def test_rejects_excessive_duration
    assert_raises(Locentra::Domain::ValidationError) { period("2026-01-01T00:00:00Z", "2030-01-01T00:00:00Z") }
  end

  def test_truncates_fractional_seconds_and_normalizes_to_utc
    value = Period.new(Time.at(1_700_000_000.75), Time.iso8601("2023-11-14T22:13:20-03:00"))

    assert_equal 1_700_000_000, value.starts_at.to_i
    assert_predicate value.starts_at, :utc?
    assert_equal 3 * 3600, value.duration_seconds
  end

  def test_expand_with_buffers
    base = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")

    assert_equal period("2026-03-02T07:30:00Z", "2026-03-02T11:00:00Z"), base.expand(before: 1800, after: 3600)
    assert_raises(ArgumentError) { base.expand(before: -1) }
  end

  def test_parse_requires_offset
    parsed = Period.parse("2026-03-02T08:00:00-03:00", "2026-03-02T14:00Z")

    assert_equal t("2026-03-02T11:00:00Z"), parsed.starts_at
    assert_raises(Locentra::Domain::ValidationError) { Period.parse("2026-03-02T08:00", "2026-03-02T10:00Z") }
    assert_raises(Locentra::Domain::ValidationError) { Period.parse(nil, "2026-03-02T10:00Z") }
    assert_raises(Locentra::Domain::ValidationError) { Period.parse("2026-02-30T08:00:00Z", "2026-03-02T10:00Z") }
  end

  def test_value_semantics_and_serialization
    a = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")
    b = period("2026-03-02T08:00:00Z", "2026-03-02T10:00:00Z")

    assert_equal a, b
    assert_equal a.hash, b.hash
    assert_equal "[2026-03-02T08:00:00Z,2026-03-02T10:00:00Z)", a.to_pg_range
    assert_equal({ "starts_at" => "2026-03-02T08:00:00Z", "ends_at" => "2026-03-02T10:00:00Z" }, a.to_h)
    assert_equal period("2026-03-02T08:00:00Z", "2026-03-02T11:00:00Z"), a.with_end(t("2026-03-02T11:00:00Z"))
    assert_includes a.to_s, "2026-03-02T08:00:00Z"
    assert_predicate a, :frozen?
  end

  def test_property_overlap_is_symmetric_and_matches_intersection
    property("sobreposição simétrica") do |random|
      base = 1_770_000_000
      a1 = base + (random.rand(0..100) * 900)
      a2 = a1 + (random.rand(1..40) * 900)
      b1 = base + (random.rand(0..100) * 900)
      b2 = b1 + (random.rand(1..40) * 900)
      a = Period.new(Time.at(a1), Time.at(a2))
      b = Period.new(Time.at(b1), Time.at(b2))

      assert_equal a.overlaps?(b), b.overlaps?(a)
      assert_equal a.overlaps?(b), !a.intersection(b).nil?
      assert_equal(a1 < b2 && b1 < a2, a.overlaps?(b))
    end
  end
end
