# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/portal_support"

# Regras de acesso além da matriz de permissões: papéis entre administradores, credenciais
# vinculadas ao criador e ordem das verificações baratas antes do bcrypt.
class AccessControlTest < DatabaseTest
  include PortalHelpers

  # Hasher que conta quantos hashes de senha foram calculados.
  class CountingHasher
    attr_reader :count

    def initialize(inner)
      @inner = inner
      @count = 0
    end

    def hash(password)
      @count += 1
      @inner.hash(password)
    end

    def verify(...) = @inner.verify(...)
    def dummy_digest = @inner.dummy_digest
  end

  def setup
    super
    @org = create_organization
    @owner = @org[:actor]
  end

  def membership_of(actor) = uc(:list_members).call(@owner)[:members].find { |m| m["user_id"] == actor.user_id }

  def test_admin_cannot_change_or_demote_another_admin
    first = staff_member(@org, "admin1@alfa.test", "admin")
    second = staff_member(@org, "admin2@alfa.test", "admin")
    target = membership_of(second)

    error = assert_raises(D::AccessDenied) { uc(:change_member_role).call(first, membership_id: target["id"], role: "auditor") }
    assert_match(/proprietário/, error.message)
    assert_raises(D::AccessDenied) { uc(:revoke_membership).call(first, membership_id: target["id"]) }
    assert_equal %w[admin active], membership_of(second).values_at("role", "status")
    assert_equal "auditor", uc(:change_member_role).call(@owner, membership_id: target["id"], role: "auditor"), "o proprietário pode"
    attendant = staff_member(@org, "atendente@alfa.test", "attendant")

    assert_equal "manager", uc(:change_member_role).call(first, membership_id: membership_of(attendant)["id"], role: "manager")
  end

  def test_credentials_follow_the_membership_and_the_current_role_of_their_creator
    admin = staff_member(@org, "admin@alfa.test", "admin")
    token = uc(:create_credential).call(admin, name: "ERP", scopes: %w[customers.read customers.write], expires_in_days: 30)["token"]
    other = uc(:create_credential).call(@owner, name: "BI", scopes: %w[customers.read], expires_in_days: 30)["token"]
    actor = uc(:authenticate_credential).call(token)

    assert_equal %w[customers.read customers.write], actor.scopes
    uc(:change_member_role).call(@owner, membership_id: membership_of(admin)["id"], role: "auditor")
    demoted = uc(:authenticate_credential).call(token)

    assert_equal %w[customers.read], demoted.scopes, "escopos limitados ao papel atual do criador"
    assert_raises(D::AccessDenied) { uc(:create_customer).call(actor, kind: "individual", name: "Cliente", document: "52998224725") }
    uc(:revoke_membership).call(@owner, membership_id: membership_of(admin)["id"])

    assert_nil uc(:authenticate_credential).call(token), "vínculo revogado"
    assert_raises(D::AccessDenied) { uc(:list_customers).call(actor) }
    revoked = owner_query("SELECT name FROM api_credentials WHERE revoked_at IS NOT NULL").map { |r| r["name"] }

    assert_equal ["ERP"], revoked
    refute_nil uc(:authenticate_credential).call(other), "credenciais de outros membros continuam válidas"
  end

  def test_invalid_tokens_and_taken_emails_do_not_cost_a_password_hash
    hasher = CountingHasher.new(@system.services[:hasher])
    r = @system.repos
    s = @system.services
    reset = A::Identity::ResetPassword.new(uow: @system.uow, users: r[:users], tokens: s[:tokens], hasher: hasher, sessions_repository: r[:sessions],
                                           clock: @clock)
    accept = A::Organizations::AcceptInvitation.new(uow: @system.uow, organizations: r[:organizations], users: r[:users], hasher: hasher,
                                                    audit: s[:audit], clock: @clock, ids: @system.ids)
    portal = A::Portal::AcceptInvitation.new(uow: @system.uow, portal: r[:portal], customers: r[:customers], users: r[:users], limits: s[:limits],
                                             hasher: hasher, audit: s[:audit], clock: @clock, ids: @system.ids)
    sign_up = A::Identity::SignUp.new(uow: @system.uow, users: r[:users], organizations: r[:organizations], hasher: hasher, notifier: s[:notifier],
                                      clock: @clock, ids: @system.ids, audit: s[:audit], rate_limiter: s[:rate_limiter])
    password = "senha-muito-segura-9"

    assert_raises(D::ValidationError) { reset.call(token: "invalido", password: password) }
    assert_raises(D::ValidationError) { accept.call(token: "#{@org[:organization_id]}.invalido", name: "X", password: password) }
    assert_raises(D::ValidationError) { portal.call(token: "#{@org[:organization_id]}.invalido", name: "X", password: password) }
    assert_raises(D::Conflict) { sign_up.call(name: "X", email: "dona@alfa.test", password: password, organization_name: "Outra") }
    assert_equal 0, hasher.count
  end

  # O cadastro da organização no setup é a primeira tentativa do endereço.
  def test_signup_attempts_are_limited_per_email
    4.times do
      assert_raises(D::Conflict) { uc(:sign_up).call(name: "X", email: "dona@alfa.test", password: "senha-muito-segura-1", organization_name: "Outra") }
    end
    assert_raises(A::Identity::TooManyRequests) do
      uc(:sign_up).call(name: "X", email: "DONA@alfa.test", password: "senha-muito-segura-1", organization_name: "Outra")
    end
    @clock.advance(3601)

    assert_raises(D::Conflict) { uc(:sign_up).call(name: "X", email: "dona@alfa.test", password: "senha-muito-segura-1", organization_name: "Outra") }
  end

  def test_signup_reports_organization_name_errors_on_the_organization_field
    error = assert_raises(D::ValidationError) do
      uc(:sign_up).call(name: "Fulano de Tal", email: "fulano@x.test", password: "senha-muito-segura-1", organization_name: "A")
    end

    assert_equal ["organizacao"], error.errors.keys
    symbols = assert_raises(D::ValidationError) do
      uc(:sign_up).call(name: "Fulano de Tal", email: "fulano@x.test", password: "senha-muito-segura-1", organization_name: "!!!")
    end

    assert_equal ["organizacao"], symbols.errors.keys
  end
end
