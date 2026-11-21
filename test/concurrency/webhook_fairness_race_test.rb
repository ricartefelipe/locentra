# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"
require_relative "../support/worker_support"

# Fila de webhooks sob concorrência real: reivindicações simultâneas em transações abertas ao mesmo
# tempo nunca deixam uma organização acima do limite nem reivindicam a mesma tarefa duas vezes, e as
# threads de webhooks de um worker não são monopolizadas pelos destinos lentos de uma organização.
class WebhookFairnessRaceTest < DatabaseTest
  include WorkerHelpers

  Q = Locentra::Infrastructure::Jobs::Queue
  CAP = 2
  THREADS = 6
  ROUNDS = 20

  # Pausa em duas etapas: a thread pausada avisa que chegou e só continua quando liberada.
  class Gate
    def initialize
      @reached = Barrier.new(2)
      @resume = Barrier.new(2)
    end

    def wait
      @reached.wait
      @resume.wait
    end

    def reached = @reached.wait
    def resume = @resume.wait
  end

  def setup
    super
    @alfa = create_organization
    @beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    worker_system
    drain
    @racing = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: @system.logger,
                                                                                database_url: TestDatabase.worker_url, pool_name: "worker",
                                                                                pool_size: THREADS + 2, mailer: FakeMailer.new)
    @queue = Q.new(clock: @clock, ids: @racing.ids, organization_limits: { "webhooks" => CAP })
  end

  def teardown
    @servers&.each(&:stop)
    @racing&.shutdown
    @worker_system&.shutdown
    super
  end

  def wtx(org = nil, &) = @racing.transactor.call(tenant_id: org && org[:organization_id], &)
  def enqueue(org, name) = wtx(org) { |tx| @queue.enqueue(tx, "webhooks.deliver", { "n" => name }, queue: "webhooks", priority: 40) }

  def worker_rows(sql, params = [])
    conn = PG.connect(TestDatabase.worker_url)
    conn.exec_params(sql, params).to_a
  ensure
    conn&.close
  end

  def running_by_org
    worker_rows(<<~SQL, [@clock.now]).to_h { |row| [row["organization_id"], row["count"].to_i] }
      SELECT organization_id, count(*) FROM jobs WHERE status = 'running' AND lease_expires_at > $1 GROUP BY 1
    SQL
  end

  def pending_of(org)
    worker_rows("SELECT count(*) AS n FROM jobs WHERE status = 'pending' AND organization_id = $1", [org[:organization_id]]).first["n"].to_i
  end

  # Seis reivindicações com as transações abertas ao mesmo tempo (a segunda barreira segura o commit).
  def race_round
    start = Barrier.new(THREADS)
    hold = Barrier.new(THREADS)
    Array.new(THREADS) do |i|
      Thread.new do
        start.wait
        wtx do |tx|
          job = @queue.claim(tx, worker: "corrida-#{i}", limit: 1, queues: ["webhooks"]).first
          hold.wait
          job
        end
      end
    end.filter_map(&:value)
  end

  # Tarefas que uma reivindicação agora poderia receber (pendentes prontas ou com lease vencido).
  def claimable(org)
    worker_rows(<<~SQL, [org[:organization_id], @clock.now]).first["n"].to_i
      SELECT count(*) AS n FROM jobs
       WHERE organization_id = $1 AND ((status = 'pending' AND run_at <= $2) OR (status = 'running' AND lease_expires_at <= $2))
    SQL
  end

  # Libera uma vaga de cada organização no limite (concluindo a execução mais antiga com o lease atual)
  # e repõe a tarefa concluída.
  def free_slots(latest)
    [@alfa, @beta].each do |org|
      ids = worker_rows(<<~SQL, [org[:organization_id], @clock.now]).map { |row| row["id"] }
        SELECT id FROM jobs WHERE organization_id = $1 AND status = 'running' AND lease_expires_at > $2 ORDER BY lease_expires_at, id
      SQL
      next unless ids.size == CAP

      assert(wtx { |tx| @queue.complete(tx, latest.fetch(ids.first)) })
      enqueue(org, "reposta")
    end
  end

  def assert_round(round, claimed)
    after = running_by_org

    assert(after.values.all? { |n| n <= CAP }, "rodada #{round}: #{after.inspect}")
    assert_equal claimed.size, claimed.map(&:id).uniq.size, "rodada #{round}: tarefa reivindicada duas vezes"
    open = worker_rows("SELECT job_id, count(*) AS n FROM job_attempts WHERE finished_at IS NULL GROUP BY job_id").to_h { |r| [r["job_id"], r["n"].to_i] }

    assert(open.values.all?(1), "rodada #{round}: no máximo uma tentativa aberta por tarefa")
    claimed.each { |job| assert_equal 1, open[job.id], "rodada #{round}: tentativa da reivindicação aberta" }
  end

  def test_simultaneous_claims_never_exceed_the_organization_limit
    10.times { |i| enqueue(@alfa, "a#{i}") }
    2.times { |i| enqueue(@beta, "b#{i}") }
    latest = {}
    turns_for_b = 0
    ROUNDS.times do |round|
      @clock.advance(121) if round == 10 # leases vencidos deixam de contar e voltam a ser candidatos
      room_for_b = running_by_org.fetch(@beta[:organization_id], 0) < CAP && claimable(@beta).positive?
      claimed = race_round
      claimed.each { |job| latest[job.id] = job }

      assert_round(round, claimed)
      if room_for_b
        assert(claimed.any? { |job| job.organization_id == @beta[:organization_id] }, "rodada #{round}: B recebe a vaga livre")
        turns_for_b += 1
      end
      free_slots(latest) if round % 3 == 2
    end

    assert_operator turns_for_b, :>=, 5
  end

  # Controle: com a primeira reivindicação parada entre o lock consultivo de A e a recontagem, a segunda
  # não reivindica A nesse intervalo (o try-lock falha e A é pulada), mas recebe a tarefa de B.
  def test_a_claim_paused_after_the_advisory_lock_makes_the_others_skip_the_organization
    3.times { |i| enqueue(@alfa, "a#{i}") }
    @clock.advance(1)
    enqueue(@beta, "b0")
    gate = Gate.new
    paused = Thread.new do
      wtx { |tx| @queue.claim(PausingProxy.new(tx, :query_value, gate, after: true), worker: "pausada", limit: 1, queues: ["webhooks"]).first }
    end
    gate.reached
    other = wtx { |tx| @queue.claim(tx, worker: "outra", limit: 1, queues: ["webhooks"]).first }

    assert_equal @beta[:organization_id], other.organization_id, "A está com o lock consultivo da primeira reivindicação"
    gate.resume
    first = paused.value

    assert_equal @alfa[:organization_id], first.organization_id
    assert_equal({ @alfa[:organization_id] => 1, @beta[:organization_id] => 1 }, running_by_org)
  end

  def dispatch(system, org, count)
    count.times do
      system.transactor.call(tenant_id: org[:organization_id]) do |tx|
        event = system.services[:events].publish(tx, "reservation.confirmed", "reservation", SecureRandom.uuid, { "code" => "R-1" })
        system.services[:dispatch_event].call(tx, event)
      end
    end
  end

  def wait_until(seconds = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.02 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  def test_slow_endpoints_of_one_organization_do_not_monopolize_webhook_threads
    server_a = HoldingServer.new
    server_b = CaptureServer.new
    @servers = [server_a, server_b]
    uc(:create_webhook).call(@alfa[:actor], url: server_a.url, events: ["*"])
    uc(:create_webhook).call(@beta[:actor], url: server_b.url, events: ["*"])
    dispatch(@racing, @alfa, 6)
    @clock.advance(1)
    dispatch(@racing, @beta, 2)
    handlers = Locentra::Interfaces::Worker::Handlers.new(@racing, mailer: FakeMailer.new, templates: @racing.services[:mail_templates])
    runner = Locentra::Interfaces::Worker::Runner.new(system: @racing, handlers: handlers, concurrency: 0, webhook_concurrency: 4,
                                                      logger: @racing.logger, scheduler: false, poll_interval: 0.05)
    threads = runner.start_threads

    2.times { assert server_b.requests.pop(timeout: 10), "B é entregue com os destinos de A parados" }
    assert(wait_until { server_a.in_flight == CAP }, "duas entregas de A em voo")
    sleep 0.3

    assert_equal CAP, server_a.max_in_flight, "A nunca ocupa mais do que o limite"
    server_a.release!

    assert(wait_until { server_a.requests.size == 6 }, "as seis entregas de A terminam depois da liberação")
    assert_equal CAP, server_a.max_in_flight
    runner.stop(threads, timeout: 5)
    delivered = owner_query("SELECT count(*) AS n FROM webhook_deliveries WHERE status = 'delivered'", tenant: @alfa[:organization_id])

    assert_equal 6, delivered.first["n"].to_i
  end
end
