# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"
require_relative "../support/commercial_terms_support"

# Disputas reais pelo uso de cupons e pelo cadastro de condições, em conexões separadas sincronizadas
# por barreiras. O limite vale sob a trava do cupom (contagem depois da trava); cancelamento,
# expiração e alocador não tocam em cupons, portanto não há ciclo de travas com a criação de reservas.
class CouponRedemptionRaceTest < DatabaseTest
  include CommercialTermsSupport

  R = Locentra::Application::Reservations
  AV = Locentra::Application::Availability
  CT = Locentra::Application::CommercialTerms

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customers = [create_customer(@actor, name: "Cliente Um"), create_customer(@actor, name: "Cliente Dois", document: "11144477735")]
    @chairs = create_product(@actor, sku: "CAD-RACE", tracking: "bulk", pricing: { "daily_cents" => 10_000 })
    stock(@actor, @chairs, @branch, 20)
  end

  def services = @system.services
  def repos = @system.repos
  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))

  def retries
    %w[TRDeadlockDetected TRSerializationFailure].sum { |reason| @system.metrics.counter_value("db_transaction_retries_total", reason: reason).to_i }
  end

  def book(customer = @customers.first, day: 10, mode: "confirm", **)
    reserve(@actor, customer, @branch, window(day), [line(@chairs, 1)], mode: mode, **)
  end

  # CreateReservation montado como na composição, com o repositório de precificação decorado.
  def create_use_case(pricing)
    R::CreateReservation.new(uow: @system.uow, reservations: repos[:reservations], customers: repos[:customers],
                             organizations: repos[:organizations], allocator: services[:allocator],
                             pricer: R::Pricer.new(pricing: pricing, ids: @system.ids), audit: services[:audit], events: services[:events],
                             clock: @clock, ids: @system.ids)
  end

  def input(customer, code, day: 10)
    { customer_id: customer.id, branch_id: @branch.id, period: window(day), lines: [line(@chairs, 1)], mode: "confirm", coupon_code: code }
  end

  # Executa o bloco numa thread e devolve [resultado, detalhe], sem deixar a exceção escapar.
  def attempt
    Thread.new do
      [:ok, yield]
    rescue D::ValidationError => e
      [:validation, e.errors]
    rescue D::Conflict => e
      [:conflict, e.code]
    rescue D::Error => e
      [:error, e]
    end
  end

  def test_two_redemptions_compete_for_the_last_use
    coupon = create_coupon("ULTIMO", max_redemptions: 2)
    book(coupon_code: "ULTIMO")
    create = create_use_case(PausingProxy.new(repos[:pricing], :find_coupon, Barrier.new(2)))

    outcomes = @customers.map { |customer| attempt { create.call(@actor, input(customer, "ULTIMO", day: 12)).id } }.map(&:value)

    assert_equal %i[ok validation], outcomes.map(&:first).sort
    assert_equal({ "cupom" => ["cupom esgotado"] }, outcomes.find { |kind, _| kind == :validation }.last)
    assert_equal(["2 de 2", 2], coupon_data(coupon.id)[:coupon].then { |c| [c.usage_text, c.total_redemptions] })
    assert_equal 2, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i, "a reserva recusada é desfeita por inteiro"
    assert_equal 0, retries
  end

  # A criação trava o cupom e depois o estoque; a confirmação de outra reserva trava o estoque e expira
  # em lote o bloqueio vencido que usou o mesmo cupom. Como a expiração não grava no cupom, as duas
  # transações terminam sem impasse nem nova tentativa.
  def test_creation_with_coupon_and_allocator_expiring_a_hold_of_the_same_coupon_do_not_deadlock
    coupon = create_coupon("CICLO")
    hold = book(mode: "hold", hold_minutes: 10, coupon_code: "CICLO")
    requested = book(@customers.last, mode: "request")
    @clock.advance(600)
    barrier = Barrier.new(2)
    create = create_use_case(PausingProxy.new(repos[:pricing], :find_coupon, barrier, after: true))
    allocator = AV::Allocator.new(repository: PausingProxy.new(repos[:availability], :lock_pools, barrier, after: true), ids: @system.ids,
                                  expiry: services[:hold_expiry])
    confirm = R::ConfirmReservation.new(uow: @system.uow, reservations: repos[:reservations], allocator: allocator, audit: services[:audit],
                                        events: services[:events], clock: @clock, guard: services[:reservation_guard],
                                        expiry: services[:hold_expiry])

    creation = attempt { create.call(@actor, input(@customers.first, "CICLO")).status }
    confirmation = attempt { confirm.call(@actor, requested.id).status }

    assert_equal [[:ok, "confirmed"], [:ok, "confirmed"]], [creation.value, confirmation.value]
    assert_equal 0, retries, "nenhuma transação foi repetida por impasse"
    assert_equal "expired", status_of(hold)
    assert_equal ["1 (sem limite)", %w[active released_expired]], [usage(coupon.id), redemptions_of(coupon.id).map { |use| use[:state] }]
    assert_equal(["allocation"], audit_events("reservation.expired").map { |event| event["details"]["trigger"] })
  end

  # O cancelamento grava a nova situação e ainda não confirmou quando o resgate conta os usos sob a
  # trava do cupom: o uso continua ativo para quem conta (conservador) e o resgate é recusado.
  def test_redemption_concurrent_with_an_unconfirmed_cancellation_is_refused
    coupon = create_coupon("UNICO", max_redemptions: 1)
    first = book(coupon_code: "UNICO")
    updated = Barrier.new(2)
    counted = Barrier.new(2)
    reservations = PausingProxy.new(PausingProxy.new(repos[:reservations], :update_status, updated, after: true), :release_allocations, counted)
    cancel = R::CancelReservation.new(uow: @system.uow, reservations: reservations, audit: services[:audit], events: services[:events],
                                      clock: @clock, guard: services[:reservation_guard])
    pricing = PausingProxy.new(PausingProxy.new(repos[:pricing], :find_coupon, updated), :find_coupon, counted, after: true)
    create = create_use_case(pricing)

    cancellation = attempt { cancel.call(@actor, first.id, reason: "Cliente desistiu").status }
    redemption = attempt { create.call(@actor, input(@customers.last, "UNICO", day: 12)).id }

    assert_equal [:ok, "cancelled"], cancellation.value
    assert_equal [:validation, { "cupom" => ["cupom esgotado"] }], redemption.value
    assert_equal "0 de 1", usage(coupon.id)
    third = book(@customers.last, day: 12, coupon_code: "UNICO")

    assert_equal ["confirmed", "1 de 1"], [third.status, usage(coupon.id)], "depois do cancelamento confirmado o uso está livre"
    assert_equal 0, retries
  end

  def test_maximum_cannot_be_reduced_below_a_use_being_redeemed
    coupon = create_coupon("REDUZ", max_redemptions: 3)
    book(coupon_code: "REDUZ")
    barrier = Barrier.new(2)
    create = create_use_case(PausingProxy.new(repos[:pricing], :find_coupon, barrier, after: true))
    update = CT::UpdateCoupon.new(uow: @system.uow, coupons: PausingProxy.new(repos[:coupons], :lock, barrier), audit: services[:audit], clock: @clock)

    redemption = attempt { create.call(@actor, input(@customers.last, "REDUZ", day: 12)).status }
    reduction = attempt { update.call(@actor, coupon.id, { max_redemptions: 1 }).record.max_redemptions }

    assert_equal [:ok, "confirmed"], redemption.value
    assert_equal [:validation, { "maximo_usos" => ["não pode ser menor que os usos ativos (2)"] }], reduction.value
    assert_equal(["2 de 3", 1], coupon_data(coupon.id)[:coupon].then { |c| [c.usage_text, c.lock_version] })
    assert_equal 0, retries
  end

  # As duas criações passam pela verificação prévia (nenhuma vê a outra); a exclusion constraint do
  # banco aceita uma só.
  def test_simultaneous_overlapping_general_agreements_create_only_one
    barrier = Barrier.new(2)
    create = CT::CreatePriceAgreement.new(uow: @system.uow, agreements: PausingProxy.new(repos[:price_agreements], :overlapping?, barrier, after: true),
                                          customers: repos[:customers], catalog: repos[:catalog], audit: services[:audit], clock: @clock,
                                          ids: @system.ids)

    outcomes = [800, 1_200].map { |bps| attempt { create.call(@actor, @customers.first.id, { discount_bps: bps }).discount_bps } }.map(&:value)

    assert_equal %i[conflict ok], outcomes.map(&:first).sort
    assert_equal "price_agreement_overlap", outcomes.find { |kind, _| kind == :conflict }.last
    created = uc(:list_price_agreements).call(@actor, @customers.first.id)

    assert_equal [1, outcomes.find { |kind, _| kind == :ok }.last], [created.total, created.items.first[:agreement].discount_bps]
    assert_equal 1, audit_events("price_agreement.created").size
  end
end
