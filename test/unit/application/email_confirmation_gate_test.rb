# frozen_string_literal: true

require_relative "../unit_helper"

# Regra de confirmação de e-mail na camada de aplicação (ADR-031), com relógio controlado e portas falsas:
# a UnitOfWork calcula a situação no instante da operação, o Authorizer recusa as alterações da conta
# somente leitura e as ações para fora da conta não confirmada, e a recusa entra em domain_conflicts_total.
class EmailConfirmationGateTest < UnitTest
  A = Locentra::Application
  EC = Domain::Identity::EmailConfirmation
  CREATED_AT = Time.utc(2026, 3, 2, 12, 0, 0)

  Tx = Struct.new(:tenant_id)

  class Transactor
    def call(tenant_id: nil, **) = yield(Tx.new(tenant_id))
  end

  class Access
    attr_accessor :confirmed_at

    def active_membership(_tx, _org, _user)
      { "id" => "m1", "role" => "owner", "email_confirmed_at" => confirmed_at, "user_created_at" => CREATED_AT }
    end

    # "k1" sem criador; "k2" criada pelo usuário u1 (mesma situação de e-mail).
    def active_credential(_tx, id, _now)
      row = { "organization_id" => "o1", "kind" => "api", "scopes" => %w[members.manage customers.write] }
      id == "k2" ? row.merge("creator_email_confirmed_at" => confirmed_at, "creator_created_at" => CREATED_AT) : row
    end

    def active_portal_access(_tx, _org, _user) = { "id" => "p1", "customer_id" => "c1" }
  end

  class Metrics
    attr_reader :counters

    def initialize = @counters = Hash.new(0)
    def increment(name, **labels) = @counters[[name, labels]] += 1
  end

  def setup
    @clock = TestClock.new(CREATED_AT)
    @access = Access.new
    @metrics = Metrics.new
    @uow = A::UnitOfWork.new(transactor: Transactor.new, access: @access, clock: @clock, metrics: @metrics)
    @user = A::Actor.user(user_id: "u1", organization_id: "o1", role: "owner")
  end

  def status = @uow.run(@user) { |_tx, current| current.email_status }

  def refusals = @metrics.counters.fetch(["domain_conflicts_total", { code: "email_unconfirmed" }], 0)

  def outbound(actor = @user) = @uow.run(actor, "members.manage") { |_tx, current| A::Authorizer.confirmed_email!(current, "members.invite") }

  def test_status_follows_the_injected_clock
    assert_equal EC::PENDING, status
    @clock.advance(EC::GRACE_PERIOD_SECONDS - 1)

    assert_equal EC::PENDING, status
    @clock.advance(1)

    assert_equal EC::READ_ONLY, status
    @access.confirmed_at = @clock.now

    assert_equal EC::CONFIRMED, status, "a confirmação vale na operação seguinte"
  end

  def test_unconfirmed_account_operates_internally_but_not_outward_within_the_grace_period
    assert_equal :ok, @uow.run(@user, "reservations.write") { :ok }
    assert_equal :ok, @uow.run(@user, "customers.read") { :ok }
    error = assert_raises(Domain::EmailUnconfirmed) { outbound }

    assert_equal "email_unconfirmed", error.code
    assert_equal 1, refusals
    @access.confirmed_at = CREATED_AT + 60

    assert_equal @user.user_id, outbound.user_id
  end

  def test_read_only_account_keeps_queries_and_refuses_mutations
    @clock.advance(EC::GRACE_PERIOD_SECONDS)

    assert_equal :ok, @uow.run(@user, "reservations.read") { :ok }
    assert_equal :ok, @uow.run(@user) { :ok }, "sem permissão, a operação não é alteração"
    assert_equal :ok, @uow.run(@user, "integrations.manage", read: true) { :ok }, "consulta com permissão de alteração"
    error = assert_raises(Domain::EmailUnconfirmed) { @uow.run(@user, "reservations.write") { flunk "não executa" } }

    assert_equal :read_only, error.reason
    assert_raises(Domain::EmailUnconfirmed) { outbound }
    assert_equal 2, refusals
  end

  def test_authorizer_checks_the_actor_received_in_a_composed_transaction
    read_only = @user.with(email_status: EC::READ_ONLY)

    assert_raises(Domain::EmailUnconfirmed) { A::Authorizer.authorize!(read_only, "quotes.write") }
    assert_same read_only, A::Authorizer.authorize!(read_only, "quotes.read")
    assert_same read_only, A::Authorizer.authorize!(read_only, "quotes.write", read: true)
    assert_raises(Domain::EmailUnconfirmed) { A::Composition.run(@uow, read_only, "quotes.write", Tx.new("o1")) { :ok } }
    assert_raises(Domain::EmailUnconfirmed, "situação desconhecida recusa") { A::Authorizer.confirmed_email!(@user, "quotes.send") }
    assert_equal EC::PENDING, A::Authorizer.writable!(read_only.with(email_status: EC::PENDING)).email_status
  end

  def test_credentials_inherit_the_creator_status
    api = A::Actor.credential(kind: "api", credential_id: "k2", organization_id: "o1", scopes: [])

    assert_raises(Domain::EmailUnconfirmed) { outbound(api) }
    assert_equal :ok, @uow.run(api, "customers.write") { :ok }
    @clock.advance(EC::GRACE_PERIOD_SECONDS)

    assert_equal :read_only, assert_raises(Domain::EmailUnconfirmed) { @uow.run(api, "customers.write") { :ok } }.reason
    @access.confirmed_at = @clock.now

    assert_equal "k2", outbound(api).credential_id
    assert_equal 2, refusals
  end

  def test_credentials_without_creator_system_and_customers_are_not_subject_to_the_rule
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    api = A::Actor.credential(kind: "api", credential_id: "k1", organization_id: "o1", scopes: [], user_id: "u1")

    assert_equal "k1", outbound(api).credential_id
    assert_nil @uow.run(api) { |_tx, current| current.email_status }
    system = A::Actor.system(organization_id: "o1")

    assert_same system, A::Authorizer.confirmed_email!(system, "contracts.issue")
    assert_same system, A::Authorizer.authorize!(system, "contracts.write")
    customer = A::Actor.customer(user_id: "u9", organization_id: "o1", customer_id: "c1")

    assert_same customer, A::Authorizer.confirmed_email!(customer, "portal.invite")
    assert_equal 0, refusals
  end
end
