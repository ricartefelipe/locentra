# frozen_string_literal: true

require_relative "repository_helper"
require_relative "../support/worker_support"

# Agregados globais de observabilidade (queue_stats, job_outcome_totals e worker_outcome_totals): sem
# dados de tenant, gravados somente pelo worker e lidos pela aplicação web para /metrics. A fila soma os desfechos
# somente quando a transição vale (lease atual), e uma tarefa sem tentativas restantes soma como
# falha permanente.
class ObservabilityTablesTest < DatabaseTest
  include WorkerHelpers

  TABLES = %w[queue_stats job_outcome_totals worker_outcome_totals].freeze
  QUEUE = "metricas_teste"

  def teardown
    @worker_system&.shutdown
    super
  end

  def connect(url) = PG.connect(url).tap { |conn| conn.exec("SET client_min_messages = warning") }
  def queue = worker_system.queue
  def wtx(&) = worker_system.transactor.call(&)
  def enqueue(kind, max_attempts: 10) = wtx { |tx| queue.enqueue(tx, kind, {}, max_attempts: max_attempts, queue: QUEUE) }
  def claim = wtx { |tx| queue.claim(tx, worker: "worker-a", limit: 1, queues: [QUEUE]).first }
  def status(job) = wtx { |tx| tx.query_value("SELECT status FROM jobs WHERE id = $1", [job.id]) }

  def totals
    owner_query("SELECT queue, kind, outcome, total FROM job_outcome_totals ORDER BY kind, outcome").map do |row|
      [row["queue"], row["kind"], row["outcome"], Integer(row["total"])]
    end
  end

  def test_global_aggregates_carry_no_tenant_or_identifier_columns
    columns = owner_query(<<~SQL, ["{#{TABLES.join(",")}}"]).group_by { |r| r["table_name"] }.transform_values { |rows| rows.map { |r| r["column_name"] } }
      SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ANY($1::text[])
       ORDER BY table_name, ordinal_position
    SQL

    assert_equal %w[queue kind outcome total updated_at], columns["job_outcome_totals"]
    assert_equal %w[queue status size oldest_age_seconds updated_at], columns["queue_stats"]
    assert_equal %w[family outcome total updated_at], columns["worker_outcome_totals"]
  end

  # Totais por desfecho de webhooks, pausas de endpoints e retenção: lista fechada de pares no CHECK.
  def test_only_the_worker_writes_worker_outcome_totals_and_nobody_deletes_them
    worker = connect(TestDatabase.worker_url)
    worker.exec("INSERT INTO worker_outcome_totals (family, outcome, total, updated_at) VALUES ('webhook_delivery', 'held', 2, now())")
    worker.exec("UPDATE worker_outcome_totals SET total = total + 1")
    app = connect(TestDatabase.app_url)

    assert_equal [%w[webhook_delivery held 3]], app.exec("SELECT family, outcome, total FROM worker_outcome_totals").values
    assert_raises(PG::InsufficientPrivilege) { app.exec("INSERT INTO worker_outcome_totals VALUES ('retention', 'jobs', 1, now())") }
    assert_raises(PG::InsufficientPrivilege) { app.exec("UPDATE worker_outcome_totals SET total = 0") }
    assert_raises(PG::InsufficientPrivilege) { app.exec("DELETE FROM worker_outcome_totals") }
    assert_raises(PG::InsufficientPrivilege) { worker.exec("DELETE FROM worker_outcome_totals") }
    assert_raises(PG::CheckViolation) { worker.exec("INSERT INTO worker_outcome_totals VALUES ('retention', 'sessions', 1, now())") }
    assert_raises(PG::CheckViolation) { worker.exec("INSERT INTO worker_outcome_totals VALUES ('webhook_circuit', 'delivered', 1, now())") }
    assert_raises(PG::CheckViolation) { worker.exec("INSERT INTO worker_outcome_totals VALUES ('webhook_delivery', 'held', -1, now())") }
  ensure
    worker&.close
    app&.close
  end

  def test_only_the_worker_writes_outcome_totals_and_nobody_deletes_them
    worker = connect(TestDatabase.worker_url)
    worker.exec("INSERT INTO job_outcome_totals (queue, kind, outcome, total, updated_at) VALUES ('default', 'webhooks.deliver', 'retry', 1, now())")
    worker.exec("UPDATE job_outcome_totals SET total = total + 1")
    app = connect(TestDatabase.app_url)

    assert_equal [%w[webhooks.deliver 2]], app.exec("SELECT kind, total FROM job_outcome_totals").values
    assert_raises(PG::InsufficientPrivilege) { app.exec("INSERT INTO job_outcome_totals VALUES ('default', 'x', 'dead', 1, now())") }
    assert_raises(PG::InsufficientPrivilege) { app.exec("UPDATE job_outcome_totals SET total = 0") }
    assert_raises(PG::InsufficientPrivilege) { app.exec("DELETE FROM job_outcome_totals") }
    assert_raises(PG::InsufficientPrivilege) { worker.exec("DELETE FROM job_outcome_totals") }
    assert_raises(PG::CheckViolation) { worker.exec("INSERT INTO job_outcome_totals VALUES ('default', 'x', 'succeeded', 1, now())") }
  ensure
    worker&.close
    app&.close
  end

  # O worker cujo lease venceu e foi assumido por outro não registra retentativa nem falha permanente.
  def test_transitions_with_a_lost_lease_do_not_count
    enqueue("webhooks.deliver")
    stale = claim
    @clock.advance(121)
    fresh = claim

    assert_equal [stale.id, 2], [fresh.id, fresh.attempts]
    refute(wtx { |tx| queue.retry_later(tx, stale, "erro do worker antigo") })
    refute(wtx { |tx| queue.kill(tx, stale, "erro do worker antigo") })
    assert_empty totals, "transição com lease perdido não soma"
    assert_equal "running", status(fresh)
    assert(wtx { |tx| queue.retry_later(tx, fresh, "erro do worker atual") })
    assert_equal [[QUEUE, "webhooks.deliver", "retry", 1]], totals
  end

  # Reagendar a última tentativa encerra a tarefa: soma uma falha permanente e nenhuma retentativa.
  def test_retry_after_the_last_attempt_counts_only_as_dead
    enqueue("payments.submit", max_attempts: 1)
    job = claim

    assert_equal [1, 1], [job.attempts, job.max_attempts]
    assert(wtx { |tx| queue.retry_later(tx, job, "falha definitiva") })
    assert_equal [[QUEUE, "payments.submit", "dead", 1]], totals
    assert_equal "dead", status(job)
    enqueue("payments.submit", max_attempts: 2)
    first = claim

    assert(wtx { |tx| queue.retry_later(tx, first, "primeira falha") })

    assert_equal [[QUEUE, "payments.submit", "dead", 1], [QUEUE, "payments.submit", "retry", 1]], totals
  end
end
