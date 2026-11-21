# frozen_string_literal: true

require_relative "../unit_helper"

# Circuito por endpoint com portas falsas: retenção sem rede quando o endpoint está pausado, tentativa
# normal quando a reativação chegou antes da retenção, pausa única e auditada sem URL ao atingir o
# limite, nada muda no circuito quando a tentativa não foi gravada e liberação em lotes reagendada.
class WebhooksCircuitUseCasesTest < UnitTest
  A = Locentra::Application
  NOW = Time.utc(2026, 3, 2, 14)
  FAILING_SINCE = Time.utc(2026, 3, 2, 12)

  # Repositório falso: registra as chamadas e devolve o valor configurado (ou o bloco) por método;
  # `args_of` devolve os argumentos da primeira chamada, sem a transação.
  class FakeWebhooks
    attr_reader :calls

    def initialize(answers)
      @answers = answers
      @calls = []
    end

    def method_missing(name, *)
      return super unless @answers.key?(name)

      @calls << [name, *]
      answer = @answers[name]
      answer.respond_to?(:call) ? answer.call(*) : answer
    end

    def respond_to_missing?(name, include_private = false) = @answers.key?(name) || super
    def called?(name) = @calls.any? { |call| call.first == name }
    def args_of(name) = @calls.find { |call| call.first == name }&.drop(2)
  end

  class FakeTx
    def tenant_id! = "org-1"
  end

  class FakeTransactor
    attr_reader :tenants

    def initialize = @tenants = []

    def call(tenant_id: nil)
      @tenants << tenant_id
      yield FakeTx.new
    end
  end

  class Recorder
    attr_reader :entries

    def initialize = @entries = []
    def add(_tx, *args) = @entries << args
    def record(_tx, *args) = @entries << args
    def enqueue(_tx, *args, **options) = @entries << [*args, options]
  end

  class FakeHttp
    attr_reader :posts

    def initialize(status: 500, error: nil)
      @status = status
      @error = error
      @posts = 0
    end

    def post(*)
      @posts += 1
      raise @error if @error

      Struct.new(:status).new(@status)
    end
  end

  class Passthrough
    def track(**) = yield
  end

  class Clock
    def now = NOW
  end

  BUNDLE = { "id" => "d1", "status" => "pending", "active" => true, "paused_at" => nil, "endpoint_id" => "e1", "event_id" => "ev1",
             "event_type" => "reservation.confirmed", "url" => "https://destino.example/hook/segredo?token=abc", "occurred_at" => NOW,
             "payload" => {}, "secret_ciphertext" => "cifrado" }.freeze

  def deliver(webhooks, http: FakeHttp.new)
    @http = http
    @totals = Recorder.new
    @audit = Recorder.new
    box = Object.new
    def box.decrypt(text) = "segredo-#{text}"
    signer = Object.new
    def signer.header(*) = "t=1,v1=assinatura"
    A::Webhooks::Deliver.new(transactor: FakeTransactor.new, webhooks: webhooks, http: http, box: box, signer: signer, clock: Clock.new,
                             calls: Passthrough.new, totals: @totals, audit: @audit)
  end

  def failing_state(failures, since: FAILING_SINCE) = { "consecutive_failures" => failures, "failing_since" => since, "paused_at" => nil, "active" => true }

  def test_paused_endpoint_holds_the_delivery_without_network
    webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE.merge("paused_at" => NOW), hold_delivery: 1)

    assert_equal :endpoint_paused, deliver(webhooks).call("org-1", "d1", correlation_id: "req-1")
    assert_equal ["d1", "e1", NOW], webhooks.args_of(:hold_delivery)
    assert_equal 0, @http.posts
    refute webhooks.called?(:record_attempt), "nenhuma tentativa é gasta"
    assert_equal [["webhook_delivery", "held", 1, NOW]], @totals.entries
  end

  def test_endpoint_resumed_before_the_hold_gets_a_normal_attempt
    webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE.merge("paused_at" => NOW), hold_delivery: 0, record_attempt: 1, register_endpoint_result: nil)

    assert_equal :delivered, deliver(webhooks, http: FakeHttp.new(status: 204)).call("org-1", "d1")
    assert_equal 1, @http.posts
    assert_equal [["webhook_delivery", "delivered", 1, NOW]], @totals.entries
  end

  def test_failure_reaching_the_threshold_pauses_once_and_audits_without_the_url
    webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE, record_attempt: 1, register_endpoint_result: failing_state(20), pause_endpoint: 1)
    error = IOError.new("falha ao conectar em https://destino.example/hook/segredo?token=abc")
    use_case = deliver(webhooks, http: FakeHttp.new(error: error))

    assert_raises(A::Webhooks::Deliver::DeliveryFailed) { use_case.call("org-1", "d1", correlation_id: "req-origem") }
    assert_equal ["e1", false, NOW], webhooks.args_of(:register_endpoint_result)
    assert_equal ["e1", NOW], webhooks.args_of(:pause_endpoint)
    assert_equal [["webhook_delivery", "failed", 1, NOW], ["webhook_circuit", "paused", 1, NOW]], @totals.entries
    actor, action, type, id, details = @audit.entries.fetch(0)

    assert_equal %w[system org-1 req-origem], [actor.kind, actor.organization_id, actor.request_id]
    assert_equal ["webhook.endpoint_paused", "webhook_endpoint", "e1"], [action, type, id]
    assert_equal({ "consecutive_failures" => 20, "failing_since" => "2026-03-02T12:00:00Z", "last_status_code" => nil }, details.except("last_error"))
    refute_includes details["last_error"], "abc", "parâmetros da URL redigidos"
    refute details.key?("url")
    assert_operator details["last_error"].length, :<=, 200
  end

  def test_no_audit_when_another_attempt_already_paused_the_endpoint
    webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE, record_attempt: 1, register_endpoint_result: failing_state(25), pause_endpoint: 0)

    assert_raises(A::Webhooks::Deliver::DeliveryFailed) { deliver(webhooks).call("org-1", "d1") }
    assert_empty @audit.entries
    assert_equal [["webhook_delivery", "failed", 1, NOW]], @totals.entries
  end

  def test_below_the_threshold_already_paused_or_inactive_does_not_pause
    [failing_state(19, since: NOW - 7200), failing_state(20, since: NOW - 3599), failing_state(30).merge("paused_at" => NOW),
     failing_state(30).merge("active" => false), nil].each do |state|
      webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE, record_attempt: 1, register_endpoint_result: state, pause_endpoint: 1)

      assert_raises(A::Webhooks::Deliver::DeliveryFailed) { deliver(webhooks).call("org-1", "d1") }
      refute webhooks.called?(:pause_endpoint), state.inspect
      assert_empty @audit.entries
    end
  end

  def test_success_resets_the_streak_and_never_pauses
    webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE, record_attempt: 1, register_endpoint_result: failing_state(0, since: nil), pause_endpoint: 1)

    assert_equal :delivered, deliver(webhooks, http: FakeHttp.new(status: 200)).call("org-1", "d1")
    assert_equal ["e1", true, NOW], webhooks.args_of(:register_endpoint_result)
    refute webhooks.called?(:pause_endpoint)
    assert_empty @audit.entries
  end

  def test_unrecorded_attempt_does_not_count_or_touch_the_circuit
    webhooks = FakeWebhooks.new(delivery_bundle: BUNDLE, record_attempt: 0, register_endpoint_result: failing_state(20))

    assert_raises(A::Webhooks::Deliver::DeliveryFailed) { deliver(webhooks).call("org-1", "d1") }
    refute webhooks.called?(:register_endpoint_result)
    assert_empty @totals.entries
  end

  def test_missing_delivered_and_disabled_short_circuit_before_the_network
    { nil => :missing, BUNDLE.merge("status" => "delivered") => :already_delivered,
      BUNDLE.merge("active" => false, "paused_at" => NOW) => :endpoint_disabled }.each do |bundle, expected|
      webhooks = FakeWebhooks.new(delivery_bundle: bundle)

      assert_equal expected, deliver(webhooks).call("org-1", "d1")
      assert_equal 0, @http.posts
    end
  end

  def release(webhooks, batch_size: 2)
    @queue = Recorder.new
    @totals = Recorder.new
    @transactor = FakeTransactor.new
    A::Webhooks::ReleaseHeld.new(transactor: @transactor, webhooks: webhooks, queue: @queue, totals: @totals, clock: Clock.new, batch_size: batch_size)
  end

  def test_release_reschedules_itself_while_the_batch_is_full
    webhooks = FakeWebhooks.new(lock_endpoint_for_release: { "id" => "e1", "active" => true, "paused_at" => nil }, release_held: %w[d1 d2])

    assert_equal 2, release(webhooks).call("org-1", "e1", correlation_id: "req-reativa")
    assert_equal ["org-1"], @transactor.tenants
    assert_equal ["e1", 2], webhooks.args_of(:release_held)
    deliveries = @queue.entries.select { |kind, *| kind == "webhooks.deliver" }

    assert_equal([{ "delivery_id" => "d1" }, { "delivery_id" => "d2" }], deliveries.map { |entry| entry[1] })
    assert(deliveries.all? { |entry| entry.last == { priority: 40, correlation_id: "req-reativa", queue: "webhooks" } })
    assert_equal ["webhooks.release_held", { "endpoint_id" => "e1" }, { priority: 45, correlation_id: "req-reativa" }], @queue.entries.last
    assert_equal [["webhook_delivery", "released", 2, NOW]], @totals.entries
  end

  def test_release_stops_with_a_partial_batch_or_a_paused_endpoint
    partial = FakeWebhooks.new(lock_endpoint_for_release: { "id" => "e1", "active" => true, "paused_at" => nil }, release_held: %w[d1])

    assert_equal 1, release(partial).call("org-1", "e1")
    refute(@queue.entries.any? { |kind, *| kind == "webhooks.release_held" })
    paused = FakeWebhooks.new(lock_endpoint_for_release: { "id" => "e1", "active" => true, "paused_at" => NOW }, release_held: %w[d1])

    assert_equal :endpoint_paused, release(paused).call("org-1", "e1")
    refute paused.called?(:release_held)
    assert_empty @queue.entries
    disabled = FakeWebhooks.new(lock_endpoint_for_release: { "id" => "e1", "active" => false, "paused_at" => nil })

    assert_equal :endpoint_paused, release(disabled).call("org-1", "e1")
    assert_equal :missing, release(FakeWebhooks.new(lock_endpoint_for_release: nil)).call("org-1", "e1")
  end
end
