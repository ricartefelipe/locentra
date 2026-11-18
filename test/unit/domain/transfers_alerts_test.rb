# frozen_string_literal: true

require_relative "../unit_helper"

class TransfersAlertsTest < UnitTest
  T = Locentra::Domain::Transfers
  AL = Locentra::Domain::Alerts
  R = Locentra::Domain::Reservations
  Money = Locentra::Domain::Money

  def now = t("2026-03-09T10:00:00Z")

  def transfer(**extra)
    T::Transfer.build(id: "t1", organization_id: "o1", code: "TR-000001", product_id: "p1", from_branch_id: "b1", to_branch_id: "b2",
                      requested_at: now, asset_id: "a1", **extra)
  end

  def test_transfer_state_machine
    requested = transfer(notes: "  reforço  ")

    assert_predicate requested, :active?
    assert_equal ["Solicitada", "reforço", 1], [requested.status_label, requested.notes, requested.quantity]
    assert_raises(Locentra::Domain::InvalidTransition) { requested.receive(now) }
    in_transit = requested.dispatch(now)

    assert_equal ["in_transit", now], [in_transit.status, in_transit.dispatched_at]
    assert_raises(Locentra::Domain::InvalidTransition) { in_transit.cancel("tarde", now) }
    received = in_transit.receive(now, to_pool_id: "pool2")

    assert_equal ["received", "pool2", 3], [received.status, received.to_pool_id, received.version]
    refute_predicate received, :active?
    assert_raises(Locentra::Domain::ValidationError) { requested.cancel("", now) }
    assert_equal "cancelled", requested.cancel("desistência", now).status
  end

  def test_transfer_validation
    assert_raises(Locentra::Domain::ValidationError) { transfer(to_branch_id: "b1") }
    assert_raises(ArgumentError) { transfer(asset_id: nil) }
    assert_raises(Locentra::Domain::ValidationError) { transfer(asset_id: nil, from_pool_id: "pool", quantity: 0) }
    assert_raises(Locentra::Domain::ValidationError) { transfer(asset_id: nil, from_pool_id: "pool", quantity: 100_001) }
    stock = transfer(asset_id: nil, from_pool_id: "pool", quantity: 7)

    refute_predicate stock, :asset?
    assert_equal 7, stock.quantity
  end

  def test_alert_resolution_and_keys
    alert = AL::Alert.new(id: "al1", reservation_id: "r1", kind: "overdue", related_reservation_id: nil, asset_id: nil, stock_pool_id: nil,
                          status: "open", details: {}, created_at: now, resolved_at: nil, resolution: nil)

    assert_predicate alert, :open?
    assert_equal "Devolução em atraso", alert.kind_label
    assert_raises(Locentra::Domain::ValidationError) { alert.resolve("ok", now) }
    resolved = alert.resolve("Cliente avisado", now)

    assert_equal ["resolved", "Cliente avisado", now], [resolved.status, resolved.resolution, resolved.resolved_at]
    assert_raises(Locentra::Domain::InvalidTransition) { resolved.resolve("de novo", now) }
    assert_equal "overdue:r1:#{now.to_i}", AL::Keys.overdue("r1", now)
    assert_equal "affected:r2:r1:a1", AL::Keys.affected("r2", "r1", "a1")
    assert_equal "unavailable:r2:a1:ret", AL::Keys.unavailable("r2", "a1", "ret")
  end

  def test_overdue_starts_at_scheduled_end
    reservation = R::Reservation.new(id: "r1", organization_id: "o1", branch_id: "b1", customer_id: "c1", code: "R-1", status: "in_progress",
                                     source: "staff", period: period("2026-03-08T10:00:00Z", "2026-03-09T10:00:00Z"), hold_expires_at: nil,
                                     quote_id: nil, notes: nil, total: Money.zero, deposit: Money.zero, version: 1)

    assert AL::Overdue.overdue?(reservation, now)
    refute AL::Overdue.overdue?(reservation, now - 1)
    refute AL::Overdue.overdue?(reservation.with(status: "completed"), now + 3600)
  end

  def test_stock_shortfall_identifies_reservations_in_uncovered_segments
    window = period("2026-03-10T00:00:00Z", "2026-03-20T00:00:00Z")
    occupancies = [
      { reservation_id: "early", period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), quantity: 4 },
      { reservation_id: "peak", period: period("2026-03-12T08:00:00Z", "2026-03-13T08:00:00Z"), quantity: 6 },
      { reservation_id: "overlap", period: period("2026-03-12T20:00:00Z", "2026-03-14T08:00:00Z"), quantity: 2 },
      { reservation_id: nil, period: period("2026-03-15T00:00:00Z", "2026-03-16T00:00:00Z"), quantity: 9 },
      { reservation_id: "outside", period: period("2026-03-25T00:00:00Z", "2026-03-26T00:00:00Z"), quantity: 50 }
    ]

    assert_empty AL::StockShortfall.affected(capacity: 10, occupancies: occupancies, window: window)
    assert_equal %w[peak overlap], AL::StockShortfall.affected(capacity: 10, outstanding: 3, occupancies: occupancies, window: window)
    assert_equal %w[early peak overlap], AL::StockShortfall.affected(capacity: 10, outstanding: 7, occupancies: occupancies, window: window)
    assert_empty AL::StockShortfall.affected(capacity: 0, outstanding: 0, occupancies: [], window: window)
  end
end
