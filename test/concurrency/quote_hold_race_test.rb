# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"

# Bloqueio do envio alterado por outra transação enquanto o orçamento é rejeitado ou convertido. A
# decisão sobre o bloqueio é tomada na linha bloqueada (FOR UPDATE): quem chega depois vê o
# resultado já gravado, em vez de agir sobre uma leitura anterior.
class QuoteHoldRaceTest < DatabaseTest
  R = Locentra::Application::Reservations
  Q = Locentra::Application::Quotes

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    customer = create_customer(@actor)
    camera = create_product(@actor, sku: "CAM-HOLD", tracking: "serialized", pricing: { "daily_cents" => 8_000 })
    register_assets(@actor, camera, @branch, 1)
    @quote = uc(:create_quote).call(@actor, { customer_id: customer.id, branch_id: @branch.id, lines: [line(camera, 1)],
                                              period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), valid_until: t("2026-03-06T00:00:00Z"),
                                              hold_policy: "hold_on_send", hold_minutes: 60 })
    @hold_id = uc(:send_quote).call(@actor, @quote.id).hold_reservation_id
  end

  def services = @system.services
  def system_actor = A::Actor.system(organization_id: @org[:organization_id])

  # A outra transação grava a nova situação do bloqueio e espera na barreira antes de confirmar.
  def paused_after_status_update(barrier)
    PausingProxy.new(@system.repos[:reservations], :update_status, barrier, after: true)
  end

  # O caso de uso do orçamento espera na mesma barreira imediatamente antes de bloquear a reserva.
  def hold_release(barrier)
    Q::HoldRelease.new(reservations: PausingProxy.new(@system.repos[:reservations], :lock, barrier), cancel: uc(:cancel_reservation))
  end

  def audit_count(action) = owner_query("SELECT count(*) AS n FROM audit_events WHERE action = $1", [action]).first["n"].to_i

  def test_rejection_keeps_a_hold_expired_by_a_concurrent_sweep
    @clock.advance(3600)
    barrier = Barrier.new(2)
    paused = paused_after_status_update(barrier)
    expiry = R::HoldExpiry.new(reservations: paused, audit: services[:audit], events: services[:events])
    sweep = R::ExpireHolds.new(uow: @system.uow, reservations: paused, expiry: expiry, clock: @clock)
    reject = Q::RejectQuote.new(uow: @system.uow, quotes: @system.repos[:quotes], hold_release: hold_release(barrier), audit: services[:audit],
                                events: services[:events], clock: @clock)

    sweeper = Thread.new { sweep.call(system_actor) }
    rejection = Thread.new { reject.call(@actor, @quote.id, reason: "Cliente desistiu").status }

    assert_equal [@hold_id], sweeper.value
    assert_equal "rejected", rejection.value
    assert_equal "expired", uc(:get_reservation).call(@actor, @hold_id)[:reservation].status
    assert_equal 0, audit_count("reservation.cancelled"), "o bloqueio expirado não é cancelado de novo"
  end

  def test_conversion_creates_a_new_reservation_when_the_hold_is_cancelled_concurrently
    uc(:approve_quote).call(@actor, @quote.id, version: 1, approver_name: "Comprador")
    barrier = Barrier.new(2)
    cancel = R::CancelReservation.new(uow: @system.uow, reservations: paused_after_status_update(barrier), audit: services[:audit],
                                      events: services[:events], clock: @clock, guard: services[:reservation_guard])
    convert = Q::ConvertQuote.new(uow: @system.uow, quotes: @system.repos[:quotes],
                                  reservations: PausingProxy.new(@system.repos[:reservations], :lock, barrier),
                                  create_reservation: uc(:create_reservation), confirm_reservation: uc(:confirm_reservation),
                                  audit: services[:audit], events: services[:events], clock: @clock)

    cancellation = Thread.new { cancel.call(@actor, @hold_id, reason: "Liberar a data").status }
    conversion = Thread.new { convert.call(@actor, @quote.id) }

    assert_equal "cancelled", cancellation.value
    result = conversion.value

    assert result.created
    refute_equal @hold_id, result.reservation.id
    assert_equal ["confirmed", @quote.id], [result.reservation.status, result.reservation.quote_id]
    assert_equal "converted", uc(:get_quote).call(@actor, @quote.id)[:quote].status
    assert_equal 1, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE active").first["n"].to_i
  end
end
