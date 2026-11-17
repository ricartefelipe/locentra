# frozen_string_literal: true

require_relative "../unit_helper"

class TimeZoneTest < UnitTest
  TimeZone = Locentra::Domain::TimeZone

  def test_converts_local_time_to_utc
    zone = TimeZone.new("America/Sao_Paulo")

    assert_equal utc(2026, 3, 2, 11, 0), zone.parse_local("2026-03-02T08:00")
    assert_equal Date.new(2026, 3, 2), zone.local_date(utc(2026, 3, 3, 2, 59))
    assert_equal Date.new(2026, 3, 3), zone.local_date(utc(2026, 3, 3, 3, 0))
    assert_equal(-3 * 3600, zone.utc_offset(utc(2026, 3, 2)))
    assert_equal "02/03/2026 08:00", zone.format_local(utc(2026, 3, 2, 11, 0))
  end

  def test_rejects_nonexistent_local_time_during_spring_forward
    zone = TimeZone.new("America/New_York")

    error = assert_raises(Locentra::Domain::ValidationError) { zone.parse_local("2026-03-08T02:30") }
    assert_match(/inexistente/, error.message)
  end

  def test_ambiguous_local_time_resolves_to_earliest_instant
    zone = TimeZone.new("America/New_York")

    # 01:30 ocorre duas vezes em 2026-11-01: 05:30Z (EDT) e 06:30Z (EST).
    assert_equal utc(2026, 11, 1, 5, 30), zone.parse_local("2026-11-01T01:30")
  end

  def test_historical_brazilian_dst_midnight_gap
    zone = TimeZone.new("America/Sao_Paulo")

    # Em 2018-11-04 o relógio saltou de 00:00 para 01:00; o dia começa às 01:00 local.
    assert_equal utc(2018, 11, 4, 3, 0), zone.start_of_day(Date.new(2018, 11, 4))
    assert_raises(Locentra::Domain::ValidationError) { zone.parse_local("2018-11-04T00:30") }
  end

  def test_calendar_dates_touched_by_period
    zone = TimeZone.new("America/Sao_Paulo")
    span = Locentra::Domain::Period.new(zone.parse_local("2026-03-02T18:00"), zone.parse_local("2026-03-04T09:00"))

    assert_equal [Date.new(2026, 3, 2), Date.new(2026, 3, 3), Date.new(2026, 3, 4)], zone.calendar_dates(span)

    midnight_end = Locentra::Domain::Period.new(zone.parse_local("2026-03-02T08:00"), zone.parse_local("2026-03-03T00:00"))

    assert_equal [Date.new(2026, 3, 2)], zone.calendar_dates(midnight_end)
  end

  def test_rejects_invalid_identifiers_and_dates
    assert_raises(Locentra::Domain::ValidationError) { TimeZone.new("Mars/Olympus") }
    assert_raises(Locentra::Domain::ValidationError) { TimeZone.new("UTC").parse_local("2026-02-30T10:00") }
    assert_raises(Locentra::Domain::ValidationError) { TimeZone.new("UTC").parse_local("amanhã") }
    assert_equal TimeZone.new("UTC"), TimeZone.new("UTC")
  end
end
