# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# Revisão de pagamentos que chegam depois do prazo do bloqueio temporário.
class PaymentReviewTest < DatabaseTest
  include WorkerHelpers
  include FinanceHelpers

  def setup
    super
    finance_setup
    worker_system
    @account = simulator_account
    drain
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  # Pix pago segundos depois do vencimento do bloqueio, antes da varredura: o pagamento já sai em
  # revisão com alerta, pelo webhook do provedor e pelo registro manual.
  def test_payment_after_hold_expiration_is_flagged_before_the_sweeper_runs
    hold = booking(mode: "hold", day: 21, hold_minutes: 30)
    rental = sync(hold, prepayment: true).first
    requested = request_online(rental, 5_000)
    drain
    @clock.advance(31 * 60)
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    by_provider = payment(requested.id)
    manual = pay(rental, 1_000)

    assert_equal "held", uc(:get_reservation).call(@actor, hold.id)[:reservation].status, "a varredura ainda não passou"
    assert(by_provider.requires_review && manual.requires_review)
    assert_match(/expiração/, by_provider.review_reason)
    kinds = uc(:finance).reservation(@actor, hold.id)[:alerts].map { |a| [a["kind"], a["payment_id"]] }

    assert_includes kinds, ["payment_after_expiration", requested.id]
    assert_includes kinds, ["payment_after_expiration", manual.id]
  end
end
