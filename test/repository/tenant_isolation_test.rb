# frozen_string_literal: true

require_relative "repository_helper"

# Isolamento entre tenants com o papel de aplicação real (sem superuser e sem BYPASSRLS).
class TenantIsolationTest < DatabaseTest
  def setup
    super
    @a = create_organization(name: "Locadora Alfa", email: "alfa@example.test")
    @b = create_organization(name: "Locadora Beta", email: "beta@example.test")
    @customer_a = create_customer(@a[:actor], name: "Cliente da Alfa")
    @org = @a
  end

  def app_connection
    @app_connection ||= PG.connect(TestDatabase.app_url)
  end

  def teardown
    @app_connection&.close
    super
  end

  def test_application_role_has_no_bypass_privileges
    row = app_connection.exec("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user").first

    assert_equal "f", row["rolsuper"]
    assert_equal "f", row["rolbypassrls"]
    owner = app_connection.exec("SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tableowner = current_user").getvalue(0, 0)

    assert_equal "0", owner
  end

  # Toda tabela com organization_id tem RLS habilitada e forçada, exceto as exceções documentadas em
  # docs/ISOLAMENTO.md (sessions: a autenticação ocorre antes de existir contexto de organização).
  def test_every_table_with_organization_id_has_forced_row_level_security
    unprotected = app_connection.exec(<<~SQL).column_values(0)
      SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
         AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'organization_id' AND NOT a.attisdropped)
         AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
       ORDER BY c.relname
    SQL

    assert_equal %w[sessions], unprotected
  end

  def test_missing_tenant_context_denies_access
    app_connection.exec("BEGIN")
    count = app_connection.exec("SELECT count(*) FROM customers").getvalue(0, 0)
    app_connection.exec("ROLLBACK")

    assert_equal "0", count
  end

  def test_tenant_context_only_exposes_own_rows
    app_connection.exec("BEGIN")
    app_connection.exec_params("SELECT set_config('app.tenant_id', $1, true)", [@b[:organization_id]])
    names = app_connection.exec("SELECT name FROM customers").column_values(0)
    app_connection.exec("ROLLBACK")

    assert_empty names
  end

  def test_rls_rejects_writes_into_another_tenant
    app_connection.exec("BEGIN")
    app_connection.exec_params("SELECT set_config('app.tenant_id', $1, true)", [@b[:organization_id]])
    assert_raises(PG::InsufficientPrivilege) do
      app_connection.exec_params(<<~SQL, [SecureRandom.uuid, @a[:organization_id]])
        INSERT INTO customers (id, organization_id, kind, name, document, created_at, updated_at)
        VALUES ($1, $2, 'individual', 'Intruso', '11144477735', now(), now())
      SQL
    end
  ensure
    app_connection.exec("ROLLBACK")
  end

  def test_composite_foreign_keys_block_cross_tenant_references
    conn = TestDatabase.owner_connection
    conn.exec("BEGIN")
    conn.exec_params("SELECT set_config('app.tenant_id', $1, true)", [@b[:organization_id]])
    assert_raises(PG::ForeignKeyViolation) do
      conn.exec_params(<<~SQL, [SecureRandom.uuid, @b[:organization_id], @b[:branch].id, @customer_a.id])
        INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, starts_at, ends_at, created_at, updated_at)
        VALUES ($1, $2, $3, $4, 'X-1', 'requested', now(), now() + interval '1 hour', now(), now())
      SQL
    end
  ensure
    conn.exec("ROLLBACK")
  end

  def test_use_cases_do_not_leak_or_accept_foreign_ids
    assert_raises(D::NotFound) { uc(:get_customer).call(@b[:actor], @customer_a.id) }
    page = uc(:list_customers).call(@b[:actor])

    assert_equal 0, page.total
    camera = create_product(@a[:actor], sku: "CAM-A", tracking: "serialized")
    assert_raises(D::NotFound) do
      uc(:register_asset).call(@b[:actor], { product_id: camera.id, branch_id: @b[:branch].id, tag: "INVASOR" })
    end
  end

  # Cupons, usos, condições negociadas e tarifas de uma organização não aparecem no contexto de outra,
  # nem pela RLS (consulta direta com o papel de aplicação) nem pelos casos de uso.
  def test_commercial_terms_are_invisible_to_other_tenants
    chairs = create_product(@b[:actor], sku: "CAD-B", tracking: "bulk")
    customer_b = create_customer(@b[:actor], name: "Cliente da Beta")
    coupon = uc(:create_coupon).call(@b[:actor], { code: "SOBETA", kind: "percent", value: 1000 })
    fee = uc(:create_fee).call(@b[:actor], { code: "ENTREGA", name: "Entrega", default_amount: D::Money.new(15_000) })
    agreement = uc(:create_price_agreement).call(@b[:actor], customer_b.id, { discount_bps: 800 })
    reserve(@b[:actor], customer_b, @b[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(chairs, 1)], mode: "request",
                                                                                                                            coupon_code: "SOBETA")
    tables = %w[coupons coupon_redemptions customer_price_agreements additional_fees]
    counts = lambda do |organization|
      @system.transactor.call(tenant_id: organization[:organization_id]) do |tx|
        tables.map { |table| tx.query_value("SELECT count(*) FROM #{table}") }
      end
    end

    assert_equal [[0, 0, 0, 0], [1, 1, 1, 1]], [counts.call(@a), counts.call(@b)]
    app_connection.exec("BEGIN")
    without_context = tables.map { |table| app_connection.exec("SELECT count(*) FROM #{table}").getvalue(0, 0) }
    app_connection.exec("ROLLBACK")

    assert_equal %w[0 0 0 0], without_context
    assert_raises(D::NotFound) { uc(:get_coupon).call(@a[:actor], coupon.id) }
    assert_raises(D::NotFound) { uc(:get_coupon).call(@a[:actor], "SOBETA") }
    assert_raises(D::NotFound) { uc(:get_fee).call(@a[:actor], fee.id) }
    assert_raises(D::NotFound) { uc(:list_price_agreements).call(@a[:actor], customer_b.id) }
    assert_raises(D::NotFound) { uc(:end_price_agreement).call(@a[:actor], agreement.id, reason: "Tentativa indevida") }
    assert_equal [0, 0], [uc(:list_coupons).call(@a[:actor]).total, uc(:list_fees).call(@a[:actor]).total]
  end

  def test_tenant_from_parameters_is_not_authorization
    forged = A::Actor.user(user_id: @b[:user_id], organization_id: @a[:organization_id], role: "owner")

    assert_raises(D::AccessDenied) { uc(:list_customers).call(forged) }
  end

  def test_membership_revocation_takes_effect_immediately
    invite = uc(:invite_member).call(@a[:actor], email: "atendente@example.test", role: "attendant")
    token = "#{@a[:organization_id]}.segredo-de-teste-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    joined = uc(:accept_invitation).call(token: token, name: "Atendente", password: "senha-muito-segura-2")
    member = A::Actor.user(user_id: joined[:user_id], organization_id: @a[:organization_id], role: "attendant")

    assert_equal 1, uc(:list_customers).call(member).total
    assert_raises(D::AccessDenied) { uc(:create_branch).call(member, name: "Filial", code: "F2") }
    membership = uc(:list_members).call(@a[:actor])[:members].find { |m| m["user_id"] == joined[:user_id] }
    uc(:revoke_membership).call(@a[:actor], membership_id: membership["id"])

    assert_raises(D::AccessDenied) { uc(:list_customers).call(member) }
  end

  def test_jobs_and_outbox_are_tenant_scoped_for_application_role
    camera = create_product(@a[:actor], sku: "CAM-J", tracking: "serialized")
    register_assets(@a[:actor], camera, @a[:branch], 1)
    reserve(@a[:actor], @customer_a, @a[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z"), [line(camera, 1)])
    visible = @system.transactor.call(tenant_id: @b[:organization_id]) { |tx| tx.query_value("SELECT count(*) FROM outbox_events") }

    assert_equal 0, visible
    own = @system.transactor.call(tenant_id: @a[:organization_id]) { |tx| tx.query_value("SELECT count(*) FROM outbox_events") }

    assert_operator own, :>, 0
  end

  def test_user_sees_only_organizations_with_active_membership
    orgs = uc(:list_memberships).call(@a[:user_id])

    assert_equal([@a[:organization_id]], orgs.map { |o| o["organization_id"] })
  end
end
