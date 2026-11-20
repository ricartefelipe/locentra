# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/barrier"

class WorkerTest < DatabaseTest
  include WorkerHelpers

  Q = Locentra::Infrastructure::Jobs::Queue

  def setup
    super
    @org = create_organization
    worker_system
    drain
    @mailer.deliveries.clear
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def queue = worker_system.queue
  def wtx(&) = worker_system.transactor.call(tenant_id: @org[:organization_id], &)

  def test_signup_confirmation_email_contains_single_use_token
    result = uc(:sign_up).call(name: "Novo", email: "novo@example.test", password: "senha-muito-segura-1", organization_name: "Empresa Nova")
    drain

    assert_equal "novo@example.test", @mailer.deliveries.last[:to]
    assert_includes @mailer.deliveries.last[:subject], "Confirme"
    assert_equal result[:user_id], uc(:confirm_email).call(@mailer.token_in)
    assert_empty jobs("status = 'pending'")
  end

  def test_password_reset_job_has_no_secret_in_payload_and_link_works
    uc(:request_password_reset).call(email: "dona@alfa.test", ip: "10.0.0.1")
    payloads = jobs("kind = 'email.password_reset'")

    assert_equal 1, payloads.size
    assert_nil payloads.first["organization_id"]
    drain
    token = @mailer.token_in

    refute_nil token
    uc(:reset_password).call(token: token, password: "senha-totalmente-nova-1")

    assert uc(:authenticate).call(email: "dona@alfa.test", password: "senha-totalmente-nova-1", ip: "10.0.0.2")
  end

  def test_invitation_email_issues_token_at_delivery
    uc(:invite_member).call(@org[:actor], email: "convidado@example.test", role: "auditor")
    drain
    token = @mailer.token_in

    assert token.start_with?(@org[:organization_id])
    joined = uc(:accept_invitation).call(token: token, name: "Convidado", password: "senha-muito-segura-9")

    assert_equal @org[:organization_id], joined[:organization_id]
  end

  def test_lease_expiry_recovery_and_fencing_of_stale_worker
    wtx { |tx| queue.enqueue(tx, "email.send", { "template" => "nao_existe", "to" => "x@example.test" }) }
    stale = worker_system.transactor.call { |tx| queue.claim(tx, worker: "a", limit: 1).first }

    assert_nil worker_system.transactor.call { |tx| queue.claim(tx, worker: "b", limit: 1).first }, "lease ativo impede nova reivindicação"
    @clock.advance(121)
    fresh = worker_system.transactor.call { |tx| queue.claim(tx, worker: "b", limit: 1).first }

    assert_equal stale.id, fresh.id
    refute_equal stale.lease_token, fresh.lease_token
    refute worker_system.transactor.call { |tx| queue.complete(tx, stale) }, "worker com lease vencido não finaliza"
    refute(worker_system.transactor.call { |tx| queue.heartbeat(tx, stale) })
    assert(worker_system.transactor.call { |tx| queue.complete(tx, fresh) })
    outcomes = PG.connect(TestDatabase.worker_url).then { |c| c.exec("SELECT outcome FROM job_attempts ORDER BY attempt").column_values(0).tap { c.close } }

    assert_equal %w[lease_lost succeeded], outcomes.last(2).sort
  end

  def test_retry_with_backoff_then_dead_and_authorized_requeue
    wtx { |tx| queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => SecureRandom.uuid }, max_attempts: 2) }
    handlers = Locentra::Interfaces::Worker::Handlers.new(worker_system, mailer: @mailer, templates: worker_system.services[:mail_templates])
    handlers.register("webhooks.deliver", ->(_job) { raise IOError, "rede indisponível" })
    flaky = Locentra::Interfaces::Worker::Runner.new(system: worker_system, handlers: handlers, concurrency: 1, logger: worker_system.logger, scheduler: false)

    assert_equal 1, flaky.drain
    row = jobs("kind = 'webhooks.deliver'").first

    assert_equal %w[pending 1], [row["status"], row["attempts"].to_s]
    assert_match(/rede indisponível/, row["last_error"])
    assert_equal 0, flaky.drain, "aguarda o backoff"
    @clock.advance(3600)

    assert_equal 1, flaky.drain
    assert_equal "dead", jobs("kind = 'webhooks.deliver'").first["status"]
    failures = @system.uow.run(@org[:actor]) { |tx, _| @system.queue.failures(tx) }

    assert_equal 1, failures.size
    assert(@system.uow.run(@org[:actor], "jobs.manage") { |tx, _| @system.queue.requeue(tx, failures.first["id"]) })
    assert_equal "pending", jobs("kind = 'webhooks.deliver'").first["status"]
  end

  # Após o reprocessamento, as tentativas da tarefa recomeçam (orçamento de max_attempts), mas a
  # numeração em job_attempts continua: encerrar a nova tentativa não altera tentativas anteriores,
  # e tentativas abandonadas (lease vencido sem retorno do worker) são encerradas no reprocessamento.
  def test_requeue_keeps_attempt_history_and_never_overwrites_previous_attempts
    id = wtx { |tx| queue.enqueue(tx, "email.send", { "template" => "nao_existe" }, max_attempts: 2) }
    abandoned = worker_system.transactor.call { |tx| queue.claim(tx, worker: "a", limit: 1).first }
    @clock.advance(121)
    second = worker_system.transactor.call { |tx| queue.claim(tx, worker: "b", limit: 1).first }

    assert(worker_system.transactor.call { |tx| queue.kill(tx, second, "falha definitiva") })
    uc(:retry_job).call(@org[:actor], id)
    third = worker_system.transactor.call { |tx| queue.claim(tx, worker: "c", limit: 1).first }

    assert_equal [id, 1], [third.id, third.attempts], "o orçamento de tentativas recomeça"
    assert(worker_system.transactor.call { |tx| queue.complete(tx, third) })
    refute(worker_system.transactor.call { |tx| queue.complete(tx, abandoned) }, "o worker antigo não finaliza")
    history = wtx { |tx| queue.attempts(tx, id) }.map { |row| row.values_at("attempt", "worker", "outcome", "error") }

    assert_equal [[1, "a", "lease_lost", nil], [2, "b", "dead", "falha definitiva"], [3, "c", "succeeded", nil]], history
    assert(wtx { |tx| queue.attempts(tx, id) }.all? { |row| row["finished_at"] })
  end

  # Processo que morre durante o handler (falta de memória, SIGKILL) não chama retry_later: o limite
  # de tentativas é aplicado na recuperação do lease vencido.
  def test_expired_lease_on_the_last_attempt_ends_the_job_as_dead
    id = wtx { |tx| queue.enqueue(tx, "email.send", { "template" => "nao_existe" }, max_attempts: 2) }
    2.times do
      refute_nil(worker_system.transactor.call { |tx| queue.claim(tx, worker: "morto", limit: 1).first })
      @clock.advance(121)
    end

    assert_nil(worker_system.transactor.call { |tx| queue.claim(tx, worker: "c", limit: 1).first })
    row = jobs("kind = 'email.send'").first

    assert_equal(["dead", 2, Q::EXHAUSTED_LEASE], row.values_at("status", "attempts", "last_error").then { |a| [a[0], a[1].to_i, a[2]] })
    history = wtx { |tx| queue.attempts(tx, id) }

    assert_equal([%w[1 lease_lost], %w[2 lease_lost]], history.map { |r| [r["attempt"].to_s, r["outcome"]] })
    assert(history.all? { |r| r["finished_at"] })
    totals = PG.connect(TestDatabase.worker_url).then { |c| c.exec("SELECT kind, outcome, total FROM job_outcome_totals").to_a.tap { c.close } }

    assert_equal([{ "kind" => "email.send", "outcome" => "dead", "total" => "1" }], totals.map { |t| t.transform_values(&:to_s) })
  end

  def test_webhook_deliveries_use_their_own_queue_and_threads
    server = CaptureServer.new
    uc(:create_webhook).call(@org[:actor], url: server.url, events: ["*"])
    customer = create_customer(@org[:actor])
    chairs = create_product(@org[:actor], sku: "CAD-Q", tracking: "bulk")
    stock(@org[:actor], chairs, @org[:branch], 5)
    reserve(@org[:actor], customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z"), [line(chairs, 1)], mode: "confirm")
    drain

    assert server.requests.pop(timeout: 5), "drain atende também a fila de webhooks"
    queues = PG.connect(TestDatabase.worker_url).then do |c|
      c.exec("SELECT kind, queue FROM jobs WHERE kind = 'webhooks.deliver'").to_a.tap { c.close }
    end

    refute_empty queues
    assert(queues.all? { |row| row["queue"] == "webhooks" })
    lanes = runner.instance_variable_get(:@lanes)

    assert_equal [[["default"], 1], [["webhooks"], 1]], lanes
  ensure
    server&.stop
  end

  # Banco indisponível: os laços esperam com backoff em vez de girar sem pausa.
  def test_loops_wait_with_backoff_when_the_database_is_unavailable
    failing = Object.new
    def failing.call(*, **) = raise(PG::ConnectionBad, "banco indisponível")
    fake = Struct.new(:transactor, :queue, :clock, :metrics) { def shutdown = nil }.new(failing, queue, @clock, worker_system.metrics)
    log = StringIO.new
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: log, level: "info")
    loops = Locentra::Interfaces::Worker::Runner.new(system: fake, handlers: nil, concurrency: 2, logger: logger, scheduler: true)
    threads = loops.start_threads
    Thread.pass until log.string.scan("worker.scheduler_failed").size >= 1 && log.string.scan("worker.thread_crashed").size >= 3
    sleep 1.2
    loops.stop(threads, timeout: 2)
    events = log.string.lines.map { |line| JSON.parse(line)["event"] }.tally

    assert_operator events.fetch("worker.thread_crashed"), :<=, 9, events.inspect
    assert_operator events.fetch("worker.scheduler_failed"), :<=, 3, events.inspect
  end

  def test_unknown_job_kind_fails_permanently
    wtx { |tx| queue.enqueue(tx, "desconhecido.tipo", {}) }
    drain

    assert_equal "dead", jobs("kind = 'desconhecido.tipo'").first["status"]
  end

  def test_backoff_grows_and_is_capped
    delays = (1..20).map { |attempt| Q.backoff(attempt, "00000000-0000-7000-8000-00000000abcd") }

    assert_operator delays[1], :>, delays[0]
    assert(delays.all? { |d| d <= 6 * 3600 })
  end

  def test_scheduler_fanout_expires_holds_per_organization_once
    camera = create_product(@org[:actor], sku: "CAM-W", tracking: "serialized")
    register_assets(@org[:actor], camera, @org[:branch], 1)
    customer = create_customer(@org[:actor])
    hold = reserve(@org[:actor], customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z"), [line(camera, 1)], hold_minutes: 5)
    @clock.advance(600)
    2.times { runner.send(:schedule) }
    drain

    assert_equal 1, jobs("kind = 'platform.fanout'").size, "chave única por janela"
    assert_equal "expired", uc(:get_reservation).call(@org[:actor], hold.id)[:reservation].status
  end

  def test_events_are_dispatched_to_signed_webhooks_with_stable_ids
    server = CaptureServer.new
    endpoint = uc(:create_webhook).call(@org[:actor], url: server.url, events: ["reservation.confirmed"])
    customer = create_customer(@org[:actor])
    chairs = create_product(@org[:actor], sku: "CAD-W", tracking: "bulk")
    stock(@org[:actor], chairs, @org[:branch], 5)
    reservation = reserve(@org[:actor], customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z"), [line(chairs, 2)], mode: "confirm")
    drain
    request = server.requests.pop(timeout: 5)

    assert request, "webhook entregue"
    body = JSON.parse(request[:body])

    assert_equal "reservation.confirmed", body["type"]
    assert_equal reservation.code, body["data"]["code"]
    assert Locentra::Infrastructure::WebhookSignature.valid?(endpoint["secret"], request[:headers]["x-locentra-signature"], request[:body], now: @clock.now)
    assert_equal body["id"], request[:headers]["x-locentra-event-id"]
    assert_includes @mailer.deliveries.map { |d| d[:subject] }, "Reserva #{reservation.code} confirmada"
    deliveries = uc(:list_webhooks).call(@org[:actor])[:deliveries]

    assert_equal([%w[delivered 1]], deliveries.map { |d| [d["status"], d["attempts"].to_s] })
    event_id = body["id"]

    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      assert_equal :already_dispatched, worker_system.services[:dispatch_event].call(tx, event_id)
    end
  ensure
    server&.stop
  end

  def test_failed_webhook_is_retried_with_same_delivery_id
    server = CaptureServer.new(status: 500)
    uc(:create_webhook).call(@org[:actor], url: server.url, events: ["*"])
    customer = create_customer(@org[:actor])
    chairs = create_product(@org[:actor], sku: "CAD-F", tracking: "bulk")
    stock(@org[:actor], chairs, @org[:branch], 5)
    reserve(@org[:actor], customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z"), [line(chairs, 1)])
    drain
    first = server.requests.pop(timeout: 5)
    @clock.advance(3600)
    drain
    second = server.requests.pop(timeout: 5)

    assert_equal first[:headers]["x-locentra-delivery-id"], second[:headers]["x-locentra-delivery-id"]
    assert_equal "failed", uc(:list_webhooks).call(@org[:actor])[:deliveries].first["status"]
  ensure
    server&.stop
  end

  def test_webhook_endpoint_validation_and_plan_gate
    assert_raises(D::ValidationError) { uc(:create_webhook).call(@org[:actor], url: "https://hooks.example", events: []) }
    assert_raises(D::ValidationError) { uc(:create_webhook).call(@org[:actor], url: "https://hooks.example", events: ["tudo"]) }
    small = create_organization(name: "Pequena", email: "pequena@example.test", plan: "essencial")

    assert_raises(D::PlanLimitExceeded) { uc(:create_webhook).call(small[:actor], url: "http://127.0.0.1:9/x", events: ["*"]) }
  end
end
