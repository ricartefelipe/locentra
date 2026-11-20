# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/portal_support"

# Regras de acesso além da matriz de permissões: papéis entre administradores, credenciais
# vinculadas ao criador e ordem das verificações baratas antes do bcrypt.
class AccessControlTest < DatabaseTest
  include PortalHelpers

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
end
