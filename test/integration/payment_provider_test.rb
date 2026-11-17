# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# Provedor de pagamentos (simulador persistido), worker, webhooks recebidos e conciliação.
class PaymentProviderTest < DatabaseTest
  include WorkerHelpers
  include FinanceHelpers

  FN = Locentra::Application::Finance

  def setup
    super
    finance_setup
    worker_system
    @account = simulator_account
    @reservation = booking
    sync(@reservation)
    @rental = rental_of(@reservation)
    drain
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def simulator_charges(reference) = count("payment_simulator_charges", "external_reference = $1", [reference])

  def test_submission_success_and_confirmation_by_provider_webhook
    requested = request_online(@rental, 10_000)

    assert_equal "pending_submission", requested.status
    drain
    submitted = payment(requested.id)

    assert_equal "pending", submitted.status
    assert_match(/\Asim_[0-9a-f]{32}\z/, submitted.provider_payment_id)
    assert_equal :accepted, uc(:simulate_payment).call(@actor, requested.id)
    assert_equal 1, count("inbound_webhooks", "status = 'received'"), "evento persistido antes do processamento"
    drain

    assert_equal "confirmed", payment(requested.id).status
    assert_equal "paid", balance_of(@rental).status
    refute payment(requested.id).requires_review
    assert_equal 1, count("inbound_webhooks", "status = 'processed'")
    assert_empty unbalanced_transactions
  end

  def test_timeout_after_success_is_resolved_without_a_second_charge
    requested = request_online(@rental, 10_000, scenario: "timeout_after_success")
    drain

    assert_equal "submission_unknown", payment(requested.id).status
    assert_equal 1, simulator_charges(requested.id), "o simulador registrou a cobrança antes do tempo esgotado"
    @clock.advance(FN::SubmitPayment::RECHECK_DELAY + 1)
    drain
    resolved = payment(requested.id)

    assert_equal "pending", resolved.status
    assert_equal 1, simulator_charges(requested.id), "nenhuma segunda cobrança no provedor"
    assert_equal owner_query("SELECT id FROM payment_simulator_charges").first["id"], resolved.provider_payment_id
    assert_equal 1, count("audit_events", "action = 'payment.submission_resolved'")
  end

  def test_reconciliation_resolves_unknown_submission_before_any_retry
    requested = request_online(@rental, 10_000, scenario: "timeout_after_success")
    drain
    report_id = uc(:reconcile_payments).call(@actor)
    data = uc(:finance).report(@actor, report_id)

    assert_equal "completed", data[:report]["status"]
    assert_equal([%w[status_mismatch local_updated]], data[:items].map { |i| i.values_at("kind", "action") })
    assert_equal "pending", payment(requested.id).status
    @clock.advance(120)
    drain

    assert_equal 1, simulator_charges(requested.id)
    assert_equal "pending", payment(requested.id).status
  end

  def test_unknown_submission_absent_in_provider_is_resubmitted_with_same_reference
    requested = request_online(@rental, 10_000, scenario: "timeout_after_success")
    drain
    owner_query("DELETE FROM payment_simulator_charges")
    @clock.advance(FN::SubmitPayment::RECHECK_DELAY + 1)
    drain

    assert_equal "submission_unknown", payment(requested.id).status, "o reenvio usa o mesmo cenário (tempo esgotado)"
    assert_equal 1, simulator_charges(requested.id)
    assert_equal 1, count("audit_events", "action = 'payment.resubmission_scheduled'")
  end

  def test_duplicate_remote_charges_raise_alert_and_remote_cancellation_is_adopted
    duplicated = request_online(@rental, 3_000, scenario: "timeout_after_success")
    removed = request_online(@rental, 2_000, scenario: "timeout_after_success")
    drain
    owner_query(<<~SQL, [duplicated.id])
      INSERT INTO payment_simulator_charges (id, organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
                                             due_date, status, created_at, updated_at)
      SELECT 'sim_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
             due_date, status, created_at + interval '1 second', updated_at
        FROM payment_simulator_charges WHERE external_reference = $1
    SQL
    owner_query("UPDATE payment_simulator_charges SET status = 'DELETED' WHERE external_reference = $1", [removed.id])
    system_actor = A::Actor.system(organization_id: @org[:organization_id])

    assert_equal :resolved, uc(:resolve_submission).call(system_actor, duplicated.id)
    assert_equal :resolved, uc(:resolve_submission).call(system_actor, removed.id)
    assert_equal :already_pending, uc(:resolve_submission).call(system_actor, duplicated.id)
    assert_equal "pending", payment(duplicated.id).status
    assert_equal "cancelled", payment(removed.id).status
    assert_equal(["duplicate_provider_charge"], uc(:finance).overview(@actor)[:alerts].map { |a| a["kind"] })
  end

  def test_reconciliation_schedules_resubmission_for_unknown_submission_absent_in_provider
    requested = request_online(@rental, 10_000, scenario: "timeout_after_success")
    drain
    owner_query("DELETE FROM payment_simulator_charges")
    data = uc(:finance).report(@actor, uc(:reconcile_payments).call(@actor))

    assert_equal([%w[missing_remote resubmission_scheduled]], data[:items].map { |i| i.values_at("kind", "action") })
    assert_equal "pending_submission", payment(requested.id).status
  end

  def test_submission_after_account_deactivation_fails_and_invalid_jobs_die
    requested = request_online(@rental, 10_000)
    uc(:deactivate_payment_account).call(@actor, @account["id"])
    drain
    failed = payment(requested.id)

    assert_equal "failed", failed.status
    assert_match(/desativada/, failed.failure_reason)
    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      worker_system.queue.enqueue(tx, "payments.submit", { "payment_id" => SecureRandom.uuid })
      worker_system.queue.enqueue(tx, "finance.sync_reservation", { "reservation_id" => "nao-e-uuid" })
    end
    drain

    assert_equal 2, count("jobs", "status = 'dead' AND kind IN ('payments.submit', 'finance.sync_reservation')")
  end

  def test_only_simulated_charges_can_be_simulated
    manual = pay(@rental, 1_000)

    assert_raises(D::Conflict) { uc(:simulate_payment).call(@actor, manual.id) }
    assert_raises(D::NotFound) { uc(:simulate_payment).call(@actor, SecureRandom.uuid) }
  end

  def test_rejected_submission_fails_payment
    requested = request_online(@rental, 10_000, scenario: "fail")
    drain
    failed = payment(requested.id)

    assert_equal "failed", failed.status
    assert_match(/recusada/, failed.failure_reason)
    assert_equal 0, simulator_charges(requested.id)
    assert_equal "open", balance_of(@rental).status
  end

  def test_repeated_webhooks_do_not_duplicate_effects
    requested = request_online(@rental, 10_000)
    drain

    assert_equal :accepted, uc(:simulate_payment).call(@actor, requested.id)
    assert_equal :duplicate, uc(:simulate_payment).call(@actor, requested.id)
    confirmed = webhook_body(requested.id, "evt_outro_1", "PAYMENT_CONFIRMED")

    assert_equal :accepted, uc(:ingest_payment_webhook).accept(account_row, confirmed)
    drain
    statuses = owner_query("SELECT status FROM inbound_webhooks ORDER BY status").map { |r| r["status"] }

    assert_equal %w[ignored processed], statuses, "o segundo evento de pagamento encontra o pagamento já confirmado"
    assert_equal 1, count("financial_entries", "source_type = 'payment' AND debit_cents > 0")
    assert_equal 1, count("outbox_events", "event_type = 'payment.confirmed'")
    processed = owner_query("SELECT id FROM inbound_webhooks WHERE status = 'processed'").first["id"]

    assert_equal :already_processed, uc(:process_payment_webhook).call(A::Actor.system(organization_id: @org[:organization_id]), processed)
  end

  def test_payment_after_hold_expiration_does_not_reactivate_reservation
    hold = booking(mode: "hold", day: 20, hold_minutes: 30)
    rental = sync(hold, prepayment: true).first
    requested = request_online(rental, 10_000)
    drain
    @clock.advance(31 * 60)
    uc(:expire_holds).call(A::Actor.system(organization_id: @org[:organization_id]))
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    confirmed = payment(requested.id)

    assert_equal "confirmed", confirmed.status, "o dinheiro é confirmado"
    assert confirmed.requires_review
    assert_match(/expiração/, confirmed.review_reason)
    assert_equal "expired", uc(:get_reservation).call(@actor, hold.id)[:reservation].status
    assert_equal 0, count("stock_allocations", "reservation_id = $1 AND active", [hold.id])
    alert = uc(:finance).reservation(@actor, hold.id)[:alerts].map { |a| a["kind"] }

    assert_includes alert, "payment_after_expiration"
  end

  def test_public_webhook_requires_the_account_token
    token = @account["webhook_token"]
    body = webhook_body(SecureRandom.uuid, "evt_publico_1", "PAYMENT_RECEIVED")
    ingest = uc(:ingest_payment_webhook)

    assert_raises(FN::WebhookUnauthorized) { ingest.call(@account["id"], token: "whk_errado", body: body) }
    assert_raises(FN::WebhookUnauthorized) { ingest.call(SecureRandom.uuid, token: token, body: body) }
    assert_raises(FN::WebhookUnauthorized) { ingest.call("nao-e-uuid", token: token, body: body) }
    assert_equal :accepted, ingest.call(@account["id"], token: token, body: body)
    assert_equal :duplicate, ingest.call(@account["id"], token: token, body: body)
    assert_raises(D::ValidationError) { ingest.call(@account["id"], token: token, body: "{}") }
    drain

    assert_equal "ignored", owner_query("SELECT status FROM inbound_webhooks").first["status"], "evento sem pagamento conhecido"
    uc(:deactivate_payment_account).call(@actor, @account["id"])

    assert_raises(FN::WebhookUnauthorized) { ingest.call(@account["id"], token: token, body: webhook_body(SecureRandom.uuid, "evt_2", "PAYMENT_RECEIVED")) }
  end

  def test_webhook_with_divergent_amount_confirms_and_flags_review
    requested = request_online(@rental, 10_000)
    drain
    uc(:ingest_payment_webhook).accept(account_row, webhook_body(requested.id, "evt_valor", "PAYMENT_RECEIVED", value: "90.00"))
    drain
    confirmed = payment(requested.id)

    assert_equal "confirmed", confirmed.status
    assert_match(/difere/, confirmed.review_reason)
  end

  def test_provider_deletion_event_cancels_pending_payment
    requested = request_online(@rental, 10_000)
    drain
    uc(:ingest_payment_webhook).accept(account_row, webhook_body(requested.id, "evt_removida", "PAYMENT_DELETED"))
    uc(:ingest_payment_webhook).accept(account_row, webhook_body(requested.id, "evt_vencida", "PAYMENT_OVERDUE"))
    drain

    assert_equal "cancelled", payment(requested.id).status
    assert_equal 1, count("inbound_webhooks", "status = 'ignored'")
  end

  def test_reconciliation_reports_discrepancies
    missing = request_online(@rental, 2_000)
    divergent = request_online(@rental, 3_000)
    paid_remotely = request_online(@rental, 4_000)
    drain
    owner_query("DELETE FROM payment_simulator_charges WHERE external_reference = $1", [missing.id])
    owner_query("UPDATE payment_simulator_charges SET value_cents = 3500 WHERE external_reference = $1", [divergent.id])
    owner_query("UPDATE payment_simulator_charges SET status = 'RECEIVED' WHERE external_reference = $1", [paid_remotely.id])
    owner_query(<<~SQL, [@org[:organization_id], @account["id"]])
      INSERT INTO payment_simulator_charges (id, organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
                                             due_date, status, created_at, updated_at)
      VALUES ('sim_ffffffffffffffffffffffffffffffff', $1, $2, 'referencia-externa', 'cliente', 'PIX', 999, '2026-03-05', 'PENDING', now(), now())
    SQL
    report_id = uc(:reconcile_payments).call(@actor)
    data = uc(:finance).report(@actor, report_id)
    kinds = data[:items].map { |i| [i["kind"], i["action"]] }.sort

    assert_equal [%w[amount_mismatch review], %w[missing_local review], %w[missing_remote review], %w[status_mismatch local_updated]], kinds
    assert_equal 4, data[:report]["summary"]["discrepancies"]
    assert_equal "confirmed", payment(paid_remotely.id).status, "webhook perdido é compensado pela conciliação"
  end

  def test_reconciliation_without_account_and_with_provider_failure
    uc(:deactivate_payment_account).call(@actor, @account["id"])

    assert_equal :no_account, uc(:reconcile_payments).call(@actor)
    simulator_account
    failing = Class.new do
      def list_charges(*) = raise(Locentra::Application::Finance::ProviderUnavailable, "fora do ar")
    end.new
    reconcile = FN::Reconcile.new(uow: @system.uow, accounts: @system.repos[:payment_accounts], payments: @system.repos[:payments],
                                  reports: @system.repos[:reconciliation], providers: FN::Providers.new("simulator" => failing),
                                  resolver: uc(:resolve_submission), remote: nil, audit: @system.services[:audit], clock: @clock, ids: @system.ids)
    report = uc(:finance).report(@actor, reconcile.call(@actor))[:report]

    assert_equal ["failed", "fora do ar"], report.values_at("status", "error")
  end

  def test_provider_refund_is_not_repeated_after_timeout
    requested = request_online(@rental, 10_000)
    drain
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    refund = uc(:request_refund).call(@actor, requested.id, amount: money(4_000), reason: "Item devolvido antes do prazo")

    assert_equal "pending", refund.status
    flaky = FlakyRefunds.new(worker_system.services[:payment_providers].for("simulator"))
    processor = FN::ProcessRefund.new(uow: worker_system.uow, payments: worker_system.repos[:payments], accounts: worker_system.repos[:payment_accounts],
                                      providers: FN::Providers.new("simulator" => flaky), ledger: ledger_for(worker_system),
                                      audit: worker_system.services[:audit], events: worker_system.services[:events], clock: @clock)
    system_actor = A::Actor.system(organization_id: @org[:organization_id])

    assert_raises(FN::ProviderTimeout) { processor.call(system_actor, refund.id) }
    assert_equal :confirmed, processor.call(system_actor, refund.id)
    assert_equal 1, flaky.refund_calls
    refunds = owner_query("SELECT refunds FROM payment_simulator_charges").first["refunds"]

    assert_equal 1, JSON.parse(refunds).size, "o estorno não foi repetido"
    assert_equal :already_confirmed, processor.call(system_actor, refund.id)
    assert_equal 6_000, payment_settled
    assert_empty unbalanced_transactions
  end

  def test_provider_refund_through_worker_and_rejection
    requested = request_online(@rental, 10_000)
    drain
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    uc(:request_refund).call(@actor, requested.id, amount: money(10_000), reason: "Cancelamento com reembolso")
    drain

    assert_equal "confirmed", owner_query("SELECT status FROM refunds").first["status"]
    assert_equal "REFUNDED", owner_query("SELECT status FROM payment_simulator_charges").first["status"]
    rejecting = Class.new do
      def refunds(*) = []
      def refund(*, **) = raise(Locentra::Application::Finance::ProviderRejected, "estorno negado")
    end.new
    second = booking(day: 22).tap { |r| sync(r) }
    paid = request_online(rental_of(second), 10_000)
    drain
    uc(:simulate_payment).call(@actor, paid.id)
    drain
    refund = uc(:request_refund).call(@actor, paid.id, amount: money(1_000), reason: "Teste de recusa")
    processor = FN::ProcessRefund.new(uow: @system.uow, payments: @system.repos[:payments], accounts: @system.repos[:payment_accounts],
                                      providers: FN::Providers.new("simulator" => rejecting), ledger: ledger_for(@system),
                                      audit: @system.services[:audit], events: @system.services[:events], clock: @clock)

    assert_equal :failed, processor.call(@actor, refund.id)
    assert_equal 0, balance_of(rental_of(second)).outstanding.cents, "reembolso recusado é estornado no diário e no saldo"
    assert_empty unbalanced_transactions
  end

  def test_reservation_events_schedule_charge_synchronization_through_the_worker
    reservation = booking(day: 25)
    drain

    assert_operator count("jobs", "kind = 'finance.sync_reservation' AND status = 'succeeded'"), :>=, 1
    assert_equal(["rental"], charges(reservation).map { |row| row[:receivable].kind })
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-27T08:00:00Z"))
    drain

    assert_equal %w[extension rental], charges(reservation).map { |row| row[:receivable].kind }.sort
  end

  def test_organization_tick_schedules_hourly_reconciliation
    job = Locentra::Infrastructure::Jobs::Queue::Claimed.new(id: SecureRandom.uuid, organization_id: @org[:organization_id], kind: "organization.tick",
                                                             payload: { "bucket" => "2026-03-02T12:00:00Z" }, attempts: 1, max_attempts: 10,
                                                             lease_token: SecureRandom.uuid, correlation_id: nil)
    handlers = Locentra::Interfaces::Worker::Handlers.new(worker_system, mailer: @mailer, templates: worker_system.services[:mail_templates])

    assert handlers.call(job)["reconciliation_scheduled"]
    handlers.call(job.with(payload: { "bucket" => "2026-03-02T12:01:00Z" }))

    assert_equal 1, count("jobs", "kind = 'finance.reconcile'"), "uma conciliação por hora"
    drain

    assert_equal 1, count("reconciliation_reports", "status = 'completed'")
  end

  def test_provider_account_configuration_rules
    asaas = uc(:configure_payment_account).call(@actor, provider: "asaas", name: "Asaas sandbox", api_key: "$aact_hmlg_chave-de-teste-1234",
                                                        environment: "sandbox")
    stored = owner_query("SELECT api_key_ciphertext, webhook_token_digest, active FROM payment_provider_accounts WHERE id = $1", [asaas["id"]]).first

    refute_includes stored["api_key_ciphertext"], "chave-de-teste"
    assert_equal FN::TokenCheck.digest(asaas["webhook_token"]), stored["webhook_token_digest"]
    assert_equal 1, count("payment_provider_accounts", "active"), "a conta anterior foi desativada"
    assert_raises(D::ValidationError) { uc(:configure_payment_account).call(@actor, provider: "asaas", name: "Sem chave") }
    assert_raises(D::ValidationError) do
      uc(:configure_payment_account).call(@actor, provider: "asaas", name: "Ambiente errado", api_key: "$aact_prod_x", environment: "sandbox")
    end
    assert_raises(D::ValidationError) { uc(:configure_payment_account).call(@actor, provider: "pagseguro", name: "Outro") }
    assert_raises(D::NotFound) { uc(:deactivate_payment_account).call(@actor, @account["id"]) }
    small = create_organization(name: "Pequena", email: "pequena@example.test", plan: "essencial")

    assert_raises(D::PlanLimitExceeded) { simulator_account(small[:actor]) }
    assert_equal 2, uc(:finance).accounts(@actor).size
  end

  private

  def account_row = owner_query("SELECT id, organization_id, provider FROM payment_provider_accounts WHERE id = $1", [@account["id"]]).first

  def webhook_body(reference, event_id, event, value: "100.00")
    JSON.generate("id" => event_id, "event" => event, "dateCreated" => "2026-03-02 12:00:00",
                  "payment" => { "id" => "sim_#{"a" * 32}", "status" => "RECEIVED", "value" => JSON::Fragment.new(value), "externalReference" => reference })
  end

  def ledger_for(system)
    FN::Ledger.new(entries: system.repos[:ledger_entries], ids: system.ids, clock: @clock)
  end

  def payment_settled = balance_of(@rental).settled.cents

  # Provedor cujo primeiro estorno é registrado e em seguida falha por tempo esgotado.
  class FlakyRefunds
    attr_reader :refund_calls

    def initialize(target)
      @target = target
      @refund_calls = 0
    end

    def refunds(...) = @target.refunds(...)

    def refund(...)
      @refund_calls += 1
      @target.refund(...)
      raise Locentra::Application::Finance::ProviderTimeout, "sem resposta após o estorno" if @refund_calls == 1
    end
  end
end
