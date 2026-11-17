# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"

# Disputas reais entre transações em conexões separadas, sincronizadas por barreiras.
class ReservationRaceTest < DatabaseTest
  R = Locentra::Application::Reservations
  AV = Locentra::Application::Availability

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customers = [create_customer(@actor, name: "Cliente Um"), create_customer(@actor, name: "Cliente Dois", document: "11144477735")]
    @window = period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z")
  end

  def create_use_case(availability_repository)
    allocator = AV::Allocator.new(repository: availability_repository, ids: @system.ids)
    R::CreateReservation.new(uow: @system.uow, reservations: @system.repos[:reservations], customers: @system.repos[:customers],
                             organizations: @system.repos[:organizations], allocator: allocator, pricer: @system.services[:pricer],
                             audit: @system.services[:audit], events: @system.services[:events], clock: @clock, ids: @system.ids)
  end

  def race(use_case, product)
    results = Queue.new
    threads = @customers.map do |customer|
      Thread.new do
        reservation = use_case.call(@actor, { customer_id: customer.id, branch_id: @branch.id, period: @window,
                                              lines: [line(product, product.bulk? ? 3 : 1)], mode: "confirm" })
        results << [:ok, reservation.id]
      rescue D::Unavailable => e
        results << [:unavailable, e]
      end
    end
    threads.each(&:join)
    Array.new(2) { results.pop }
  end

  def test_two_customers_competing_for_the_last_asset
    camera = create_product(@actor, sku: "CAM-ULTIMA", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    barrier = Barrier.new(2)
    repository = PausingProxy.new(@system.repos[:availability], :insert_asset_allocation, barrier)

    outcomes = race(create_use_case(repository), camera)

    assert_equal %i[ok unavailable], outcomes.map(&:first).sort
    assert_equal 1, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE active").first["n"].to_i
    assert_equal 1, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i, "a reserva perdedora é desfeita por inteiro"
  end

  def test_concurrent_bulk_allocations_never_exceed_capacity
    chairs = create_product(@actor, sku: "CAD-CONC", tracking: "bulk")
    stock(@actor, chairs, @branch, 5)
    barrier = Barrier.new(2)
    repository = PausingProxy.new(@system.repos[:availability], :lock_pools, barrier)

    outcomes = race(create_use_case(repository), chairs)

    assert_equal %i[ok unavailable], outcomes.map(&:first).sort
    assert_equal 3, owner_query("SELECT COALESCE(sum(quantity), 0) AS n FROM stock_allocations WHERE active").first["n"].to_i
  end

  def test_last_asset_with_two_units_lets_both_succeed_without_sharing
    camera = create_product(@actor, sku: "CAM-DUAS", tracking: "serialized")
    register_assets(@actor, camera, @branch, 2)
    barrier = Barrier.new(2)
    repository = PausingProxy.new(@system.repos[:availability], :insert_asset_allocation, barrier)

    outcomes = race(create_use_case(repository), camera)

    assert_equal %i[ok ok], outcomes.map(&:first)
    assert_equal 2, owner_query("SELECT count(DISTINCT asset_id) AS n FROM asset_allocations WHERE active").first["n"].to_i
  end

  def confirm_use_case(reservations_repository)
    R::ConfirmReservation.new(uow: @system.uow, reservations: reservations_repository, allocator: @system.services[:allocator],
                              audit: @system.services[:audit], events: @system.services[:events], clock: @clock,
                              guard: @system.services[:reservation_guard])
  end

  def concurrent_confirm_and_sweep(hold)
    locked = Barrier.new(2)
    swept = Barrier.new(2)
    repo = PausingProxy.new(@system.repos[:reservations], :lock, locked, after: true)
    confirm = confirm_use_case(PausingProxy.new(repo, :update_status, swept))
    confirmation = Thread.new do
      confirm.call(@actor, hold.id).status
    rescue D::HoldExpired
      "hold_expired"
    end
    sweeper = Thread.new do
      locked.wait
      expired = uc(:expire_holds).call(A::Actor.system(organization_id: @org[:organization_id]))
      swept.wait
      expired
    end
    [confirmation.value, sweeper.value]
  end

  def test_confirmation_before_expiry_wins_against_concurrent_sweeper
    camera = create_product(@actor, sku: "CAM-CONF", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    hold = reserve(@actor, @customers.first, @branch, @window, [line(camera, 1)], hold_minutes: 10)
    @clock.advance(599)

    confirmation, swept = concurrent_confirm_and_sweep(hold)

    assert_equal "confirmed", confirmation
    assert_empty swept
    assert_equal "confirmed", uc(:get_reservation).call(@actor, hold.id)[:reservation].status
  end

  def test_confirmation_at_expiry_instant_loses_deterministically
    camera = create_product(@actor, sku: "CAM-EXPI", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    hold = reserve(@actor, @customers.first, @branch, @window, [line(camera, 1)], hold_minutes: 10)
    @clock.advance(600)

    confirmation, swept = concurrent_confirm_and_sweep(hold)

    assert_equal "hold_expired", confirmation
    assert_empty swept, "a reserva em uso pela confirmação é ignorada pela varredura (SKIP LOCKED)"
    assert_equal "expired", uc(:get_reservation).call(@actor, hold.id)[:reservation].status
    assert_equal 1, owner_query("SELECT count(*) AS n FROM audit_events WHERE action = 'reservation.expired'").first["n"].to_i
  end
end
