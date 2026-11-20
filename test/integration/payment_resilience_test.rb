# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# Falhas e respostas inesperadas do provedor: reexecução do envio, conciliação com listagem
# incompleta, contas substituídas, situação dos estornos e webhooks de outra conta ou cobrança.
class PaymentResilienceTest < DatabaseTest
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

  def system_actor = A::Actor.system(organization_id: @org[:organization_id])
  def simulator = @system.services[:payment_providers].for("simulator")
  def simulator_charges(reference) = count("payment_simulator_charges", "external_reference = $1", [reference])

  def submit_with(provider)
    FN::SubmitPayment.new(uow: @system.uow, payments: @system.repos[:payments], accounts: @system.repos[:payment_accounts],
                          customers: @system.repos[:customers], reservations: @system.repos[:reservations],
                          providers: FN::Providers.new("simulator" => provider), remote: remote_sync, resolver: uc(:resolve_submission),
                          alert_book: alert_book, audit: @system.services[:audit], clock: @clock)
  end

  def reconcile_with(provider)
    FN::Reconcile.new(uow: @system.uow, accounts: @system.repos[:payment_accounts], payments: @system.repos[:payments],
                      reports: @system.repos[:reconciliation], providers: FN::Providers.new("simulator" => provider),
                      resolver: uc(:resolve_submission), remote: remote_sync, audit: @system.services[:audit], clock: @clock, ids: @system.ids)
  end

  def refund_with(provider)
    FN::ProcessRefund.new(uow: @system.uow, payments: @system.repos[:payments], accounts: @system.repos[:payment_accounts],
                          providers: FN::Providers.new("simulator" => provider), queue: @system.queue,
                          ledger: FN::Ledger.new(entries: @system.repos[:ledger_entries], ids: @system.ids, clock: @clock),
                          audit: @system.services[:audit], events: @system.services[:events], clock: @clock)
  end

  # Falha depois de o provedor registrar a cobrança (resposta perdida, erro de rede não classificado,
  # queda do processo): a tarefa é reexecutada pela fila.
  def test_job_reexecution_after_remote_creation_never_charges_twice
    requested = request_online(@rental, 10_000)
    crashing = Failing.new(simulator, create_first: true, error: IOError.new("conexão interrompida"))
    submit = submit_with(crashing)

    assert_raises(IOError) { submit.call(system_actor, requested.id) }
    interrupted = payment(requested.id)

    assert_equal ["submission_unknown", 1, 1], [interrupted.status, interrupted.submission_attempts, simulator_charges(requested.id)],
                 "a tentativa foi gravada antes da chamada de rede"
    assert_equal :resolved, submit.call(system_actor, requested.id), "a reexecução consulta o provedor em vez de reenviar"
    drain
    resolved = payment(requested.id)

    assert_equal ["pending", 1, 1], [resolved.status, resolved.submission_attempts, simulator_charges(requested.id)]
    assert_equal 1, crashing.create_calls
    assert_equal owner_query("SELECT id FROM payment_simulator_charges").first["id"], resolved.provider_payment_id
  end

  # Queda antes de a requisição chegar ao provedor: a ausência só é conclusiva depois da janela.
  def test_reexecution_within_the_window_waits_and_resubmits_once_after_it
    requested = request_online(@rental, 10_000)
    submit = submit_with(Failing.new(simulator, create_first: false, error: IOError.new("processo interrompido")))

    assert_raises(IOError) { submit.call(system_actor, requested.id) }
    assert_equal :awaiting_settlement, submit.call(system_actor, requested.id)
    assert_equal :awaiting_settlement, uc(:resolve_submission).call(system_actor, requested.id)
    assert_equal ["submission_unknown", 0], [payment(requested.id).status, simulator_charges(requested.id)]
    assert_equal 1, count_jobs("kind = 'payments.submit' AND unique_key = $1", ["payment-check:#{requested.id}:1"]), "uma consulta agendada"
    drain

    assert_equal 0, simulator_charges(requested.id), "nada é reenviado dentro da janela"
    @clock.advance(FN::SubmitPayment::RECHECK_DELAY)
    drain
    sent = payment(requested.id)

    assert_equal ["pending", 2, 1], [sent.status, sent.submission_attempts, simulator_charges(requested.id)]
    assert_equal 1, count("audit_events", "action = 'payment.resubmission_scheduled'")
  end

  def test_duplicate_lookup_prefers_the_charge_that_can_still_be_paid
    requested = request_online(@rental, 3_000, scenario: "timeout_after_success")
    drain
    owner_query("UPDATE payment_simulator_charges SET status = 'DELETED' WHERE external_reference = $1", [requested.id])
    owner_query(<<~SQL, [requested.id])
      INSERT INTO payment_simulator_charges (id, organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
                                             due_date, status, created_at, updated_at)
      SELECT 'sim_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
             due_date, 'PENDING', created_at + interval '1 second', updated_at
        FROM payment_simulator_charges WHERE external_reference = $1
    SQL

    assert_equal :resolved, uc(:resolve_submission).call(system_actor, requested.id)
    assert_equal %w[pending sim_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee], payment(requested.id).then { |p| [p.status, p.provider_payment_id] },
                 "a cobrança removida não cancela o pagamento quando há outra ativa"
    assert_match(/sim_e{32} foi associada/, uc(:finance).overview(@actor)[:alerts].first["message"])
  end

  def test_unavailable_provider_returns_payment_to_submission_queue
    requested = request_online(@rental, 10_000)
    unavailable = Failing.new(simulator, create_first: false, error: FN::ProviderUnavailable.new("conexão recusada"))

    assert_raises(FN::ProviderUnavailable) { submit_with(unavailable).call(system_actor, requested.id) }
    assert_equal ["pending_submission", 1, 0], [payment(requested.id).status, payment(requested.id).submission_attempts, simulator_charges(requested.id)]
    assert_equal 1, count("audit_events", "action = 'payment.submission_not_sent'")
    assert_equal :submitted, submit_with(simulator).call(system_actor, requested.id)
    assert_equal [2, 1], [payment(requested.id).submission_attempts, simulator_charges(requested.id)]
  end

  def test_reconciliation_looks_up_unknown_submissions_missing_from_an_incomplete_listing
    unknown = request_online(@rental, 3_000, scenario: "timeout_after_success")
    absent = request_online(@rental, 2_000, scenario: "timeout_after_success")
    pending = request_online(@rental, 1_000)
    drain
    owner_query("DELETE FROM payment_simulator_charges WHERE external_reference = $1", [absent.id])
    truncated = TruncatedListing.new(simulator)
    report = uc(:finance).report(@actor, reconcile_with(truncated).call(@actor))
    items = report[:items].to_h { |i| [i["payment_id"], i.values_at("kind", "action")] }

    assert_equal({ unknown.id => %w[status_mismatch local_updated], absent.id => %w[missing_remote check_scheduled] }, items,
                 "pagamento pendente fora da listagem incompleta não é dado como ausente")
    assert_equal [unknown.id, absent.id].sort, truncated.lookups.sort, "consulta pela referência antes de qualquer decisão"
    assert_equal [false, 3], report[:report]["summary"].values_at("complete", "checked")
    assert_equal(%w[pending submission_unknown pending], [unknown, absent, pending].map { |p| payment(p.id).status })
    assert_equal 1, simulator_charges(unknown.id)
    assert_equal 1, simulator_charges(pending.id)
  end

  def test_reconciliation_covers_open_payments_of_a_replaced_account
    old_payment = request_online(@rental, 4_000)
    drain
    owner_query("UPDATE payment_simulator_charges SET status = 'RECEIVED' WHERE external_reference = $1", [old_payment.id])
    manual = pay(@rental, 1_000)
    replacement = simulator_account
    owner_query(<<~SQL, [@org[:organization_id], replacement["id"], manual.id])
      INSERT INTO payment_simulator_charges (id, organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
                                             due_date, status, created_at, updated_at)
      VALUES ('sim_cccccccccccccccccccccccccccccccc', $1, $2, $3, 'cliente', 'PIX', 1000, '2026-03-05', 'RECEIVED', now(), now())
    SQL
    data = uc(:finance).report(@actor, uc(:reconcile_payments).call(@actor))

    assert_equal([[old_payment.id, "status_mismatch", "local_updated"]], data[:items].map { |i| i.values_at("payment_id", "kind", "action") },
                 "cobrança remota de pagamento conhecido não é 'ausente no Locentra'")
    assert_equal "confirmed", payment(old_payment.id).status, "pagamento da conta substituída conciliado com as credenciais dela"
    assert_equal [1, 0], data[:report]["summary"].values_at("legacy_checked", "legacy_failures")
  end

  def test_lookup_failure_for_replaced_account_does_not_stop_reconciliation
    old_payment = request_online(@rental, 4_000)
    drain
    simulator_account
    revoked = Failing.new(simulator, lookup_error: FN::ProviderRejected.new("credencial revogada"))
    data = uc(:finance).report(@actor, reconcile_with(revoked).call(@actor))

    assert_equal ["completed", 1, 0], [data[:report]["status"], data[:report]["summary"]["legacy_failures"], data[:items].size]
    assert_equal "pending", payment(old_payment.id).status
  end

  def test_invalid_provider_responses_fail_the_report
    { Locentra::Domain::ValidationError.field("valor", "valor com fração de centavo") => /fração de centavo/,
      KeyError.new("key not found: \"id\"") => /KeyError/ }.each do |error, message|
      report = uc(:finance).report(@actor, reconcile_with(Failing.new(simulator, listing_error: error)).call(@actor))[:report]

      assert_equal "failed", report["status"]
      assert_match message, report["error"]
    end
    assert_raises(RuntimeError) { reconcile_with(Failing.new(simulator, listing_error: RuntimeError.new("defeito"))).call(@actor) }
    assert_equal 0, count("reconciliation_reports", "status = 'running'"), "nenhum relatório fica em execução"
  end

  def test_refund_made_directly_at_the_provider_is_a_divergence
    refunded_remotely = confirmed_online(5_000)
    refunded_here = confirmed_online(5_000)
    owner_query("UPDATE payment_simulator_charges SET status = 'REFUNDED' WHERE external_reference = $1", [refunded_remotely.id])
    uc(:request_refund).call(@actor, refunded_here.id, amount: money(5_000), reason: "Devolução combinada")
    drain
    data = uc(:finance).report(@actor, uc(:reconcile_payments).call(@actor))

    assert_equal([[refunded_remotely.id, "status_mismatch", "refunded", "review"]],
                 data[:items].map { |i| i.values_at("payment_id", "kind", "remote_status", "action") })
  end

  def test_provider_refund_status_decides_the_local_refund
    paid = confirmed_online(10_000)
    gateway = RefundStatuses.new(simulator, "pending")
    pending = uc(:request_refund).call(@actor, paid.id, amount: money(4_000), reason: "Estorno aguardando autorização")

    assert_equal :pending, refund_with(gateway).call(system_actor, pending.id)
    assert_equal "pending", refund_status(pending.id), "estorno em andamento não é confirmado"
    assert_equal 1, count_jobs("kind = 'payments.refund' AND run_at > $1", [@clock.now]), "nova consulta agendada"
    assert_equal 0, count("outbox_events", "event_type = 'payment.refunded'")
    gateway.status = "done"

    assert_equal :confirmed, refund_with(gateway).call(system_actor, pending.id)
    assert_equal 1, gateway.refund_calls, "a situação é consultada, o estorno não é pedido de novo"
    cancelled = uc(:request_refund).call(@actor, paid.id, amount: money(3_000), reason: "Estorno cancelado no provedor")
    gateway.status = "cancelled"

    assert_equal :failed, refund_with(gateway).call(system_actor, cancelled.id)
    assert_equal "failed", refund_status(cancelled.id)
    assert_match(/cancelado no provedor/, owner_query("SELECT failure_reason FROM refunds WHERE id = $1", [cancelled.id]).first["failure_reason"])
    assert_equal 6_000, balance_of(@rental).settled.cents, "estorno cancelado não reduz o recebido"
    assert_empty unbalanced_transactions
  end

  def test_cancelled_refund_found_by_description_fails_without_new_request
    paid = confirmed_online(10_000)
    refund = uc(:request_refund).call(@actor, paid.id, amount: money(2_000), reason: "Estorno recusado pelo cliente")
    gateway = RefundStatuses.new(simulator, "cancelled", existing: refund)

    assert_equal :failed, refund_with(gateway).call(system_actor, refund.id)
    assert_equal 0, gateway.refund_calls
  end

  def test_webhook_received_by_another_account_does_not_change_the_payment
    requested = request_online(@rental, 10_000)
    drain
    other = simulator_account
    body = webhook_body(requested.id, "evt_outra_conta", "PAYMENT_RECEIVED", charge: payment(requested.id).provider_payment_id)

    assert_equal :accepted, uc(:ingest_payment_webhook).call(other["id"], token: other["webhook_token"], body: body)
    drain
    stored = owner_query("SELECT status, error FROM inbound_webhooks").first

    assert_equal ["ignored", "pagamento de outra conta do provedor"], stored.values_at("status", "error")
    assert_equal "pending", payment(requested.id).status
    assert_equal 0, count("financial_entries", "source_type = 'payment'")
  end

  def test_payment_through_a_duplicate_charge_is_confirmed_relinked_and_flagged
    requested = request_online(@rental, 10_000)
    drain
    linked = payment(requested.id).provider_payment_id
    duplicate = "sim_#{"d" * 32}"
    ingest(webhook_body(requested.id, "evt_dup_pago", "PAYMENT_RECEIVED", charge: duplicate))
    confirmed = payment(requested.id)

    assert_equal ["confirmed", duplicate, true], [confirmed.status, confirmed.provider_payment_id, confirmed.requires_review]
    assert_match(/duplicada #{duplicate}.*#{linked}/, confirmed.review_reason)
    ingest(webhook_body(requested.id, "evt_original_pago", "PAYMENT_RECEIVED", charge: linked))
    ingest(webhook_body(requested.id, "evt_original_pago_2", "PAYMENT_CONFIRMED", charge: linked))
    alerts = uc(:finance).overview(@actor)[:alerts]

    assert_equal(%w[duplicate_provider_charge duplicate_provider_charge], alerts.map { |a| a["kind"] })
    assert(alerts.any? { |a| a["message"].include?("#{linked} também foi paga") }, "o segundo recebimento fica registrado para decisão")
    assert_equal 1, count("financial_entries", "source_type = 'payment' AND debit_cents > 0"), "o valor recebido duas vezes não é lançado duas vezes"
    assert_equal(%w[ignored ignored processed], owner_query("SELECT status FROM inbound_webhooks ORDER BY status").map { |r| r["status"] })
  end

  def test_provider_deletion_event_cancels_only_through_the_linked_charge
    requested = request_online(@rental, 10_000)
    drain
    charge = payment(requested.id).provider_payment_id
    ingest(webhook_body(requested.id, "evt_outra_removida", "PAYMENT_DELETED", charge: "sim_#{"b" * 32}"))

    assert_equal "pending", payment(requested.id).status, "remoção de outra cobrança com a mesma referência não cancela o pagamento"
    ingest(webhook_body(requested.id, "evt_removida", "PAYMENT_DELETED", charge: charge))
    ingest(webhook_body(requested.id, "evt_vencida", "PAYMENT_OVERDUE", charge: charge))

    assert_equal "cancelled", payment(requested.id).status
    assert_equal 2, count("inbound_webhooks", "status = 'ignored'")
    assert_equal 3, count("inbound_webhooks", "provider_account_id = $1", [@account["id"]]), "eventos guardam a conta que os recebeu"
  end

  def test_receipt_for_a_cancelled_payment_raises_an_alert
    requested = request_online(@rental, 10_000)
    drain
    charge = payment(requested.id).provider_payment_id
    ingest(webhook_body(requested.id, "evt_removida", "PAYMENT_DELETED", charge: charge))
    ingest(webhook_body(requested.id, "evt_restaurada_paga", "PAYMENT_RECEIVED", charge: charge))
    ingest(webhook_body(requested.id, "evt_restaurada_confirmada", "PAYMENT_CONFIRMED", charge: charge))

    assert_equal "cancelled", payment(requested.id).status
    alerts = uc(:finance).overview(@actor)[:alerts]

    assert_equal ["unmatched_provider_receipt"], alerts.map { |a| a["kind"] }, "um alerta por cobrança"
    assert_match(/#{charge} \(R\$ 100,00\).*cancelado/, alerts.first["message"])
    assert_equal requested.id, alerts.first["payment_id"]
  end

  private

  def ingest(body)
    account = owner_query("SELECT id, organization_id, provider FROM payment_provider_accounts WHERE id = $1", [@account["id"]]).first
    uc(:ingest_payment_webhook).accept(account, body)
    drain
  end

  def confirmed_online(cents)
    requested = request_online(@rental, cents)
    drain
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    payment(requested.id)
  end

  def refund_status(id) = owner_query("SELECT status FROM refunds WHERE id = $1", [id]).first["status"]

  def count_jobs(where, params = [])
    PG.connect(TestDatabase.worker_url).then do |conn|
      conn.exec_params("SELECT count(*) AS n FROM jobs WHERE #{where}", params).first["n"].to_i
    ensure
      conn&.close
    end
  end

  def webhook_body(reference, event_id, event, charge:, value: "100.00")
    JSON.generate("id" => event_id, "event" => event, "dateCreated" => "2026-03-02 12:00:00",
                  "payment" => { "id" => charge, "status" => "RECEIVED", "value" => JSON::Fragment.new(value), "externalReference" => reference })
  end

  def remote_sync = @system.services[:payment_remote_sync]
  def alert_book = @system.services[:finance_alert_book]

  # Provedor que falha de forma programada: na criação da cobrança (antes ou depois de registrá-la),
  # na listagem ou na consulta pela referência.
  class Failing
    attr_reader :create_calls

    def initialize(target, error: nil, create_first: false, listing_error: nil, lookup_error: nil)
      @target = target
      @error = error
      @create_first = create_first
      @listing_error = listing_error
      @lookup_error = lookup_error
      @create_calls = 0
    end

    def create_charge(account, request)
      @create_calls += 1
      @target.create_charge(account, request) if @create_first
      raise @error
    end

    def list_charges(...)
      raise @listing_error if @listing_error

      @target.list_charges(...)
    end

    def find_by_external_reference(...)
      raise @lookup_error if @lookup_error

      @target.find_by_external_reference(...)
    end
  end

  # Listagem truncada (limite de páginas atingido) sem nenhuma cobrança.
  class TruncatedListing < SimpleDelegator
    attr_reader :lookups

    def initialize(target)
      super
      @lookups = []
    end

    def list_charges(*, **) = Locentra::Application::Finance::ChargeListing.new(charges: [], complete: false)

    def find_by_external_reference(account, reference)
      @lookups << reference
      __getobj__.find_by_external_reference(account, reference)
    end
  end

  # Estornos com situação programada no provedor.
  class RefundStatuses
    attr_accessor :status
    attr_reader :refund_calls

    def initialize(target, status, existing: nil)
      @target = target
      @status = status
      @refund_calls = 0
      @requested = existing && "Locentra reembolso #{existing.id}"
    end

    def refunds(*) = @requested ? [item(@requested)] : []

    def refund(_account, _charge, amount:, description:)
      @refund_calls += 1
      @requested = description
      item(description, amount)
    end

    private

    def item(description, amount = Locentra::Domain::Money.new(100))
      Locentra::Application::Finance::ProviderRefund.new(reference: "ref_#{status}", description: description, amount: amount, status: status)
    end
  end
end
