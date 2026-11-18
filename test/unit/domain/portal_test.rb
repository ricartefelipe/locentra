# frozen_string_literal: true

require_relative "../unit_helper"

class PortalDomainTest < UnitTest
  PT = Domain::Portal

  def now = t("2026-03-02T12:00:00Z")

  def customer(status: "active")
    Domain::Customers::Customer.build(id: "c1", organization_id: "o1", kind: "individual", name: "Cliente", document: "52998224725").with(status: status)
  end

  def contact(customer_id: "c1", email: "Compras@Cliente.test")
    Domain::Customers::Contact.build(id: "k1", organization_id: "o1", customer_id: customer_id, name: "Paula", email: email)
  end

  def invitation(**overrides)
    PT::Invitation.issue(id: "i1", organization_id: "o1", customer: customer, contact: contact, invited_by: "u1", now: now).with(**overrides)
  end

  def test_invitation_targets_a_contact_with_email_of_an_active_customer
    issued = invitation

    assert_equal ["c1", "k1", "compras@cliente.test", now + PT::INVITATION_TTL_SECONDS], [issued.customer_id, issued.contact_id, issued.email,
                                                                                          issued.expires_at]
    assert_raises(Domain::ValidationError) do
      PT::Invitation.issue(id: "i2", organization_id: "o1", customer: customer(status: "blocked"), contact: contact, invited_by: "u1", now: now)
    end
    assert_raises(Domain::NotFound) do
      PT::Invitation.issue(id: "i2", organization_id: "o1", customer: customer, contact: contact(customer_id: "c2"), invited_by: "u1", now: now)
    end
    assert_raises(Domain::NotFound) { PT::Invitation.issue(id: "i2", organization_id: "o1", customer: customer, contact: nil, invited_by: "u1", now: now) }
    error = assert_raises(Domain::ValidationError) do
      PT::Invitation.issue(id: "i2", organization_id: "o1", customer: customer, contact: contact(email: nil), invited_by: "u1", now: now)
    end

    assert_equal ["contato"], error.errors.keys
  end

  def test_invitation_states_and_expiration_instant
    pending = invitation

    assert_equal "pending", pending.status(now)
    assert_equal "Aguardando aceite", pending.status_label(now)
    assert pending.pending?(pending.expires_at - 1)
    assert_equal "expired", pending.status(pending.expires_at), "o instante de expiração pertence ao período vencido"
    accepted = pending.accept("u9", now + 60)

    assert_equal ["accepted", "u9", now + 60], [accepted.status(now), accepted.accepted_user_id, accepted.accepted_at]
    assert_raises(Domain::ValidationError) { accepted.accept("u9", now) }
    assert_raises(Domain::ValidationError) { pending.accept("u9", pending.expires_at) }
    assert_raises(Domain::InvalidTransition) { accepted.revoke(now) }
    revoked = pending.revoke(now)

    assert_equal "revoked", revoked.status(now)
    assert_raises(Domain::InvalidTransition) { revoked.revoke(now) }
    assert_raises(Domain::ValidationError) { revoked.accept("u9", now) }
    assert_equal "revoked", invitation.revoke(invitation.expires_at + 10).status(now), "convite vencido pode ser cancelado"
  end

  def test_access_grant_revocation_and_reactivation
    access = PT::Access.grant(id: "a1", organization_id: "o1", user_id: "u9", invitation: invitation, now: now)

    assert_equal %w[active c1 k1 i1 Ativo], [access.status, access.customer_id, access.contact_id, access.invitation_id, access.status_label]
    revoked = access.revoke(now + 5)

    assert_equal ["revoked", now + 5, false], [revoked.status, revoked.revoked_at, revoked.active?]
    assert_equal "already_revoked", assert_raises(Domain::Conflict) { revoked.revoke(now) }.code
    other = invitation(id: "i2", customer_id: "c2", contact_id: "k2")
    reactivated = revoked.reactivate(other)

    assert_equal ["active", "c2", "k2", "i2", nil], [reactivated.status, reactivated.customer_id, reactivated.contact_id, reactivated.invitation_id,
                                                     reactivated.revoked_at]
    assert_equal "i3", access.reactivate(invitation(id: "i3")).invitation_id, "mesmo cliente mantém o acesso ativo"
    assert_equal "portal_other_customer", assert_raises(Domain::Conflict) { access.reactivate(other) }.code
  end

  def test_grant_rules_for_emails_with_active_access
    assert PT::Rules.grantable!(nil, "c1")
    assert_equal "portal_already_granted", assert_raises(Domain::Conflict) { PT::Rules.grantable!("c1", "c1") }.code
    assert_equal "portal_other_customer", assert_raises(Domain::Conflict) { PT::Rules.grantable!("c2", "c1") }.code
    assert_includes PT::REQUEST_NOTICE, "não garante disponibilidade"
  end

  def test_new_invitation_replaces_own_and_expired_invitations_but_not_pending_ones_of_other_customers
    own = invitation
    expired_elsewhere = invitation(id: "i2", customer_id: "c2", expires_at: now)
    names = { "c2" => "Cliente Vizinho" }

    assert_equal [own, expired_elsewhere], PT::Rules.replaceable!([own, expired_elsewhere], "c1", now) { |id| names.fetch(id) }
    assert_empty PT::Rules.replaceable!([], "c1", now) { |id| names.fetch(id) }
    pending_elsewhere = invitation(id: "i3", customer_id: "c2")
    error = assert_raises(Domain::Conflict) { PT::Rules.replaceable!([own, pending_elsewhere], "c1", now) { |id| names.fetch(id) } }

    assert_equal "portal_pending_other_customer", error.code
    assert_includes error.message, "para o cliente Cliente Vizinho"
  end
end
