# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/webhook_support"
require_relative "../support/portal_support"

# Circuito por endpoint de ponta a ponta: pausa automática só com 20 falhas consecutivas e 1 h desde a
# primeira, auditada como ação do sistema; entregas seguintes e novos despachos retidos sem rede e sem
# tarefa; sucesso zera a sequência, exceto o sucesso em voo depois da pausa, que a conserva até a
# reativação; reativação autorizada, auditada e com liberação em lotes; reenvio de entrega retida com o
# endpoint ainda pausado volta a reter.
class WebhookCircuitTest < DatabaseTest
  include WorkerHelpers
  include WebhookHelpers
  include PortalHelpers

  Circuit = Locentra::Domain::Webhooks::Circuit

  def setup
    super
    @org = create_organization
    worker_system
    drain
    @server = CaptureServer.new(status: 500)
    @endpoint = uc(:create_webhook).call(@org[:actor], url: @server.url("/hook/segredo-do-cliente"), events: ["*"])["id"]
  end

  def teardown
    @server&.stop
    @worker_system&.shutdown
    super
  end

  def received = @server.requests.size

  def test_twenty_failures_pause_only_after_one_hour_and_later_deliveries_are_held
    dispatch_events(@org, Circuit::FAILURE_THRESHOLD, request_id: "req-evento-0001")
    drain

    assert_equal 20, received
    state = endpoint_row(@org, @endpoint)

    assert_equal ["20", nil], state.values_at("consecutive_failures", "paused_at"), "20 falhas em menos de 1 h não pausam"
    @clock.advance(3600)
    drain

    assert_equal 21, received, "a falha seguinte pausa o endpoint e as demais entregas não saem"
    refute_nil endpoint_row(@org, @endpoint)["paused_at"]
    audit = owner_query("SELECT actor_type, request_id, details FROM audit_events WHERE action = 'webhook.endpoint_paused'")

    assert_equal 1, audit.size
    assert_equal %w[system req-evento-0001], audit.first.values_at("actor_type", "request_id")
    details = JSON.parse(audit.first["details"])

    assert_equal [21, 500, "2026-03-02T12:00:00Z"], details.values_at("consecutive_failures", "last_status_code", "failing_since")
    refute_includes audit.first["details"], "segredo-do-cliente"
    held = deliveries_of(@org).count { |row| row["held_at"] }

    assert_equal 19, held
    assert_equal({ %w[webhook_circuit paused] => 1, %w[webhook_delivery failed] => 21, %w[webhook_delivery held] => 19 }, outcome_totals)
    statuses = %w[succeeded pending]

    assert(webhook_jobs.all? { |job| statuses.include?(job["status"]) })
    assert_equal 19, webhook_jobs.count { |job| job["status"] == "succeeded" }, "entregas retidas concluem a tarefa (:endpoint_paused)"
  end

  def test_dispatch_to_a_paused_endpoint_creates_a_held_delivery_without_a_job
    pause_endpoint!(@org, @endpoint)
    before = webhook_jobs.size
    dispatch_events(@org, 2)

    assert_equal before, webhook_jobs.size
    assert(deliveries_of(@org).all? { |row| row["held_at"] && row["status"] == "pending" })
    assert_equal({ %w[webhook_delivery held] => 2 }, outcome_totals)
    drain

    assert_equal 0, received
  end

  def test_success_resets_the_failure_streak
    dispatch_events(@org, 3)
    drain

    assert_equal "3", endpoint_row(@org, @endpoint)["consecutive_failures"]
    @server.status = 200
    @clock.advance(3600)
    drain
    state = endpoint_row(@org, @endpoint)

    assert_equal ["0", nil, nil], state.values_at("consecutive_failures", "failing_since", "paused_at")
    assert_equal(3, deliveries_of(@org).count { |row| row["status"] == "delivered" })
  end

  # Destino que, durante a chamada, vê o endpoint ser pausado por outra tentativa (a falha que fechou o
  # circuito) e responde com sucesso.
  class PausedInFlightHttp
    def initialize(http, &on_post)
      @http = http
      @on_post = on_post
    end

    def post(...)
      @on_post.call
      @http.post(...)
    end
  end

  def test_in_flight_success_after_the_pause_keeps_the_failure_streak_until_resume
    @server.status = 200
    dispatch_events(@org)
    delivery = deliveries_of(@org).first["id"]
    since = @clock.now - 3600
    s = worker_system.services
    http = PausedInFlightHttp.new(s[:http]) { pause_endpoint!(@org, @endpoint, failures: 21, since: since) }
    deliver = A::Webhooks::Deliver.new(transactor: worker_system.transactor, webhooks: worker_system.repos[:webhooks], http: http, box: s[:box],
                                       signer: Locentra::Infrastructure::WebhookSignature, clock: @clock, calls: s[:external_calls],
                                       totals: worker_system.repos[:outcome_totals], audit: s[:audit])

    assert_equal :delivered, deliver.call(@org[:organization_id], delivery)
    row = endpoint_row(@org, @endpoint)
    times = row.values_at("failing_since", "paused_at").map { |value| value && Time.parse(value) }

    assert_equal ["21", since, @clock.now], [row["consecutive_failures"], *times], "a pausa conserva a sequência que a causou"
    listed = uc(:list_webhooks).call(@org[:actor])[:endpoints].first

    assert_equal [21, since], listed.values_at("consecutive_failures", "failing_since")
    uc(:resume_webhook).call(@org[:actor], @endpoint)
    audit = owner_query("SELECT details FROM audit_events WHERE action = 'webhook.endpoint_resumed'").first

    assert_equal 21, JSON.parse(audit["details"])["consecutive_failures"]
    assert_equal ["0", nil, nil], endpoint_row(@org, @endpoint).values_at("consecutive_failures", "failing_since", "paused_at")
  end

  def test_resume_rules_permission_conflicts_and_isolation
    auditor = staff_member(@org, "auditor@alfa.test", "auditor")

    assert_raises(D::AccessDenied) { uc(:resume_webhook).call(auditor, @endpoint) }
    not_paused = assert_raises(D::Conflict) { uc(:resume_webhook).call(@org[:actor], @endpoint) }

    assert_equal "endpoint_not_paused", not_paused.code
    pause_endpoint!(@org, @endpoint)
    other = create_organization(name: "Locadora Beta", email: "dona@beta.test")

    assert_raises(D::NotFound) { uc(:resume_webhook).call(other[:actor], @endpoint) }
    assert_raises(D::ValidationError) { uc(:resume_webhook).call(@org[:actor], "nao-e-uuid") }
    uc(:disable_webhook).call(@org[:actor], @endpoint)
    disabled = assert_raises(D::Conflict) { uc(:resume_webhook).call(@org[:actor], @endpoint) }

    assert_equal "endpoint_disabled", disabled.code
    assert_empty owner_query("SELECT id FROM audit_events WHERE action = 'webhook.endpoint_resumed'")
  end

  def test_resume_is_audited_and_releases_held_deliveries_in_batches
    pause_endpoint!(@org, @endpoint)
    dispatch_events(@org, 5)
    worker_system.services[:release_held_webhooks] =
      A::Webhooks::ReleaseHeld.new(transactor: worker_system.transactor, webhooks: worker_system.repos[:webhooks], queue: worker_system.queue,
                                   totals: worker_system.repos[:outcome_totals], clock: @clock, batch_size: 2)
    @server.status = 200
    result = uc(:resume_webhook).call(@org[:actor], @endpoint)

    assert_equal({ "id" => @endpoint, "held_deliveries" => 5 }, result)
    assert_equal ["0", nil, nil], endpoint_row(@org, @endpoint).values_at("consecutive_failures", "failing_since", "paused_at")
    audit = owner_query("SELECT actor_type, details FROM audit_events WHERE action = 'webhook.endpoint_resumed'").first

    assert_equal "user", audit["actor_type"]
    assert_equal [5, 20], JSON.parse(audit["details"]).values_at("held_deliveries", "consecutive_failures")
    drain

    assert_equal 3, webhook_jobs("webhooks.release_held").size, "lotes de 2, 2 e 1"
    assert_equal 5, received
    assert(deliveries_of(@org).all? { |row| row["status"] == "delivered" && row["held_at"].nil? })
    assert_equal 5, outcome_totals[%w[webhook_delivery released]]
    assert_equal 5, outcome_totals[%w[webhook_delivery delivered]]
  end

  def test_resume_without_held_deliveries_enqueues_no_release
    pause_endpoint!(@org, @endpoint)

    assert_equal 0, uc(:resume_webhook).call(@org[:actor], @endpoint)["held_deliveries"]
    assert_empty webhook_jobs("webhooks.release_held")
  end

  def test_redelivering_a_held_delivery_while_paused_holds_it_again
    pause_endpoint!(@org, @endpoint)
    dispatch_events(@org)
    delivery = deliveries_of(@org).first["id"]

    assert uc(:redeliver_webhook).call(@org[:actor], delivery)
    assert_nil deliveries_of(@org).first["held_at"], "o reenvio limpa a retenção"
    drain

    refute_nil deliveries_of(@org).first["held_at"], "com o endpoint ainda pausado, a tarefa retém a entrega de novo"
    assert_equal 0, received
    assert_equal(["succeeded"], webhook_jobs.map { |job| job["status"] })
  end
end
