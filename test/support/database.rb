# frozen_string_literal: true

require "pg"
require "locentra/system"

# Banco de testes: schema recriado uma vez por processo com as migrations reais e limpo entre testes.
# Os testes usam o papel de aplicação (sem superuser, sem BYPASSRLS) para exercitar RLS e grants.
module TestDatabase
  TABLES_TO_KEEP = %w[schema_migrations plans].freeze

  module_function

  def owner_url = ENV.fetch("TEST_MIGRATION_DATABASE_URL")
  def app_url = ENV.fetch("TEST_DATABASE_URL")
  def worker_url = ENV.fetch("TEST_WORKER_DATABASE_URL")

  def prepare!
    return if @prepared

    conn = PG.connect(owner_url)
    conn.exec("SET client_min_messages = warning")
    conn.exec("DROP SCHEMA IF EXISTS public CASCADE")
    conn.exec("CREATE SCHEMA public")
    conn.exec("GRANT USAGE ON SCHEMA public TO locentra_app, locentra_worker")
    conn.close
    Locentra::Infrastructure::Database::Migrator.new(url: owner_url, directory: File.expand_path("../../db/migrations", __dir__)).migrate
    @prepared = true
  end

  def clean!
    conn = owner_connection
    tables = conn.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").column_values(0) - TABLES_TO_KEEP
    conn.exec("TRUNCATE #{tables.map { |t| conn.quote_ident(t) }.join(", ")} RESTART IDENTITY CASCADE") unless tables.empty?
  end

  def owner_connection
    @owner_connection ||= PG.connect(owner_url).tap { |c| c.exec("SET client_min_messages = warning") }
  end

  def env(overrides = {})
    {
      "APP_ENV" => "test", "DATABASE_URL" => app_url, "WORKER_DATABASE_URL" => worker_url, "MIGRATION_DATABASE_URL" => owner_url,
      "APP_SECRET_KEY_BASE" => "test-secret-key-base-0123456789abcdef0123456789",
      "APP_ENCRYPTION_KEY" => "test-encryption-key-0123456789",
      "DB_POOL_SIZE" => "8", "LOG_LEVEL" => "error", "BCRYPT_COST" => "4",
      "STORAGE_ROOT" => File.expand_path("../../tmp/test-storage", __dir__)
    }.merge(overrides)
  end
end

class DatabaseTest < Minitest::Test
  include TimeHelpers

  D = Locentra::Domain
  A = Locentra::Application

  def setup
    TestDatabase.prepare!
    TestDatabase.clean!
    @clock = TestClock.new(Time.utc(2026, 3, 2, 12, 0, 0))
    @log = StringIO.new
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: @log, level: "error")
    @system = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: logger)
  end

  def teardown
    @system&.shutdown
  end

  def uc(name) = @system.use_cases[name]

  # Cria organização completa e devolve o ator proprietário.
  def create_organization(name: "Locadora Alfa", email: "dona@alfa.test", plan: "profissional")
    result = uc(:sign_up).call(name: "Dona #{name}", email: email, password: "senha-muito-segura-1", organization_name: name, plan_id: plan)
    actor = A::Actor.user(user_id: result[:user_id], organization_id: result[:organization_id], role: "owner")
    branch = uc(:get_organization).call(actor)[:branches].first
    { actor: actor, branch: branch, organization_id: result[:organization_id], user_id: result[:user_id] }
  end

  def create_customer(actor, name: "Cliente Teste", document: "52998224725", kind: "individual")
    uc(:create_customer).call(actor, { kind: kind, name: name, document: document, email: "cliente@example.test" })
  end

  def create_product(actor, sku:, tracking:, name: nil, pricing: { "daily_cents" => 10_000 }, **extra)
    uc(:create_product).call(actor, { sku: sku, name: name || "Produto #{sku}", tracking: tracking, pricing: pricing, **extra })
  end

  def register_assets(actor, product, branch, count, prefix: product.sku)
    Array.new(count) { |i| uc(:register_asset).call(actor, { product_id: product.id, branch_id: branch.id, tag: "#{prefix}-#{i + 1}" }) }
  end

  def stock(actor, product, branch, quantity)
    uc(:adjust_stock).call(actor, product_id: product.id, branch_id: branch.id, quantity: quantity, kind: "acquisition")
  end

  def line(product, quantity) = D::Reservations::Line.new(product_id: product.id, quantity: quantity)

  def reserve(actor, customer, branch, period, lines, mode: "hold", **extra)
    uc(:create_reservation).call(actor,
                                 { customer_id: customer.id, branch_id: branch.id, period: period, lines: lines, mode: mode, **extra })
  end

  # Consulta de verificação com o papel proprietário. Como a RLS é forçada também para o
  # proprietário, o contexto de tenant precisa ser informado explicitamente.
  def owner_query(sql, params = [], tenant: @org && @org[:organization_id])
    conn = TestDatabase.owner_connection
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [tenant.to_s])
    conn.exec_params(sql, params).to_a
  ensure
    conn&.exec("RESET app.tenant_id")
  end
end
