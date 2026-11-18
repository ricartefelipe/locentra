# frozen_string_literal: true

require_relative "repository_helper"

# Agregados globais de observabilidade (queue_stats e job_outcome_totals): sem dados de tenant,
# gravados somente pelo worker e lidos pela aplicação web para /metrics.
class ObservabilityTablesTest < DatabaseTest
  TABLES = %w[queue_stats job_outcome_totals].freeze

  def connect(url) = PG.connect(url).tap { |conn| conn.exec("SET client_min_messages = warning") }

  def test_global_aggregates_carry_no_tenant_or_identifier_columns
    columns = owner_query(<<~SQL, ["{#{TABLES.join(",")}}"]).group_by { |r| r["table_name"] }.transform_values { |rows| rows.map { |r| r["column_name"] } }
      SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ANY($1::text[])
       ORDER BY table_name, ordinal_position
    SQL

    assert_equal %w[queue kind outcome total updated_at], columns["job_outcome_totals"]
    assert_equal %w[queue status size oldest_age_seconds updated_at], columns["queue_stats"]
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
end
