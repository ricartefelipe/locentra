# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"

# Reivindicação justa na fila de webhooks (sequencial e determinística): nenhuma organização passa do
# limite de execuções com lease válido, quem tem menos execuções em curso tem preferência, leases
# vencidos não contam e continuam recuperáveis com fencing, tarefas sem organização e a fila `default`
# não têm limite, a prioridade vale entre filas misturadas e tarefas esgotadas continuam enterradas.
class WebhookFairnessTest < DatabaseTest
  include WorkerHelpers

  Q = Locentra::Infrastructure::Jobs::Queue
  CAP = 2

  def setup
    super
    @alfa = create_organization
    @beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    worker_system
    drain
    @queue = Q.new(clock: @clock, ids: worker_system.ids, organization_limits: { "webhooks" => CAP })
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def wtx(org = nil, &) = worker_system.transactor.call(tenant_id: org && org[:organization_id], &)

  def enqueue(org, name, queue: "webhooks", priority: 40, **)
    wtx(org) { |tx| @queue.enqueue(tx, "webhooks.deliver", { "n" => name }, queue: queue, priority: priority, **) }
  end

  def claim(worker: "w", queues: ["webhooks"], queue: @queue)
    wtx { |tx| queue.claim(tx, worker: worker, limit: 1, queues: queues).first }
  end

  def org_of(job) = { @alfa[:organization_id] => "A", @beta[:organization_id] => "B" }.fetch(job.organization_id, "-")

  def test_organizations_with_fewer_running_jobs_come_first_and_the_limit_holds
    5.times { |i| enqueue(@alfa, "a#{i}") }
    @clock.advance(1)
    enqueue(@beta, "b0")
    claimed = Array.new(3) { claim }

    assert_equal %w[A B A], claimed.map { |job| org_of(job) }, "B, sem execuções, passa à frente do backlog de A"
    assert_nil claim, "A está no limite e B não tem mais pendências"
    assert(wtx { |tx| @queue.complete(tx, claimed.first) })
    again = claim

    assert_equal "A", org_of(again), "ao concluir uma execução, A volta a ser elegível"
    assert_nil claim
    running = owner_query("SELECT count(*) AS n FROM jobs WHERE status = 'running' AND organization_id = $1", [@alfa[:organization_id]],
                          tenant: @alfa[:organization_id])

    assert_equal CAP, running.first["n"].to_i
  end

  def test_expired_leases_do_not_count_and_are_reclaimed_within_the_limit_with_fencing
    2.times { |i| enqueue(@alfa, "a#{i}") }
    stale = Array.new(2) { claim(worker: "antigo") }

    assert_nil claim, "duas execuções de lease válido"
    @clock.advance(121)
    fresh = Array.new(2) { claim(worker: "novo") }

    assert_equal stale.map(&:id).sort, fresh.map(&:id).sort, "as tarefas de lease vencido são reivindicadas de novo"
    assert_nil claim, "as novas execuções contam no limite"
    refute(wtx { |tx| @queue.complete(tx, stale.first) }, "o worker antigo não conclui")
    assert(wtx { |tx| @queue.complete(tx, fresh.first) })
    history = wtx(@alfa) { |tx| @queue.attempts(tx, stale.first.id) }.map { |row| [row["worker"], row["outcome"]] }

    assert_equal [%w[antigo lease_lost], %w[novo succeeded]], history
  end

  def test_jobs_without_organization_are_claimed_in_the_limited_queue
    CAP.times { |i| enqueue(@alfa, "a#{i}") }
    CAP.times { claim }
    enqueue(@alfa, "a-excedente")
    enqueue(nil, "plataforma")
    job = claim

    assert_nil job.organization_id
    assert_equal "plataforma", job.payload["n"]
    assert_nil claim, "a excedente de A continua esperando"
  end

  def test_the_default_queue_has_no_limit_per_organization
    5.times { |i| enqueue(@alfa, "d#{i}", queue: "default") }
    claimed = Array.new(5) { claim(queues: ["default"]) }

    assert_equal [@alfa[:organization_id]] * 5, claimed.map(&:organization_id)
    assert_equal 5, claimed.map(&:id).uniq.size
  end

  def test_drain_with_mixed_queues_respects_priority
    { "default-90" => ["default", 90], "webhooks-10" => ["webhooks", 10], "default-50" => ["default", 50],
      "webhooks-60" => ["webhooks", 60] }.each { |name, (queue, priority)| enqueue(@alfa, name, queue: queue, priority: priority) }
    order = []
    handlers = Locentra::Interfaces::Worker::Handlers.new(worker_system, mailer: @mailer, templates: worker_system.services[:mail_templates])
    handlers.register("webhooks.deliver", ->(job) { order << job.payload["n"] })
    mixed = Locentra::Interfaces::Worker::Runner.new(system: worker_system, handlers: handlers, concurrency: 1, logger: worker_system.logger,
                                                     scheduler: false)

    assert_equal 4, mixed.drain
    assert_equal %w[webhooks-10 default-50 webhooks-60 default-90], order
    assert_equal({ "webhooks" => CAP }, worker_system.queue.organization_limits, "limite padrão da configuração")
  end

  def test_jobs_scheduled_for_the_future_are_not_candidates
    enqueue(@alfa, "futura", run_at: @clock.now + 60)

    assert_nil claim
    @clock.advance(60)

    assert_equal "futura", claim.payload["n"]
  end

  def test_exhausted_jobs_are_still_buried
    enqueue(@alfa, "esgotada", max_attempts: 1)

    refute_nil claim(worker: "morto")
    @clock.advance(121)

    assert_nil claim
    row = jobs("kind = 'webhooks.deliver'").first

    assert_equal ["dead", Q::EXHAUSTED_LEASE], row.values_at("status", "last_error")
  end
end
