# frozen_string_literal: true

require_relative "../unit_helper"

# Instrumentação da camada de aplicação com portas falsas: chamadas externas com correlação,
# contagem de conflitos na unidade de trabalho e coleta de métricas agregadas da fila.
class ApplicationObservabilityTest < UnitTest
  A = Locentra::Application
  FN = Locentra::Application::Finance

  class FakeLogger
    attr_reader :entries

    def initialize = @entries = []
    def info(fields) = @entries << [:info, fields]
    def warn(fields) = @entries << [:warn, fields]
  end

  class FakeMetrics
    attr_reader :counters, :observations, :gauges, :totals

    def initialize
      @counters = Hash.new(0)
      @observations = []
      @gauges = {}
      @totals = {}
    end

    def increment(name, by = 1, **labels) = @counters[[name, labels]] += by
    def observe(name, value, **labels) = @observations << [name, value, labels]
    def set_counter(name, value, **labels) = @totals[[name, labels]] = value
    def replace_gauges(name, series) = @gauges[name] = series
    def gauge(name, value, **labels) = @gauges[name] = [[value, labels]]
  end

  class FakeTransactor
    def initialize(error: nil, result: nil)
      @error = error
      @result = result
    end

    def call(**)
      raise @error if @error

      yield(:tx)
    end
  end

  def calls = @calls ||= A::ExternalCalls.new(logger: logger, metrics: metrics)
  def logger = @logger ||= FakeLogger.new
  def metrics = @metrics ||= FakeMetrics.new
  def actor = A::Actor.system(organization_id: "org-1", request_id: "req-origem-0001")

  def test_call_duration_comes_from_the_injected_clock
    ticks = [10.0, 10.25]
    clock = Object.new
    clock.define_singleton_method(:monotonic) { ticks.shift }
    A::ExternalCalls.new(logger: logger, metrics: metrics, clock: clock)
                    .track(service: "webhook", operation: "deliver", organization_id: "org-1", correlation_id: nil) { :ok }

    assert_in_delta 250.0, logger.entries.last[1][:duration_ms]
    assert_equal [["external_call_duration_seconds", 0.25, { provider: "webhook", kind: "deliver" }]], metrics.observations
  end

  def test_successful_call_logs_correlation_and_low_cardinality_metrics
    result = calls.track(service: "simulator", operation: "create_charge", organization_id: "org-1", correlation_id: "req-origem-0001",
                         details: { reference: "pagamento-1" }) { :cobranca }

    assert_equal :cobranca, result
    level, entry = logger.entries.last

    assert_equal :info, level
    assert_equal %w[external.call simulator create_charge ok org-1 req-origem-0001 pagamento-1],
                 entry.values_at(:event, :service, :operation, :outcome, :organization_id, :correlation_id, :reference)
    assert_equal 1, metrics.counters[["external_calls_total", { provider: "simulator", kind: "create_charge", outcome: "ok" }]]
    assert_equal([["external_call_duration_seconds", { provider: "simulator", kind: "create_charge" }]],
                 metrics.observations.map { |name, _, labels| [name, labels] })
  end

  def test_results_and_errors_are_classified_and_errors_propagate
    outcome = ->(status) { status == 200 ? "ok" : "http_5xx" }
    calls.track(service: "webhook", operation: "deliver", organization_id: "o", correlation_id: nil, outcome: outcome) { 503 }

    assert_equal [:warn, "http_5xx"], [logger.entries.last.first, logger.entries.last.last[:outcome]]
    error = assert_raises(FN::ProviderTimeout) do
      calls.track(service: "asaas", operation: "refund", organization_id: "o", correlation_id: "c", errors: { FN::ProviderError => "timeout" }) do
        raise FN::ProviderTimeout, "tempo esgotado"
      end
    end

    assert_equal "tempo esgotado", error.message
    assert_equal ["timeout", "Locentra::Application::Finance::ProviderTimeout: tempo esgotado"], logger.entries.last.last.values_at(:outcome, :error)
    assert_raises(KeyError) { calls.track(service: "asaas", operation: "refund", organization_id: "o", correlation_id: "c") { raise KeyError } }
    assert_equal "error", logger.entries.last.last[:outcome]
    assert_equal 1, metrics.counters[["external_calls_total", { provider: "asaas", kind: "refund", outcome: "error" }]]
  end

  def test_providers_track_network_calls_only_with_actor_and_map_provider_errors
    adapter = Object.new
    def adapter.create_charge(_account, request) = "cobranca-#{request.external_reference}"
    def adapter.find_by_external_reference(_account, _reference) = raise(FN::ProviderUnavailable, "fora do ar")
    def adapter.list_charges(_account, since:) = [since]
    def adapter.refunds(_account, _id) = []
    def adapter.refund(_account, _id, amount:, description:) = raise(FN::ProviderRejected, "#{amount} #{description}")
    def adapter.parse_webhook(body) = "evento #{body}"
    providers = FN::Providers.new({ "simulator" => adapter }, calls)
    request = FN::ChargeRequest.new(external_reference: "ref-1", amount: nil, payment_method: "pix", due_on: nil, description: "x", customer: nil,
                                    scenario: nil)

    assert_same adapter, providers.for("simulator"), "sem ator não há registro (ex.: interpretação de webhook)"
    tracked = providers.for("simulator", actor: actor)

    assert_equal "cobranca-ref-1", tracked.create_charge({}, request)
    assert_equal [:t0], tracked.list_charges({}, since: :t0)
    assert_empty tracked.refunds({}, "sim_1")
    assert_equal "evento {}", tracked.parse_webhook("{}")
    assert_raises(FN::ProviderUnavailable) { tracked.find_by_external_reference({}, "ref-1") }
    assert_raises(FN::ProviderRejected) { tracked.refund({}, "sim_1", amount: 1, description: "d") }
    outcomes = logger.entries.map { |_, entry| entry.values_at(:operation, :outcome, :correlation_id) }

    assert_equal [%w[create_charge ok req-origem-0001], %w[list_charges ok req-origem-0001], %w[refunds ok req-origem-0001],
                  %w[find_by_external_reference unavailable req-origem-0001], %w[refund rejected req-origem-0001]], outcomes
    assert_raises(Domain::ValidationError) { providers.for("asaas", actor: actor) }
  end

  def test_unit_of_work_counts_conflicts_that_end_the_operation
    access = Object.new
    def access.active_membership(*) = { "id" => "m1", "role" => "owner" }
    user = A::Actor.user(user_id: "u1", organization_id: "o1", role: "owner")
    unavailable = Domain::Unavailable.new([{ "product_id" => "p" }])
    uow = A::UnitOfWork.new(transactor: FakeTransactor.new, access: access, clock: TestClock.new, metrics: metrics)

    assert_raises(Domain::Unavailable) { uow.run(user, "reservations.write") { raise unavailable } }
    assert_raises(Domain::HoldExpired) { uow.run(user) { raise Domain::HoldExpired } }
    assert_raises(Domain::Conflict) { uow.anonymous { raise Domain::Conflict.new("duplicado", code: "duplicate:users_email_key") } }
    assert_raises(Domain::ValidationError) { uow.run(user) { raise Domain::ValidationError.field("x", "inválido") } }
    assert_raises(Domain::InvalidTransition) { uow.run(user, "reservations.write") { raise Domain::InvalidTransition.new("reserva", "cancelled", "confirmed") } }
    assert_raises(Domain::InvalidTransition) { uow.anonymous { raise Domain::InvalidTransition.new("convite", "accepted", "accepted") } }
    concurrent = A::UnitOfWork.new(transactor: FakeTransactor.new(error: Domain::Conflict.new("concorrente", code: "concurrent_update")),
                                   access: access, clock: TestClock.new, metrics: metrics)

    assert_raises(Domain::Conflict) { concurrent.run(user) { :nunca } }
    assert_equal({ "unavailable" => 1, "hold_expired" => 1, "duplicate:users_email_key" => 1, "invalid_transition" => 2, "concurrent_update" => 1 },
                 metrics.counters.filter_map { |(name, labels), value| [labels[:code], value] if name == "domain_conflicts_total" }.to_h)
    assert_equal :ok, A::UnitOfWork.new(transactor: FakeTransactor.new, access: access, clock: TestClock.new).run(user) { :ok }
  end

  def test_collect_metrics_publishes_queue_snapshot_staleness_and_outcome_totals
    clock = TestClock.new(Time.utc(2026, 3, 2, 12, 0, 30))
    stats = [{ "queue" => "default", "status" => "pending", "size" => 3, "oldest_age" => 12.34, "updated_at" => Time.utc(2026, 3, 2, 12) },
             { "queue" => "default", "status" => "dead", "size" => 1, "oldest_age" => 0, "updated_at" => Time.utc(2026, 3, 2, 12) }]
    totals = [{ "queue" => "default", "kind" => "payments.submit", "outcome" => "retry", "total" => 5 },
              { "queue" => "default", "kind" => "webhooks.deliver", "outcome" => "dead", "total" => 2 },
              { "queue" => "default", "kind" => "webhooks.deliver", "outcome" => "desconhecido", "total" => 9 }]
    reports = Object.new
    reports.define_singleton_method(:queue_stats) { |_tx, _now| stats }
    reports.define_singleton_method(:job_outcome_totals) { |_tx| totals }
    reports.define_singleton_method(:worker_outcome_totals) { |_tx| [] }
    collect = A::Reports::CollectMetrics.new(transactor: FakeTransactor.new, reports: reports, metrics: metrics, clock: clock)

    assert collect.call
    assert_equal [[3, { queue: "default", status: "pending" }], [1, { queue: "default", status: "dead" }]], metrics.gauges["jobs_queue_size"]
    assert_equal [12.3, 0.0], metrics.gauges["jobs_oldest_age_seconds"].map(&:first)
    assert_equal [[30.0, {}]], metrics.gauges["jobs_queue_stats_age_seconds"]
    assert_equal({ ["jobs_retries_total", { queue: "default", kind: "payments.submit" }] => 5,
                   ["jobs_dead_total", { queue: "default", kind: "webhooks.deliver" }] => 2 }, metrics.totals)
    stats.clear

    assert collect.call
    assert_empty metrics.gauges["jobs_queue_stats_age_seconds"], "sem agregados gravados não há idade a informar"
    assert_equal [[1, {}]], metrics.gauges["metrics_collect_success"]
    refute A::Reports::CollectMetrics.new(transactor: FakeTransactor.new(error: RuntimeError.new("sem banco")), reports: reports, metrics: metrics,
                                          clock: clock, logger: logger).call
    assert_equal [[0, {}]], metrics.gauges["metrics_collect_success"], "falha visível na própria série"
    assert_equal "metrics.collect_failed", logger.entries.last[1][:event]
  end

  # Totais gravados pelo worker: entregas de webhook por desfecho, pausas de endpoints (sem rótulo) e
  # registros removidos pela retenção por tipo. Família desconhecida é ignorada.
  def test_collect_metrics_publishes_worker_outcome_totals_with_their_labels
    outcomes = [{ "family" => "retention", "outcome" => "jobs", "total" => 7 }, { "family" => "retention", "outcome" => "outbox_events", "total" => 3 },
                { "family" => "webhook_circuit", "outcome" => "paused", "total" => 1 },
                { "family" => "webhook_delivery", "outcome" => "delivered", "total" => 40 },
                { "family" => "webhook_delivery", "outcome" => "held", "total" => 2 },
                { "family" => "desconhecida", "outcome" => "x", "total" => 9 }]
    reports = Object.new
    reports.define_singleton_method(:queue_stats) { |_tx, _now| [] }
    reports.define_singleton_method(:job_outcome_totals) { |_tx| [] }
    reports.define_singleton_method(:worker_outcome_totals) { |_tx| outcomes }

    assert A::Reports::CollectMetrics.new(transactor: FakeTransactor.new, reports: reports, metrics: metrics, clock: TestClock.new).call
    assert_equal({ ["retention_purged_total", { kind: "jobs" }] => 7, ["retention_purged_total", { kind: "outbox_events" }] => 3,
                   ["webhook_endpoint_pauses_total", {}] => 1, ["webhook_deliveries_total", { outcome: "delivered" }] => 40,
                   ["webhook_deliveries_total", { outcome: "held" }] => 2 }, metrics.totals)
  end
end
