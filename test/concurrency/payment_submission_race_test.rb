# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"
require_relative "../support/finance_support"

# Duas tarefas 'payments.submit' do mesmo pagamento enquanto a primeira ainda está na chamada de
# rede (consulta agendada, reexecução após lease vencido, conciliação). Barreiras param a primeira
# tentativa dentro do provedor; nenhum sleep é usado.
class PaymentSubmissionRaceTest < DatabaseTest
  include FinanceHelpers

  FN = Locentra::Application::Finance

  def setup
    super
    finance_setup
    simulator_account
    reservation = booking
    sync(reservation)
    @requested = request_online(rental_of(reservation), 10_000)
    @entered = Barrier.new(2)
    @release = Barrier.new(2)
  end

  def system_actor = A::Actor.system(organization_id: @org[:organization_id])
  def simulator = @system.services[:payment_providers].for("simulator")
  def remote_charges = count("payment_simulator_charges", "external_reference = $1", [@requested.id])

  def submit_with(provider)
    FN::SubmitPayment.new(uow: @system.uow, payments: @system.repos[:payments], accounts: @system.repos[:payment_accounts],
                          customers: @system.repos[:customers], reservations: @system.repos[:reservations],
                          providers: FN::Providers.new("simulator" => provider), remote: @system.services[:payment_remote_sync],
                          resolver: uc(:resolve_submission), alert_book: @system.services[:finance_alert_book], audit: @system.services[:audit],
                          clock: @clock)
  end

  # A primeira tentativa fica parada dentro do provedor até a liberação.
  def in_flight
    gated = Gated.new(simulator, @entered, @release)
    Thread.new { submit_with(gated).call(system_actor, @requested.id) }.tap { @entered.wait }
  end

  def test_second_job_during_the_network_call_does_not_resend
    first = in_flight
    second = submit_with(simulator).call(system_actor, @requested.id)

    assert_equal :awaiting_settlement, second, "a tentativa em andamento não é tida como ausente"
    assert_equal 0, remote_charges
    @release.wait

    assert_equal :submitted, first.value
    assert_equal [1, "pending", 1], [remote_charges, payment(@requested.id).status, payment(@requested.id).submission_attempts]
    assert_empty uc(:finance).overview(@actor)[:alerts]
  end

  # Tentativa que ultrapassa a janela: a consulta conclui ausência e um novo envio é feito; quando a
  # tentativa antiga enfim cria a cobrança, a duplicidade é sinalizada para cancelamento no provedor.
  def test_attempt_outliving_the_window_is_flagged_as_duplicate
    first = in_flight
    @clock.advance(Locentra::Domain::Finance::SUBMISSION_WINDOW_SECONDS)

    assert_equal :resubmission_scheduled, uc(:resolve_submission).call(system_actor, @requested.id)
    assert_equal :submitted, submit_with(simulator).call(system_actor, @requested.id)
    @release.wait

    assert_equal :already_pending, first.value
    assert_equal 2, remote_charges
    alert = uc(:finance).overview(@actor)[:alerts].first

    assert_equal "duplicate_provider_charge", alert["kind"]
    assert_match(/cancele-a no provedor/, alert["message"])
  end

  # Provedor que, na primeira chamada, avisa a entrada e espera a liberação antes de criar a cobrança.
  class Gated
    def initialize(target, entered, release)
      @target = target
      @entered = entered
      @release = release
      @calls = 0
      @mutex = Thread::Mutex.new
    end

    def create_charge(account, request)
      if @mutex.synchronize { (@calls += 1) == 1 }
        @entered.wait
        @release.wait
      end
      @target.create_charge(account, request)
    end
  end
end
