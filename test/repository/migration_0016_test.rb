# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "repository_helper"

# Atualização de um banco da versão 1.1.0 (migrations 0001 a 0015) para a 0016, com dados legados gravados
# por SQL no formato da 1.1.0: política de cancelamento copiada do contrato ou das configurações para as
# reservas, versões de orçamento já enviadas preenchidas com a proteção reativada, JSON null removido das
# configurações, RLS forçada restaurada e inserções no formato antigo aceitas pelo gatilho de
# preenchimento. Configurações fora do formato abortam a migration sem alterar nada. O esquema completo é
# recriado ao final.
class Migration0016Test < Minitest::Test
  MIGRATIONS = File.expand_path("../../db/migrations", __dir__)
  LEGACY_AT = "2026-01-05T12:00:00Z"
  DEFAULT_POLICY = { "tiers" => [{ "min_hours_before" => 72, "fee_bps" => 0 }, { "min_hours_before" => 24, "fee_bps" => 3000 },
                                 { "min_hours_before" => 0, "fee_bps" => 10_000 }] }.freeze
  CUSTOM_POLICY = { "tiers" => [{ "min_hours_before" => 48, "fee_bps" => 1000 }, { "min_hours_before" => 0, "fee_bps" => 5000 }] }.freeze
  CONTRACT_POLICY = { "tiers" => [{ "min_hours_before" => 96, "fee_bps" => 500 }, { "min_hours_before" => 0, "fee_bps" => 8000 }] }.freeze
  TABLES = %w[organizations branches reservations quote_versions contracts].freeze

  def setup
    @previous = Dir.mktmpdir("locentra-migrations")
    Dir.children(MIGRATIONS).sort.each { |file| FileUtils.cp(File.join(MIGRATIONS, file), @previous) unless file.start_with?("0016") }
    recreate_schema
    migrator(@previous).migrate
  end

  # O esquema completo volta a existir para os testes seguintes do mesmo processo: a 0016 é aplicada se
  # ainda estiver pendente; se os dados do teste a impedirem, o esquema é recriado do zero.
  def teardown
    @system&.shutdown
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

  def json(value) = JSON.generate(value)
  def jsonb(tenant, sql, params = []) = JSON.parse(owner_query(tenant, sql, params).first.values.first)

  def forced_rls(table)
    TestDatabase.owner_connection.exec_params("SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = $1::regclass",
                                              [table]).getvalue(0, 0)
  end

  def legacy_organization(slug, settings)
    id = SecureRandom.uuid
    owner_query(id, <<~SQL, [id, "Locadora #{slug}", slug, settings, LEGACY_AT])
      INSERT INTO organizations (id, name, slug, settings, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $5)
    SQL
    id
  end

  def legacy_branch(org, code, active: true)
    id = SecureRandom.uuid
    owner_query(org, <<~SQL, [id, org, "Filial #{code}", code, active, LEGACY_AT])
      INSERT INTO branches (id, organization_id, name, code, active, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $6)
    SQL
    id
  end

  def legacy_customer(org)
    id = SecureRandom.uuid
    owner_query(org, <<~SQL, [id, org, LEGACY_AT])
      INSERT INTO customers (id, organization_id, kind, name, document, created_at, updated_at)
      VALUES ($1, $2, 'individual', 'Cliente Legado', '52998224725', $3, $3)
    SQL
    id
  end

  def legacy_product(org)
    id = SecureRandom.uuid
    owner_query(org, <<~SQL, [id, org, LEGACY_AT])
      INSERT INTO products (id, organization_id, sku, name, tracking, pricing, created_at, updated_at)
      VALUES ($1, $2, 'CAD-LEG', 'Cadeira', 'bulk', '{"daily_cents": 10000}', $3, $3)
    SQL
    id
  end

  # Reserva no formato da 1.1.0: sem a coluna cancellation_policy.
  def legacy_reservation(org, branch, customer, code)
    id = SecureRandom.uuid
    owner_query(org, <<~SQL, [id, org, branch, customer, code, LEGACY_AT])
      INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, starts_at, ends_at, pricing, total_cents,
                                created_at, updated_at, confirmed_at)
      VALUES ($1, $2, $3, $4, $5, 'confirmed', '2026-04-01T08:00:00Z', '2026-04-02T08:00:00Z',
              '{"timezone": "America/Sao_Paulo", "total_cents": 10000}', 10000, $6, $6, $6)
    SQL
    id
  end

  def legacy_contract(org, reservation, customer, policy)
    id = SecureRandom.uuid
    terms = { "cancellation_policy" => policy, "period" => { "timezone" => "America/Sao_Paulo" }, "contracted_total_cents" => 10_000 }
    owner_query(org, <<~SQL, [id, org, reservation, customer, json(terms), LEGACY_AT])
      INSERT INTO contracts (id, organization_id, code, reservation_id, customer_id, terms_snapshot, issued_at, updated_at)
      VALUES ($1, $2, 'C-000001', $3, $4, $5, $6, $6)
    SQL
    id
  end

  # Orçamento enviado com a versão 1 já enviada (sent_at preenchido), no formato da 1.1.0.
  def legacy_sent_quote(org, branch, customer, product)
    quote = SecureRandom.uuid
    owner_query(org, <<~SQL, [quote, org, customer, branch, LEGACY_AT])
      INSERT INTO quotes (id, organization_id, code, customer_id, branch_id, status, sent_at, created_at, updated_at)
      VALUES ($1, $2, 'Q-000001', $3, $4, 'sent', $5, $5, $5)
    SQL
    legacy_version(org, quote, branch, product, number: 1, sent: true)
    quote
  end

  def legacy_version(org, quote, branch, product, number:, sent:)
    id = SecureRandom.uuid
    items = json([{ "product_id" => product, "quantity" => 1, "total_cents" => 10_000 }])
    owner_query(org, <<~SQL, [id, org, quote, number, branch, items, LEGACY_AT, sent ? LEGACY_AT : nil])
      INSERT INTO quote_versions (id, organization_id, quote_id, version, branch_id, starts_at, ends_at, valid_until, items, pricing,
                                  deposit_cents, total_cents, created_at, sent_at)
      VALUES ($1, $2, $3, $4, $5, '2026-04-01T08:00:00Z', '2026-04-02T08:00:00Z', '2026-03-30T08:00:00Z', $6, '{}', 0, 10000, $7, $8)
    SQL
    id
  end

  def reservation_policy(org, id) = jsonb(org, "SELECT cancellation_policy FROM reservations WHERE id = $1", [id])
  def version_policy(org, id) = jsonb(org, "SELECT cancellation_policy FROM quote_versions WHERE id = $1", [id])
  def settings_of(org) = jsonb(org, "SELECT settings FROM organizations WHERE id = $1", [org])

  def legacy_data
    custom = legacy_organization("personalizada", json("cancellation_policy" => CUSTOM_POLICY, "hold_minutes" => 45, "tema" => "escuro"))
    empty = legacy_organization("vazia", "{}")
    nulls = legacy_organization("nula", json("cancellation_policy" => nil, "hold_minutes" => nil))
    data = { custom: custom, empty: empty, nulls: nulls }
    branch = legacy_branch(custom, "MATRIZ")
    customer = legacy_customer(custom)
    product = legacy_product(custom)
    data.merge(branch: branch, inactive_branch: legacy_branch(custom, "ANTIGA", active: false), customer: customer, product: product,
               with_contract: legacy_reservation(custom, branch, customer, "R-000001").tap { |r| legacy_contract(custom, r, customer, CONTRACT_POLICY) },
               without_contract: legacy_reservation(custom, branch, customer, "R-000002"),
               empty_reservation: legacy_reservation(empty, legacy_branch(empty, "MATRIZ"), legacy_customer(empty), "R-000001"),
               quote: legacy_sent_quote(custom, branch, customer, product))
  end

  def test_upgrade_copies_policies_into_the_records_and_keeps_legacy_inserts_working
    data = legacy_data
    custom = data[:custom]
    sent_version = owner_query(custom, "SELECT id FROM quote_versions WHERE quote_id = $1", [data[:quote]]).first["id"]

    assert_equal ["0016"], migrator(MIGRATIONS).migrate
    assert_equal(%w[t t t t t], TABLES.map { |table| forced_rls(table) })
    assert_equal CONTRACT_POLICY, reservation_policy(custom, data[:with_contract]), "o snapshot do contrato tem prioridade"
    assert_equal CUSTOM_POLICY, reservation_policy(custom, data[:without_contract])
    assert_equal DEFAULT_POLICY, reservation_policy(data[:empty], data[:empty_reservation])
    assert_equal CUSTOM_POLICY, version_policy(custom, sent_version)
    assert_equal({ "cancellation_policy" => CUSTOM_POLICY, "hold_minutes" => 45, "tema" => "escuro" }, settings_of(custom))
    assert_empty settings_of(data[:nulls]), "valores JSON null são removidos"
    assert_equal(%w[1 1 1], [custom, data[:empty], data[:nulls]].map { |org| owner_query(org, "SELECT lock_version FROM organizations").first["lock_version"] })
    branches = owner_query(custom, "SELECT code, active, deactivated_at IS NOT NULL AS deactivated, lock_version FROM branches ORDER BY code")

    assert_equal [%w[ANTIGA f t 1], %w[MATRIZ t f 1]], branches.map(&:values)
    nullable = TestDatabase.owner_connection.exec(<<~SQL).to_a.map(&:values)
      SELECT table_name, is_nullable, column_default IS NULL FROM information_schema.columns
       WHERE column_name = 'cancellation_policy' AND table_schema = 'public' ORDER BY table_name
    SQL

    assert_equal [%w[quote_versions NO t], %w[reservations NO t]], nullable
    refused = assert_raises(PG::CheckViolation) { owner_query(custom, "UPDATE quote_versions SET terms = 'Alterado' WHERE id = $1", [sent_version]) }

    assert_includes refused.message, "o envio da versão do orçamento é registrado uma única vez", "a proteção da versão enviada foi reativada"
    legacy_insert = legacy_reservation(custom, data[:branch], data[:customer], "R-000003")
    draft = legacy_version(custom, data[:quote], data[:branch], data[:product], number: 2, sent: false)

    assert_equal CUSTOM_POLICY, reservation_policy(custom, legacy_insert), "inserção no formato da 1.1.0 recebe a política das configurações"
    assert_equal CUSTOM_POLICY, version_policy(custom, draft)
    empty = data[:empty]
    empty_branch, empty_customer = %w[branches customers].map { |table| owner_query(empty, "SELECT id FROM #{table}").first["id"] }

    assert_equal DEFAULT_POLICY, reservation_policy(empty, legacy_reservation(empty, empty_branch, empty_customer, "R-000002"))
    read_with_the_application(custom, data)
  end

  # Só depois da migration a aplicação é montada: a organização e as filiais são lidas pelo papel de aplicação.
  def read_with_the_application(org, data)
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: StringIO.new, level: "error")
    @system = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), logger: logger)
    result = @system.use_cases[:get_organization].call(Locentra::Application::Actor.system(organization_id: org))

    assert_equal ["Locadora personalizada", CUSTOM_POLICY, 45], [result[:organization].name, result[:organization].cancellation_policy,
                                                                 result[:organization].hold_minutes]
    assert_equal({ "ANTIGA" => false, "MATRIZ" => true }, result[:branches].to_h { |branch| [branch.code, branch.active] })
    assert_equal data[:inactive_branch], result[:branches].find { |branch| branch.code == "ANTIGA" }.id
  end

  def test_upgrade_aborts_with_the_organizations_whose_settings_are_out_of_shape
    not_object = legacy_organization("lista", "[]")
    no_tiers = legacy_organization("sem-faixas", json("cancellation_policy" => { "faixas" => [] }))
    bad_hold = legacy_organization("validade", json("hold_minutes" => "2 horas"))
    valid = legacy_organization("valida", json("cancellation_policy" => CUSTOM_POLICY, "hold_minutes" => nil))
    error = assert_raises(Locentra::Infrastructure::Database::MigrationError) { migrator(MIGRATIONS).migrate }

    assert_includes error.message, "falha na migration 0016_configuracoes_organizacao"
    assert_includes error.message, "configurações (settings) fora do formato esperado nas organizações #{[not_object, no_tiers, bad_hold].sort.join(", ")}"
    refute_includes error.message, valid
    conn = TestDatabase.owner_connection

    refute_includes conn.exec("SELECT version FROM schema_migrations").column_values(0), "0016", "a transação da migration é desfeita por inteiro"
    assert_nil conn.exec("SELECT to_regprocedure('app_default_cancellation_policy()')").getvalue(0, 0)
    assert_equal "f", conn.exec("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'organizations' " \
                                "AND column_name = 'lock_version')").getvalue(0, 0)
    assert_equal({ "cancellation_policy" => CUSTOM_POLICY, "hold_minutes" => nil }, settings_of(valid), "nada é alterado")
    assert_equal(%w[t t t t t], TABLES.map { |table| forced_rls(table) })
  end
end
