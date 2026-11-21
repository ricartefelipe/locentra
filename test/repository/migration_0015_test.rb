# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "repository_helper"

# Atualização de um banco da versão 1.0.0 (migrations 0001 a 0014) para a 0015: preenchimento das
# colunas novas com a RLS forçada restaurada, contador legado de cupons preservado como base dos usos
# e recusa de condições negociadas sobrepostas. O esquema completo é recriado ao final.
class Migration0015Test < Minitest::Test
  include TimeHelpers

  D = Locentra::Domain
  MIGRATIONS = File.expand_path("../../db/migrations", __dir__)
  LEGACY_AT = "2026-01-05T12:00:00Z"

  def setup
    @previous = Dir.mktmpdir("locentra-migrations")
    Dir.children(MIGRATIONS).sort.each { |file| FileUtils.cp(File.join(MIGRATIONS, file), @previous) unless file.start_with?("0015") }
    recreate_schema
    migrator(@previous).migrate
    @clock = TestClock.new(Time.utc(2026, 3, 2, 12, 0, 0))
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: StringIO.new, level: "error")
    @system = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: logger)
    result = uc(:sign_up).call(name: "Dona Legada", email: "dona@legado.test", password: "senha-muito-segura-1",
                               organization_name: "Locadora Legada", plan_id: "profissional")
    @organization_id = result[:organization_id]
    @actor = Locentra::Application::Actor.user(user_id: result[:user_id], organization_id: @organization_id, role: "owner")
    @branch = uc(:get_organization).call(@actor)[:branches].first
    @customer = uc(:create_customer).call(@actor, { kind: "individual", name: "Cliente Legado", document: "52998224725" })
    @chairs = uc(:create_product).call(@actor, { sku: "CAD-LEG", name: "Cadeira", tracking: "bulk", pricing: { "daily_cents" => 10_000 } })
  end

  # O esquema completo volta a existir para os testes seguintes do mesmo processo: a 0015 é aplicada se
  # ainda estiver pendente; se os dados do teste a impedirem, o esquema é recriado do zero.
  def teardown
    @system&.shutdown
    FileUtils.remove_entry(@previous) if @previous
    migrator(MIGRATIONS).migrate
  rescue Locentra::Infrastructure::Database::MigrationError
    TestDatabase.instance_variable_set(:@prepared, false)
    TestDatabase.prepare!
  end

  def uc(name) = @system.use_cases[name]
  def migrator(directory) = Locentra::Infrastructure::Database::Migrator.new(url: TestDatabase.owner_url, directory: directory)

  def recreate_schema
    conn = TestDatabase.owner_connection
    conn.exec("DROP SCHEMA IF EXISTS public CASCADE")
    conn.exec("CREATE SCHEMA public")
    conn.exec("GRANT USAGE ON SCHEMA public TO locentra_app, locentra_worker")
  end

  def owner_query(sql, params = [])
    conn = TestDatabase.owner_connection
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [@organization_id])
    conn.exec_params(sql, params).to_a
  ensure
    conn&.exec("RESET app.tenant_id")
  end

  def legacy_coupon(code, redemptions:, max:, valid_from: nil, valid_until: nil, active: true)
    id = SecureRandom.uuid
    owner_query(<<~SQL, [id, @organization_id, code, max, redemptions, LEGACY_AT, valid_from, valid_until, active])
      INSERT INTO coupons (id, organization_id, code, kind, value, max_redemptions, redemptions, created_at, valid_from, valid_until, active)
      VALUES ($1, $2, $3, 'percent', 1000, $4, $5, $6, $7, $8, $9)
    SQL
    id
  end

  def errors_of(&) = assert_raises(D::ValidationError, &).errors

  def legacy_agreement(bps, valid_until: nil, product_id: nil)
    id = SecureRandom.uuid
    owner_query(<<~SQL, [id, @organization_id, @customer.id, product_id, bps, valid_until, LEGACY_AT])
      INSERT INTO customer_price_agreements (id, organization_id, customer_id, product_id, discount_bps, valid_until, created_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
    SQL
    id
  end

  def forced_rls(table)
    TestDatabase.owner_connection.exec_params("SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = $1::regclass", [table]).getvalue(0, 0)
  end

  def book(day, **extra)
    window = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
    line = D::Reservations::Line.new(product_id: @chairs.id, quantity: 1)
    uc(:create_reservation).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: window, lines: [line], mode: "request", **extra })
  end

  def test_upgrade_fills_new_columns_and_keeps_the_legacy_counter_as_the_base
    coupon_id = legacy_coupon("LEGADO", redemptions: 1, max: 2)
    agreement_id = legacy_agreement(500)
    inverted_id = legacy_agreement(900, valid_until: "2026-01-01T00:00:00Z")

    assert_equal ["0015"], migrator(MIGRATIONS).migrate
    assert_equal(%w[t t t t], %w[coupons customer_price_agreements coupon_redemptions additional_fees].map { |table| forced_rls(table) })
    coupon = owner_query("SELECT updated_at = created_at AS filled, lock_version, redemptions FROM coupons WHERE id = $1", [coupon_id]).first

    assert_equal %w[t 1 1], coupon.values
    filled = owner_query("SELECT id, valid_from = created_at AS filled FROM customer_price_agreements ORDER BY discount_bps")

    assert_equal [[agreement_id, "t"], [inverted_id, "t"]], filled.map(&:values)
    data = uc(:get_coupon).call(@actor, "LEGADO")

    assert_equal ["1 de 2", 1, 1, false], [data[:coupon].usage_text, data[:coupon].legacy_redemptions, data[:coupon].total_redemptions, data[:deletable]]
    assert_equal "coupon_in_use", assert_raises(D::Conflict) { uc(:delete_coupon).call(@actor, "LEGADO") }.code
    reservation = book(10, coupon_code: "legado")
    summary = uc(:get_reservation).call(@actor, reservation.id)[:pricing][:summary]

    assert_equal [9_500, 950, agreement_id], [summary["subtotal_cents"], summary["coupon_discount_cents"], summary["agreements"].first["id"]]
    assert_equal(["2 de 2", 2], uc(:get_coupon).call(@actor, "LEGADO")[:coupon].then { |c| [c.usage_text, c.total_redemptions] })
    error = assert_raises(D::ValidationError) { book(12, coupon_code: "LEGADO") }

    assert_equal({ "cupom" => ["cupom esgotado"] }, error.errors)
    assert_equal "1", owner_query("SELECT redemptions FROM coupons WHERE id = $1", [coupon_id]).first["redemptions"], "o contador legado fica congelado"
    statuses = uc(:list_price_agreements).call(@actor, @customer.id).items.to_h { |item| [item[:agreement].id, item[:status]] }

    assert_equal({ agreement_id => "active", inverted_id => "expired" }, statuses)
    ended = uc(:end_price_agreement).call(@actor, agreement_id, reason: "Contrato encerrado")

    assert_equal @clock.now, ended.ended_at, "a condição legada aceita o encerramento"
  end

  # A 1.0.0 aceitava fim anterior ao início e máximo acima de 1.000.000. Depois da 0015, esses cupons
  # continuam desativáveis e reativáveis (a contenção nunca é bloqueada); a edição exige corrigir o campo
  # inválido, com o erro no próprio campo, e o banco recusa gravar valores novos fora do limite.
  def test_legacy_coupons_outside_the_new_limits_can_be_deactivated_and_reactivated
    legacy_coupon("INVERTIDO", redemptions: 0, max: nil, valid_from: "2026-06-01T00:00:00Z", valid_until: "2026-05-01T00:00:00Z")
    legacy_coupon("GRANDE", redemptions: 0, max: 5_000_000)
    legacy_coupon("GRANDEINATIVO", redemptions: 0, max: 5_000_000, active: false)

    assert_equal ["0015"], migrator(MIGRATIONS).migrate
    %w[INVERTIDO GRANDE].each do |code|
      result = uc(:set_coupon_active).call(@actor, code, active: false)

      assert_equal [true, false, @clock.now], [result.changed, result.record.active, result.record.deactivated_at], code
      assert_equal "inactive", uc(:get_coupon).call(@actor, code)[:status], code
    end
    assert_equal({ "cupom" => ["cupom desativado"] }, errors_of { book(10, coupon_code: "GRANDE") })
    reactivated = %w[GRANDE GRANDEINATIVO].map { |code| uc(:set_coupon_active).call(@actor, code, active: true).record.active }

    assert_equal [true, true], reactivated
    assert_equal ["entre 1 e 1.000.000"], errors_of { uc(:update_coupon).call(@actor, "GRANDE", { description: "Legado" }) }["maximo_usos"]
    assert_equal ["deve ser posterior ao início da vigência"],
                 errors_of { uc(:update_coupon).call(@actor, "INVERTIDO", { description: "Legado" }) }["valido_ate"]
    fixed = uc(:update_coupon).call(@actor, "GRANDE", { description: "Legado", max_redemptions: 1_000_000 }).record

    assert_equal ["Legado", 1_000_000], [fixed.description, fixed.max_redemptions]
    refused = ["max_redemptions = 1000001", "valid_from = '2026-04-01T00:00:00Z', valid_until = '2026-04-01T00:00:00Z'"].map do |change|
      assert_raises(PG::CheckViolation) { owner_query("UPDATE coupons SET #{change} WHERE code = 'GRANDE'") }.message[/ERROR:  ([^\n]+)/, 1]
    end

    assert_equal ["o máximo de usos do cupom é 1.000.000", "o fim da vigência do cupom deve ser posterior ao início"], refused
  end

  def test_upgrade_refuses_overlapping_legacy_agreements
    legacy_agreement(500)
    legacy_agreement(800)
    legacy_agreement(700, product_id: @chairs.id)
    error = assert_raises(Locentra::Infrastructure::Database::MigrationError) { migrator(MIGRATIONS).migrate }

    assert_includes error.message, "falha na migration 0015_condicoes_comerciais"
    assert_includes error.message, "1 par(es) de condições negociadas com vigências sobrepostas (organização #{@organization_id}, cliente #{@customer.id})"
    assert_includes error.message, "docs/RUNBOOKS.md"
    conn = TestDatabase.owner_connection

    assert_equal "0014", conn.exec("SELECT max(version) FROM schema_migrations").getvalue(0, 0), "a transação da migration é desfeita por inteiro"
    assert_nil conn.exec("SELECT to_regclass('public.coupon_redemptions')").getvalue(0, 0)
    assert_equal(%w[t t], %w[coupons customer_price_agreements].map { |table| forced_rls(table) })
    owner_query("UPDATE customer_price_agreements SET valid_until = created_at WHERE discount_bps = 500")

    assert_equal ["0015"], migrator(MIGRATIONS).migrate, "depois do ajuste da vigência a migration aplica"
  end
end
