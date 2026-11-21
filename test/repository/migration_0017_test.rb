# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "repository_helper"

# Atualização de um banco da versão 1.2.0 (migrations 0001 a 0016) para a 0017, com dados gravados por
# SQL no formato da 1.2.0: endpoints ativos e desativados, entregas pendentes, entregues e com falha,
# eventos da outbox despachados e não despachados e webhooks recebidos. Depois da migration, o circuito
# começa zerado, nenhuma entrega fica retida, os índices novos existem com os predicados esperados, os
# CHECKs valem, a RLS continua forçada e inserções no formato da 1.2.0 (sem as colunas novas) continuam
# aceitas pelos papéis da aplicação e do worker. O esquema completo é recriado ao final.
class Migration0017Test < Minitest::Test
  MIGRATIONS = File.expand_path("../../db/migrations", __dir__)
  LEGACY_AT = "2026-01-05T12:00:00Z"
  TABLES = %w[webhook_endpoints webhook_deliveries inbound_webhooks].freeze
  INDEXES = {
    "jobs_ready_org_idx" => ["(queue, organization_id, priority, run_at)", "WHERE (status = 'pending'::text)"],
    "outbox_events_dispatched_idx" => ["(organization_id, dispatched_at)", "WHERE (dispatched_at IS NOT NULL)"],
    "webhook_deliveries_event_idx" => ["(organization_id, event_id)", nil],
    "webhook_deliveries_finished_idx" => ["(organization_id, last_attempt_at)",
                                          "WHERE ((status = ANY (ARRAY['delivered'::text, 'failed'::text])) AND (held_at IS NULL))"],
    "webhook_deliveries_held_idx" => ["(organization_id, endpoint_id, created_at)", "WHERE (held_at IS NOT NULL)"],
    "inbound_webhooks_processed_idx" => ["(organization_id, processed_at)", "WHERE (status = ANY (ARRAY['processed'::text, 'ignored'::text]))"],
    "worker_outcome_totals_pkey" => ["(family, outcome)", nil]
  }.freeze

  def setup
    @previous = Dir.mktmpdir("locentra-migrations")
    Dir.children(MIGRATIONS).sort.each { |file| FileUtils.cp(File.join(MIGRATIONS, file), @previous) unless file.start_with?("0017") }
    recreate_schema
    migrator(@previous).migrate
  end

  # O esquema completo volta a existir para os testes seguintes do mesmo processo.
  def teardown
    FileUtils.remove_entry(@previous) if @previous
    migrator(MIGRATIONS).migrate
  rescue Locentra::Infrastructure::Database::MigrationError
    TestDatabase.instance_variable_set(:@prepared, false)
    TestDatabase.prepare!
  end

  def migrator(directory) = Locentra::Infrastructure::Database::Migrator.new(url: TestDatabase.owner_url, directory: directory)

  def recreate_schema
    conn = TestDatabase.owner_connection
    conn.exec("DROP SCHEMA IF EXISTS public CASCADE")
    conn.exec("CREATE SCHEMA public")
    conn.exec("GRANT USAGE ON SCHEMA public TO locentra_app, locentra_worker")
  end

  # Consulta com o proprietário no contexto da organização (a RLS é forçada também para ele).
  def owner_query(tenant, sql, params = [])
    conn = TestDatabase.owner_connection
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [tenant.to_s])
    conn.exec_params(sql, params).to_a
  ensure
    conn&.exec("RESET app.tenant_id")
  end

  # Mesmo comando com o papel informado (aplicação ou worker), no contexto da organização.
  def role_exec(url, tenant, sql, params)
    conn = PG.connect(url)
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [tenant.to_s])
    conn.exec_params(sql, params).cmd_tuples
  ensure
    conn&.close
  end

  def forced_rls(table)
    TestDatabase.owner_connection.exec_params("SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = $1::regclass",
                                              [table]).getvalue(0, 0)
  end

  def legacy_organization
    id = SecureRandom.uuid
    owner_query(id, "INSERT INTO organizations (id, name, slug, created_at, updated_at) VALUES ($1, 'Locadora Legada', $2, $3, $3)",
                [id, "legada-#{id[0, 8]}", LEGACY_AT])
    id
  end

  def legacy_endpoint(org, active: true)
    id = SecureRandom.uuid
    owner_query(org, <<~SQL, [id, org, active, LEGACY_AT, active ? nil : LEGACY_AT])
      INSERT INTO webhook_endpoints (id, organization_id, url, events, secret_ciphertext, active, created_at, disabled_at)
      VALUES ($1, $2, 'https://erp.example/hook', '{*}', 'cifrado', $3, $4, $5)
    SQL
    id
  end

  def legacy_event(org, dispatched:)
    id = SecureRandom.uuid
    owner_query(org, <<~SQL, [id, org, SecureRandom.uuid, LEGACY_AT, dispatched ? LEGACY_AT : nil])
      INSERT INTO outbox_events (id, organization_id, event_type, aggregate_type, aggregate_id, occurred_at, dispatched_at)
      VALUES ($1, $2, 'reservation.confirmed', 'reservation', $3, $4, $5)
    SQL
    id
  end

  DELIVERY_SQL = <<~SQL
    INSERT INTO webhook_deliveries (id, organization_id, endpoint_id, event_id, event_type, status, attempts, created_at, last_attempt_at)
    VALUES ($1, $2, $3, $4, 'reservation.confirmed', $5, $6, $7, $8)
  SQL

  def legacy_delivery(org, endpoint, event, status)
    id = SecureRandom.uuid
    attempted = status == "pending" ? nil : LEGACY_AT
    owner_query(org, DELIVERY_SQL, [id, org, endpoint, event, status, attempted ? 1 : 0, LEGACY_AT, attempted])
    id
  end

  INBOUND_SQL = <<~SQL
    INSERT INTO inbound_webhooks (id, organization_id, provider, event_id, event_type, payload, status, received_at, processed_at)
    VALUES ($1, $2, 'asaas', $3, 'PAYMENT_RECEIVED', '{}', $4, $5, $6)
  SQL

  def legacy_inbound(org, status)
    owner_query(org, INBOUND_SQL, [SecureRandom.uuid, org, "evt-#{SecureRandom.hex(4)}", status, LEGACY_AT, status == "received" ? nil : LEGACY_AT])
  end

  def legacy_data
    org = legacy_organization
    active = legacy_endpoint(org)
    disabled = legacy_endpoint(org, active: false)
    dispatched = legacy_event(org, dispatched: true)
    legacy_event(org, dispatched: false)
    legacy_delivery(org, active, dispatched, "pending")
    legacy_delivery(org, active, legacy_event(org, dispatched: true), "delivered")
    legacy_delivery(org, disabled, dispatched, "failed")
    %w[received processed].each { |status| legacy_inbound(org, status) }
    { org: org, active: active, disabled: disabled, event: dispatched }
  end

  def test_upgrade_starts_with_a_closed_circuit_and_keeps_legacy_inserts_working
    data = legacy_data
    org = data[:org]

    assert_equal ["0017"], migrator(MIGRATIONS).migrate
    endpoints = owner_query(org, "SELECT active, consecutive_failures, failing_since, paused_at FROM webhook_endpoints ORDER BY active")

    assert_equal [["f", "0", nil, nil], ["t", "0", nil, nil]], endpoints.map(&:values)
    assert_equal([[3, 0]], owner_query(org, "SELECT count(*) AS total, count(held_at) AS held FROM webhook_deliveries").map { |row| row.values.map(&:to_i) })
    assert_equal(%w[t t t], TABLES.map { |table| forced_rls(table) })
    assert_new_indexes
    assert_checks(org, data)
    assert_legacy_inserts(org, data)
  end

  # Índices que não dependem de colunas novas, construídos antes com CONCURRENTLY (docs/RUNBOOKS.md §16.1)
  # com os comandos documentados: a migration os aproveita e cria só os demais.
  PREBUILT_INDEXES = <<~SQL.lines.map(&:strip).freeze
    CREATE INDEX CONCURRENTLY IF NOT EXISTS jobs_ready_org_idx ON jobs (queue, organization_id, priority, run_at) WHERE status = 'pending'
    CREATE INDEX CONCURRENTLY IF NOT EXISTS outbox_events_dispatched_idx ON outbox_events (organization_id, dispatched_at) WHERE dispatched_at IS NOT NULL
    CREATE INDEX CONCURRENTLY IF NOT EXISTS webhook_deliveries_event_idx ON webhook_deliveries (organization_id, event_id)
    CREATE INDEX CONCURRENTLY IF NOT EXISTS inbound_webhooks_processed_idx ON inbound_webhooks (organization_id, processed_at) WHERE status IN ('processed', 'ignored')
  SQL

  def test_upgrade_accepts_indexes_built_beforehand_concurrently
    legacy_data
    PREBUILT_INDEXES.each { |sql| TestDatabase.owner_connection.exec(sql) }

    assert_equal ["0017"], migrator(MIGRATIONS).migrate
    assert_new_indexes
    runbook = File.read(File.expand_path("../../docs/RUNBOOKS.md", __dir__))
    PREBUILT_INDEXES.each { |sql| assert_includes runbook, "#{sql};" }
  end

  # SQL da 1.2.0 (Redeliver e Deliver) sobre entregas retidas pela versão nova, como no retorno à 1.2.0 ou
  # num worker da 1.2.0 durante a implantação gradual: o reenvio e a entrega concluída liberam a retenção
  # em vez de violar o CHECK; a falha mantém a entrega retida para a versão nova.
  LEGACY_RESET_SQL = "UPDATE webhook_deliveries SET status = 'pending' WHERE organization_id = $1 AND id = $2"
  LEGACY_ATTEMPT_SQL = <<~SQL
    UPDATE webhook_deliveries
       SET status = $3, attempts = attempts + 1, last_status_code = $4, last_error = $5, last_attempt_at = $6,
           delivered_at = CASE WHEN $3 = 'delivered' THEN $6::timestamptz ELSE delivered_at END
     WHERE organization_id = $1 AND id = $2 AND status <> 'delivered'
  SQL

  def test_legacy_redelivery_and_attempts_release_held_deliveries
    data = legacy_data
    org = data[:org]
    migrator(MIGRATIONS).migrate
    failed, pending, retried, born_held = Array.new(4) { legacy_delivery(org, data[:active], legacy_event(org, dispatched: true), "failed") }
    ids = "{#{[failed, pending, retried, born_held].join(",")}}"
    owner_query(org, "UPDATE webhook_deliveries SET status = 'pending' WHERE id = ANY($1::uuid[])", ["{#{pending},#{born_held}}"])
    owner_query(org, "UPDATE webhook_deliveries SET held_at = $2 WHERE id = ANY($1::uuid[])", [ids, LEGACY_AT])

    assert_equal 1, role_exec(TestDatabase.app_url, org, LEGACY_RESET_SQL, [org, failed])
    assert_equal 1, role_exec(TestDatabase.app_url, org, LEGACY_RESET_SQL, [org, born_held])
    assert_equal 1, role_exec(TestDatabase.worker_url, org, LEGACY_ATTEMPT_SQL, [org, pending, "delivered", 200, nil, LEGACY_AT])
    assert_equal 1, role_exec(TestDatabase.worker_url, org, LEGACY_ATTEMPT_SQL, [org, retried, "failed", 503, nil, LEGACY_AT])
    states = owner_query(org, "SELECT id, status, held_at IS NOT NULL AS held FROM webhook_deliveries WHERE id = ANY($1::uuid[])", [ids])
             .to_h { |row| [row["id"], [row["status"], row["held"]]] }

    assert_equal({ failed => %w[pending f], born_held => %w[pending f], pending => %w[delivered f], retried => %w[failed t] }, states)
  end

  private

  def assert_new_indexes
    rows = TestDatabase.owner_connection.exec_params(<<~SQL, ["{#{INDEXES.keys.join(",")}}"]).to_h { |row| [row["indexname"], row["indexdef"]] }
      SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1::text[])
    SQL

    assert_equal INDEXES.keys.sort, rows.keys.sort
    INDEXES.each do |name, (columns, predicate)|
      assert_includes rows[name], columns, name
      predicate ? assert(rows[name].end_with?(predicate), "#{name}: #{rows[name]}") : refute_includes(rows[name], "WHERE", name)
    end
  end

  def assert_checks(org, data)
    assert_raises(PG::CheckViolation) { owner_query(org, "UPDATE webhook_endpoints SET consecutive_failures = -1, failing_since = now()") }
    assert_raises(PG::CheckViolation) { owner_query(org, "UPDATE webhook_endpoints SET failing_since = now() WHERE id = $1", [data[:active]]) }
    assert_raises(PG::CheckViolation) { owner_query(org, "UPDATE webhook_endpoints SET consecutive_failures = 3 WHERE id = $1", [data[:active]]) }
    assert_raises(PG::CheckViolation) { owner_query(org, "UPDATE webhook_deliveries SET held_at = now() WHERE status = 'delivered'") }
    assert_equal 1, owner_query(org, "UPDATE webhook_deliveries SET held_at = now() WHERE status = 'pending' RETURNING id").size
    streak = owner_query(org, "UPDATE webhook_endpoints SET consecutive_failures = 2, failing_since = now() WHERE id = $1 RETURNING id",
                         [data[:active]])

    assert_equal 1, streak.size
  end

  # Inserções sem as colunas novas, como a 1.2.0 faz, com os papéis da aplicação e do worker.
  def assert_legacy_inserts(org, data)
    endpoint_sql = <<~SQL
      INSERT INTO webhook_endpoints (id, organization_id, url, events, secret_ciphertext, created_at)
      VALUES ($1, $2, 'https://erp.example/novo', '{*}', 'cifrado', $3)
    SQL
    [TestDatabase.app_url, TestDatabase.worker_url].each do |url|
      endpoint = SecureRandom.uuid

      assert_equal 1, role_exec(url, org, endpoint_sql, [endpoint, org, LEGACY_AT])
      assert_equal 1, role_exec(url, org, <<~SQL, [SecureRandom.uuid, org, endpoint, data[:event], LEGACY_AT])
        INSERT INTO webhook_deliveries (id, organization_id, endpoint_id, event_id, event_type, created_at)
        VALUES ($1, $2, $3, $4, 'reservation.confirmed', $5)
      SQL
      fresh = owner_query(org, <<~SQL, [endpoint]).first
        SELECT w.consecutive_failures, w.failing_since, w.paused_at, d.held_at, d.status
          FROM webhook_endpoints w JOIN webhook_deliveries d ON d.organization_id = w.organization_id AND d.endpoint_id = w.id WHERE w.id = $1
      SQL

      assert_equal ["0", nil, nil, nil, "pending"], fresh.values
    end
  end
end
