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

end
