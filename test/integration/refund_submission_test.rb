# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# Estorno no provedor com tempo esgotado: a tentativa é gravada antes da chamada, e dentro da janela
# nada é reenviado, mesmo que o provedor ainda não mostre o estorno pedido.
class RefundSubmissionTest < DatabaseTest
  include WorkerHelpers
  include FinanceHelpers

  FN = Locentra::Application::Finance

  # Provedor que recebe o pedido de estorno, responde com tempo esgotado e só registra o estorno
  # quando `persist!` é chamado (processamento atrasado). Conta os pedidos de estorno enviados.
  class LateRefunds
    attr_reader :refund_calls

    def initialize(target, error: FN::ProviderTimeout.new("sem resposta do provedor"))
      @target = target
      @error = error
      @refund_calls = 0
      @queued = []
    end

    def refunds(...) = @target.refunds(...)

    def refund(*args, **kwargs)
      @refund_calls += 1
      @queued << [args, kwargs]
      raise @error
    end

    def persist! = @queued.shift.then { |args, kwargs| @target.refund(*args, **kwargs) }
    def forget! = @queued.clear
  end

  def setup
    super
    finance_setup
    worker_system
    @account = simulator_account
    @rental = rental_of(booking.tap { |r| sync(r) })
    drain
    requested = request_online(@rental, 10_000)
    drain
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    @payment_id = requested.id
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def system_actor = A::Actor.system(organization_id: @org[:organization_id])
  def simulator_refunds = JSON.parse(owner_query("SELECT refunds FROM payment_simulator_charges").first["refunds"]).size
  def refund_row(id) = owner_query("SELECT status, submission_attempts FROM refunds WHERE id = $1", [id]).first

  def ledger_for(system) = FN::Ledger.new(entries: system.repos[:ledger_entries], ids: system.ids, clock: @clock)

  def count_jobs(where, params = [])
    PG.connect(TestDatabase.worker_url).then do |conn|
      conn.exec_params("SELECT count(*) AS n FROM jobs WHERE #{where}", params).first["n"].to_i
    ensure
      conn&.close
    end
  end

  def processor(gateway)
    FN::ProcessRefund.new(uow: worker_system.uow, payments: worker_system.repos[:payments], accounts: worker_system.repos[:payment_accounts],
                          providers: FN::Providers.new("simulator" => gateway), ledger: ledger_for(worker_system), queue: worker_system.queue,
                          audit: worker_system.services[:audit], events: worker_system.services[:events], clock: @clock)
  end

  def test_refund_that_shows_up_late_is_not_requested_twice
    refund = uc(:request_refund).call(@actor, @payment_id, amount: money(4_000), reason: "Item devolvido antes do prazo")
    gateway = LateRefunds.new(worker_system.services[:payment_providers].for("simulator"))
    process = processor(gateway)

    assert_equal :awaiting_settlement, process.call(system_actor, refund.id)
    assert_equal({ "status" => "pending", "submission_attempts" => "1" }, refund_row(refund.id).transform_values(&:to_s))
    assert_equal :awaiting_settlement, process.call(system_actor, refund.id), "nova execução dentro da janela (fila ou outro worker)"
    assert_equal 1, gateway.refund_calls, "nada é reenviado enquanto o pedido anterior pode estar em processamento"
    assert_equal 1, count_jobs("kind = 'payments.refund' AND unique_key = $1", ["refund-submission-check:#{refund.id}:1"])
    gateway.persist!
    @clock.advance(FN::ProcessRefund::RECHECK_DELAY)

    assert_equal :confirmed, process.call(system_actor, refund.id)
    assert_equal [1, 1], [gateway.refund_calls, simulator_refunds]
    assert_empty unbalanced_transactions
  end

  def test_refund_lost_by_the_provider_is_requested_again_only_after_the_window
    refund = uc(:request_refund).call(@actor, @payment_id, amount: money(3_000), reason: "Estorno sem resposta do provedor")
    gateway = LateRefunds.new(worker_system.services[:payment_providers].for("simulator"))

    assert_equal :awaiting_settlement, processor(gateway).call(system_actor, refund.id)
    gateway.forget!
    @clock.advance(Locentra::Domain::Finance::SUBMISSION_WINDOW_SECONDS - 1)

    assert_equal :awaiting_settlement, processor(gateway).call(system_actor, refund.id)
    assert_equal 1, gateway.refund_calls
    @clock.advance(1)

    assert_equal :confirmed, processor(worker_system.services[:payment_providers].for("simulator")).call(system_actor, refund.id)
    assert_equal [2, 1], [refund_row(refund.id)["submission_attempts"].to_i, simulator_refunds]
  end

  def test_refused_connection_releases_the_attempt_for_the_queue_retry
    refund = uc(:request_refund).call(@actor, @payment_id, amount: money(2_000), reason: "Provedor fora do ar")
    gateway = LateRefunds.new(worker_system.services[:payment_providers].for("simulator"), error: FN::ProviderUnavailable.new("conexão recusada"))

    assert_raises(FN::ProviderUnavailable) { processor(gateway).call(system_actor, refund.id) }
    gateway.forget!

    assert_equal :confirmed, processor(worker_system.services[:payment_providers].for("simulator")).call(system_actor, refund.id),
                 "sem janela de espera: o pedido não saiu"
    assert_equal 1, simulator_refunds
  end
end
