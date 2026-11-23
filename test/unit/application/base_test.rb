# frozen_string_literal: true

require_relative "../unit_helper"

# Casos de uso testados com fakes pequenos nas fronteiras (sem banco).
class ApplicationBaseTest < UnitTest
  A = Locentra::Application
  CONFIRMED_AT = Time.utc(2026, 1, 5, 9, 0, 0)

  FakeTx = Struct.new(:tenant_id, :user_id, :actor) do
    def tenant_id! = tenant_id || raise(Locentra::Domain::AccessDenied)
    def savepoint = yield
  end

  class FakeTransactor
    attr_reader :calls

    def initialize = @calls = []

    def call(tenant_id: nil, user_id: nil, actor: nil, **)
      @calls << tenant_id
      yield FakeTx.new(tenant_id, user_id, actor)
    end
  end

  class FakeAccess
    def initialize(memberships: {}, credentials: {}, portal: {})
      @memberships = memberships
      @credentials = credentials
      @portal = portal
    end

    def active_membership(_tx, org, user) = @memberships[[org, user]]
    def active_credential(_tx, id, _now) = @credentials[id]
    def active_portal_access(_tx, org, user) = @portal[[org, user]]
  end

  def uow(access)
    A::UnitOfWork.new(transactor: FakeTransactor.new, access: access, clock: TestClock.new)
  end

  def test_unit_of_work_refreshes_role_from_current_membership
    membership = { "id" => "m1", "role" => "auditor", "email_confirmed_at" => CONFIRMED_AT, "user_created_at" => CONFIRMED_AT }
    access = FakeAccess.new(memberships: { %w[o1 u1] => membership })
    actor = A::Actor.user(user_id: "u1", organization_id: "o1", role: "owner")

    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(actor, "reservations.write") { :ok } }
    assert_equal "auditor", uow(access).run(actor, "audit.read") { |_tx, current| current.role }
  end

  def test_unit_of_work_denies_revoked_or_missing_context
    access = FakeAccess.new
    actor = A::Actor.user(user_id: "u1", organization_id: "o1", role: "owner")

    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(actor) { :ok } }
    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(actor.with(organization_id: nil)) { :ok } }
  end

  def test_credentials_use_scopes_and_must_belong_to_tenant
    access = FakeAccess.new(credentials: { "c1" => { "organization_id" => "o1", "kind" => "api", "scopes" => ["customers.read"] },
                                           "c2" => { "organization_id" => "o2", "kind" => "api", "scopes" => ["customers.read"] } })
    api = A::Actor.credential(kind: "api", credential_id: "c1", organization_id: "o1", scopes: ["reservations.write"])

    assert_equal :ok, uow(access).run(api, "customers.read") { :ok }, "escopos são recarregados do banco"
    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(api, "reservations.write") { :ok } }
    forged = A::Actor.credential(kind: "api", credential_id: "c2", organization_id: "o1", scopes: ["customers.read"])

    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(forged, "customers.read") { :ok } }
  end

  def test_credential_kind_must_match_the_actor_kind
    access = FakeAccess.new(credentials: { "c1" => { "organization_id" => "o1", "kind" => "api", "scopes" => ["jobs.manage"] },
                                           "c2" => { "organization_id" => "o1", "kind" => "cli", "scopes" => ["jobs.manage"] } })
    as_cli = A::Actor.credential(kind: "cli", credential_id: "c1", organization_id: "o1", scopes: ["jobs.manage"])

    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(as_cli, "jobs.manage") { :ok } }
    assert_equal "cli", uow(access).run(as_cli.with(credential_id: "c2"), "jobs.manage") { |_tx, current| current.kind }
  end

  def test_customer_actor_is_restricted_to_portal_permission
    access = FakeAccess.new(portal: { %w[o1 u9] => { "id" => "p1", "customer_id" => "cust" } })
    customer = A::Actor.customer(user_id: "u9", organization_id: "o1", customer_id: "cust")

    assert_equal :ok, uow(access).run(customer, "portal.access") { :ok }
    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(customer, "customers.read") { :ok } }
    other = A::Actor.customer(user_id: "u9", organization_id: "o1", customer_id: "outro")

    assert_raises(Locentra::Domain::AccessDenied) { uow(access).run(other) { :ok } }
  end

  def test_authorizer_rules
    assert A::Authorizer.allowed?(A::Actor.system(organization_id: "o"), "jobs.manage")
    refute A::Authorizer.allowed?(A::Actor.user(user_id: "u", organization_id: "o", role: "attendant"), "audit.read")
    assert_raises(ArgumentError) { A::Actor.credential(kind: "root", credential_id: "c", organization_id: "o", scopes: []) }
    assert_equal "c", A::Actor.credential(kind: "cli", credential_id: "c", organization_id: "o", scopes: []).audit_actor_id
  end

  def test_pagination_limits
    assert_equal [25, 0], A::Page.params
    assert_equal [10, 20], A::Page.params(limit: "10", offset: "20")
    assert_raises(Locentra::Domain::ValidationError) { A::Page.params(limit: "1000") }
    assert_raises(Locentra::Domain::ValidationError) { A::Page.params(offset: "-1") }
    assert_raises(Locentra::Domain::ValidationError) { A::Page.params(limit: "abc") }
    page = A::Page.new(items: [], limit: 10, offset: 10, total: 35)

    assert_equal 20, page.next_offset
    assert_equal 0, page.previous_offset
  end

  def test_idempotency_fingerprint_is_canonical
    a = A::Idempotency.fingerprint("POST", "/x", { "b" => 1, "a" => [{ "d" => 2, "c" => 3 }] })
    b = A::Idempotency.fingerprint("POST", "/x", { "a" => [{ "c" => 3, "d" => 2 }], "b" => 1 })

    assert_equal a, b
    refute_equal a, A::Idempotency.fingerprint("POST", "/x", { "a" => [], "b" => 1 })
    refute_equal a, A::Idempotency.fingerprint("POST", "/y", { "b" => 1, "a" => [{ "d" => 2, "c" => 3 }] })
    refute_equal A::Idempotency.fingerprint("POST", "/x", { "f" => false }), A::Idempotency.fingerprint("POST", "/x", { "f" => nil }),
                 "false e null são conteúdos diferentes"
    assert_equal A::Idempotency.fingerprint("POST", "/x", { "f" => false }), A::Idempotency.fingerprint("POST", "/x", { f: false })
  end

  def test_pagination_offset_has_an_upper_bound
    assert_equal [25, A::MAX_PAGE_OFFSET], A::Page.params(offset: A::MAX_PAGE_OFFSET.to_s)
    error = assert_raises(Locentra::Domain::ValidationError) { A::Page.params(offset: "99999999999999999999") }

    assert_equal ["deslocamento"], error.errors.keys
  end

  def test_audit_trail_records_actor_and_request
    rows = []
    repo = Object.new
    repo.define_singleton_method(:insert) { |_tx, row| rows << row }
    trail = A::AuditTrail.new(repository: repo, clock: TestClock.new, ids: SequentialIds.new)
    actor = A::Actor.user(user_id: "u1", organization_id: "o1", role: "owner", request_id: "req-1", ip: "10.0.0.1")
    trail.record(FakeTx.new("o1"), actor, "x.done", "x", "id1", "k" => "v")
    trail.record(FakeTx.new("o1"), nil, "x.system", "x", nil)

    assert_equal(%w[user system], rows.map { |r| r["actor_type"] })
    assert_equal "req-1", rows.first["request_id"]
  end
end
