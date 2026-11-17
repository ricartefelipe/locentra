# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"
require_relative "../support/finance_support"

# Reembolsos concorrentes acima do saldo elegível, em conexões separadas sincronizadas por barreiras.
class RefundRaceTest < DatabaseTest
  include FinanceHelpers

  FN = Locentra::Application::Finance

  def setup
    super
    finance_setup
    reservation = booking
    sync(reservation)
    @payment = pay(rental_of(reservation), 10_000)
  end

  def refund_use_case(payments_repository)
    FN::RequestRefund.new(uow: @system.uow, payments: payments_repository, queue: @system.queue, events: @system.services[:events],
                          ledger: FN::Ledger.new(entries: @system.repos[:ledger_entries], ids: @system.ids, clock: @clock),
                          audit: @system.services[:audit], clock: @clock, ids: @system.ids)
  end

  # Todas as threads abrem a transação e chegam juntas ao lock do pagamento.
  def race(use_case, parties, cents)
    results = Queue.new
    threads = Array.new(parties) do |index|
      Thread.new do
        use_case.call(@actor, @payment.id, amount: money(cents), reason: "Reembolso concorrente #{index + 1}")
        results << :ok
      rescue D::Conflict => e
        results << e.code.to_sym
      rescue D::ValidationError
        results << :rejected_by_database
      end
    end
    threads.each(&:join)
    Array.new(parties) { results.pop }
  end

  def refunded_cents = owner_query("SELECT COALESCE(sum(amount_cents), 0) AS n FROM refunds").first["n"].to_i

  def test_two_concurrent_refunds_above_eligible_balance
    barrier = Barrier.new(2)
    outcomes = race(refund_use_case(PausingProxy.new(@system.repos[:payments], :lock, barrier)), 2, 6_000)

    assert_equal %i[ok refund_exceeds_eligible], outcomes.sort
    assert_equal 6_000, refunded_cents
    assert_empty unbalanced_transactions
  end

  def test_three_concurrent_refunds_never_exceed_confirmed_amount
    barrier = Barrier.new(3)
    outcomes = race(refund_use_case(PausingProxy.new(@system.repos[:payments], :lock, barrier)), 3, 4_000)

    assert_equal %i[ok ok refund_exceeds_eligible], outcomes.sort
    assert_equal 8_000, refunded_cents
    assert_equal 2_000, uc(:finance).payment(@actor, @payment.id)[:eligible].cents
  end

  # Mesmo com a soma lida de forma desatualizada (sem a verificação da aplicação), o trigger do
  # banco bloqueia o pagamento e recusa o reembolso que excederia o valor confirmado.
  def test_database_trigger_rejects_excess_even_with_stale_sum
    barrier = Barrier.new(2)
    stale = StaleCommitted.new(@system.repos[:payments])
    outcomes = race(refund_use_case(PausingProxy.new(stale, :lock, barrier)), 2, 6_000)

    assert_equal %i[ok rejected_by_database], outcomes.sort
    assert_equal 6_000, refunded_cents
  end

  # Repositório que informa zero reembolsos comprometidos (leitura desatualizada simulada).
  class StaleCommitted < SimpleDelegator
    def committed_refunds(*) = Locentra::Domain::Money.zero
  end
end
