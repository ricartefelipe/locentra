# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# Retenção do histórico de integrações por organização: saem somente entregas concluídas antigas, todas
# as entregas antigas de endpoints desativados antes do corte, eventos despachados antigos sem entrega
# restante e webhooks recebidos processados ou ignorados antigos. Ficam entregas recentes, retidas e
# pendentes, eventos com entrega ou não despachados, recebidos `received`/`failed` e tudo de outra
# organização. Lotes limitados, totais globais, reenvio e tarefa de entrega removida, deduplicação dos
# recebidos dentro da janela e a tarefa organization.retention pelo worker.
class RetentionTest < DatabaseTest
  include WorkerHelpers
  include FinanceHelpers

  DAY = 86_400

  def setup
    super
    @org = create_organization
    @other = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    worker_system
    drain
    @old = @clock.now - (40 * DAY)
    @recent = @clock.now - DAY
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def as(org, sql, params = []) = owner_query(sql, params, tenant: org[:organization_id])
  def ids_of(org, table) = as(org, "SELECT id FROM #{table}").map { |row| row["id"] }.sort

  def endpoint(org, disabled_at: nil)
    id = SecureRandom.uuid
    as(org, <<~SQL, [id, org[:organization_id], disabled_at.nil?, @old - DAY, disabled_at])
      INSERT INTO webhook_endpoints (id, organization_id, url, events, secret_ciphertext, active, created_at, disabled_at)
      VALUES ($1, $2, 'https://erp.example/hook', '{*}', 'cifrado', $3, $4, $5)
    SQL
    id
  end

  def event(org, dispatched_at:, occurred_at: @old)
    id = SecureRandom.uuid
    as(org, <<~SQL, [id, org[:organization_id], SecureRandom.uuid, occurred_at, dispatched_at])
      INSERT INTO outbox_events (id, organization_id, event_type, aggregate_type, aggregate_id, occurred_at, dispatched_at)
      VALUES ($1, $2, 'reservation.confirmed', 'reservation', $3, $4, $5)
    SQL
    id
  end

  def delivery(org, endpoint_id, event_id, status, last_attempt_at: nil, held_at: nil, created_at: @old)
    id = SecureRandom.uuid
    as(org, <<~SQL, [id, org[:organization_id], endpoint_id, event_id, status, last_attempt_at ? 1 : 0, created_at, last_attempt_at, held_at])
      INSERT INTO webhook_deliveries (id, organization_id, endpoint_id, event_id, event_type, status, attempts, created_at, last_attempt_at, held_at)
      VALUES ($1, $2, $3, $4, 'reservation.confirmed', $5, $6, $7, $8, $9)
    SQL
    id
  end

  def inbound(org, status, processed_at)
    id = SecureRandom.uuid
    as(org, <<~SQL, [id, org[:organization_id], "evt-#{id}", status, @clock.now - (120 * DAY), processed_at])
      INSERT INTO inbound_webhooks (id, organization_id, provider, event_id, event_type, payload, status, received_at, processed_at)
      VALUES ($1, $2, 'simulator', $3, 'PAYMENT_RECEIVED', '{}', $4, $5, $6)
    SQL
    id
  end

  # Delivered antiga cujo evento fica sem entrega: os dois saem.
  def old_delivered(org, endpoint_id)
    event_id = event(org, dispatched_at: @old)
    [event_id, delivery(org, endpoint_id, event_id, "delivered", last_attempt_at: @old)]
  end

  def scenario
    active = endpoint(@org)
    kept = {}
    gone = {}
    gone[:delivered_event], gone[:delivered] = old_delivered(@org, active)
    failed_event = event(@org, dispatched_at: @old)
    gone[:failed] = delivery(@org, active, failed_event, "failed", last_attempt_at: @old)
    gone[:failed_event] = failed_event
    kept[:recent_event] = event(@org, dispatched_at: @old)
    kept[:recent] = delivery(@org, active, kept[:recent_event], "delivered", last_attempt_at: @recent)
    kept[:pending_event] = event(@org, dispatched_at: @old)
    kept[:pending] = delivery(@org, active, kept[:pending_event], "pending")
    kept[:held_event] = event(@org, dispatched_at: @old)
    kept[:held] = delivery(@org, active, kept[:held_event], "failed", last_attempt_at: @old, held_at: @old)
    gone[:lonely_event] = event(@org, dispatched_at: @old)
    kept[:undispatched_event] = event(@org, dispatched_at: nil)
    kept[:recent_dispatch] = event(@org, dispatched_at: @recent, occurred_at: @recent)
    old_disabled = endpoint(@org, disabled_at: @old)
    gone[:disabled_event] = event(@org, dispatched_at: @old)
    gone[:disabled_pending] = delivery(@org, old_disabled, gone[:disabled_event], "pending")
    recently_disabled = endpoint(@org, disabled_at: @recent)
    kept[:recently_disabled_event] = event(@org, dispatched_at: @old)
    kept[:recently_disabled] = delivery(@org, recently_disabled, kept[:recently_disabled_event], "pending")
    inbound_old = @clock.now - (100 * DAY)
    gone[:processed] = inbound(@org, "processed", inbound_old)
    gone[:ignored] = inbound(@org, "ignored", inbound_old)
    kept[:received] = inbound(@org, "received", nil)
    kept[:failed_inbound] = inbound(@org, "failed", inbound_old)
    kept[:processed_recently] = inbound(@org, "processed", @clock.now - (10 * DAY))
    [kept, gone]
  end

  def other_organization_data
    active = endpoint(@other)
    event_id, delivery_id = old_delivered(@other, active)
    { events: [event_id, event(@other, dispatched_at: @old)].sort, deliveries: [delivery_id], inbound: [inbound(@other, "processed", @old - (90 * DAY))] }
  end

  def snapshot(org) = { events: ids_of(org, "outbox_events"), deliveries: ids_of(org, "webhook_deliveries"), inbound: ids_of(org, "inbound_webhooks") }

  def purge(org = @org, **) = purger(**).call(org[:organization_id])

  def purger(**)
    windows = A::Retention::Windows.new(outbox_seconds: 30 * DAY, deliveries_seconds: 30 * DAY, inbound_seconds: 90 * DAY)
    A::Retention::PurgeHistory.new(transactor: worker_system.transactor, retention: worker_system.repos[:retention],
                                   totals: worker_system.repos[:outcome_totals], clock: @clock, windows: windows, **)
  end

  def totals
    owner_query("SELECT outcome, total FROM worker_outcome_totals WHERE family = 'retention'", tenant: nil).to_h { |r| [r["outcome"], r["total"].to_i] }
  end

  def test_removes_only_what_is_outside_the_window_and_never_touches_another_organization
    other = other_organization_data
    kept, gone = scenario
    before = snapshot(@org)
    removed = purge

    assert_equal({ "webhook_deliveries" => 3, "outbox_events" => 4, "inbound_webhooks" => 2 }, removed)
    after = snapshot(@org)
    all_ids = before.values.flatten

    assert_empty(gone.values & after.values.flatten, "removidos: #{(gone.values & after.values.flatten).inspect}")
    assert_equal kept.values.sort, (kept.values & all_ids).sort
    assert_equal kept.values.sort, (after.values.flatten & kept.values).sort, "mantidos"
    assert_equal other, snapshot(@other), "outra organização intocada"
    assert_equal({ "webhook_deliveries" => 3, "outbox_events" => 4, "inbound_webhooks" => 2 }, totals)
    assert_equal({ "webhook_deliveries" => 0, "outbox_events" => 0, "inbound_webhooks" => 0 }, purge, "nada mais a remover")
  end

  # Sem contexto de organização a RLS esconderia as entregas, e o evento pareceria sem entrega restante:
  # a retenção exige o tenant.
  def test_retention_requires_the_tenant_context
    assert_raises(D::AccessDenied) do
      worker_system.transactor.call { |tx| worker_system.repos[:retention].purge_dispatched_events(tx, before: @clock.now, limit: 10) }
    end
  end

  def test_batches_respect_batch_size_and_max_batches
    active = endpoint(@org)
    5.times { old_delivered(@org, active) }
    first = purge(batch_size: 2, max_batches: 2)

    assert_equal [4, 4], first.values_at("webhook_deliveries", "outbox_events"), "dois lotes de dois por tipo"
    assert_equal [1, 1], [ids_of(@org, "webhook_deliveries").size, ids_of(@org, "outbox_events").size]
    assert_equal [1, 1], purge(batch_size: 2, max_batches: 2).values_at("webhook_deliveries", "outbox_events"), "o restante sai na execução seguinte"
    assert_equal({ "webhook_deliveries" => 5, "outbox_events" => 5 }, totals)
  end

  def test_removed_delivery_cannot_be_redelivered_and_its_job_finishes_as_missing
    _, removed = old_delivered(@org, endpoint(@org))
    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      worker_system.queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => removed }, queue: "webhooks", priority: 40)
    end
    purge

    assert_raises(D::NotFound) { uc(:redeliver_webhook).call(@org[:actor], removed) }
    drain

    assert_equal(["succeeded"], jobs("kind = 'webhooks.deliver'").map { |job| job["status"] })
  end

  def test_the_retention_job_runs_through_the_worker
    old_delivered(@org, endpoint(@org))
    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      worker_system.queue.enqueue(tx, "organization.retention", {}, priority: 95)
    end
    drain

    assert_equal(["succeeded"], jobs("kind = 'organization.retention'").map { |job| job["status"] })
    assert_empty ids_of(@org, "webhook_deliveries")
    assert_empty as(@org, "SELECT id FROM outbox_events WHERE dispatched_at < $1", [@clock.now - (30 * DAY)])
  end

  # Dentro da janela, o reenvio do provedor é reconhecido como duplicado. Depois da remoção (fora da
  # janela), o reenvio é aceito e o processamento é idempotente: o pagamento já confirmado não muda e o
  # webhook fica `ignored`. Por isso a janela mínima cobre a conciliação e o reenvio do provedor.
  def test_inbound_deduplication_holds_inside_the_window_and_processing_is_idempotent_after_it
    finance_setup(@org)
    @account = simulator_account
    reservation = booking
    sync(reservation)
    drain
    requested = request_online(rental_of(reservation), 3_000)
    drain
    uc(:simulate_payment).call(@actor, requested.id)
    drain
    confirmed = payment(requested.id)
    processed = as(@org, "SELECT payload::text AS body FROM inbound_webhooks WHERE status = 'processed'")

    assert_equal ["confirmed", 1], [confirmed.status, processed.size]
    account = as(@org, "SELECT id, organization_id, provider FROM payment_provider_accounts WHERE id = $1", [@account["id"]]).first
    body = processed.first["body"]
    balance = trial_balance

    assert_equal :duplicate, uc(:ingest_payment_webhook).accept(account, body)
    @clock.advance(91 * DAY)

    assert_equal 1, purge["inbound_webhooks"]
    assert_equal :accepted, uc(:ingest_payment_webhook).accept(account, body)
    drain

    assert_equal(["ignored"], as(@org, "SELECT status FROM inbound_webhooks").map { |row| row["status"] })
    assert_equal "confirmed", payment(requested.id).status
    assert_equal balance, trial_balance
  end
end
