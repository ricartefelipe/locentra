# frozen_string_literal: true

require_relative "portal_flow_helper"

# Acesso ao portal do cliente pelos casos de uso: concessão por convite com e-mail entregue pelo
# worker, substituição e cancelamento de convites, aceite com conta nova ou existente e revogação
# imediata.
class PortalFlowTest < PortalFlowCase
  def test_invitation_email_carries_token_issued_at_delivery_and_acceptance_creates_user_and_access
    contact = portal_contact(@actor, @customer, email: "compras@cliente.test", name: "Paula Compras")
    invitation = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: contact.id)
    job = owner_query("SELECT payload::text AS payload FROM jobs WHERE kind = 'email.portal_invitation'").first

    assert_equal({ "invitation_id" => invitation.id }, JSON.parse(job["payload"]), "a fila guarda apenas o identificador")
    assert_equal "compras@cliente.test", invitation.email
    assert_equal @clock.now + (7 * 86_400), invitation.expires_at
    drain
    mail = @mailer.deliveries.last

    assert_equal "compras@cliente.test", mail[:to]
    assert_includes mail[:subject], "portal do cliente de Locadora Alfa"
    assert_includes mail[:text], "Cliente Alfa"
    assert_includes mail[:text], "/portal/convite?token="
    token = @mailer.token_in

    assert token.start_with?("#{@org[:organization_id]}.")
    refute_includes owner_query("SELECT token_digest FROM portal_invitations").first["token_digest"], token
    result = uc(:accept_portal_invitation).call(token: token, name: "Paula Compras", password: PORTAL_PASSWORD)

    assert_equal @customer.id, result[:customer_id]
    assert uc(:authenticate).call(email: "compras@cliente.test", password: PORTAL_PASSWORD, ip: "10.0.0.9")
    access = owner_query("SELECT status, contact_id, invitation_id, created_by FROM portal_accesses WHERE user_id = $1", [result[:user_id]]).first

    assert_equal ["active", contact.id, invitation.id, @org[:user_id]], access.values_at("status", "contact_id", "invitation_id", "created_by")
    memberships = uc(:list_memberships).call(result[:user_id])

    assert_equal([["portal", @customer.id]], memberships.map { |m| [m["kind"], m["customer_id"]] })
    assert_raises(D::ValidationError) { uc(:accept_portal_invitation).call(token: token, name: "De novo", password: PORTAL_PASSWORD) }
    actions = owner_query("SELECT action, actor_type FROM audit_events WHERE action LIKE 'portal.%' ORDER BY occurred_at, action")

    assert_equal [%w[portal.access_granted customer], %w[portal.invited user]], actions.map(&:values).sort
  end

  def test_grant_requires_permission_plan_feature_and_a_contact_with_email
    contact = portal_contact(@actor, @customer, email: "contato@cliente.test")
    finance = staff_member(@org, "financeiro@alfa.test", "finance")
    attendant = staff_member(@org, "atendente@alfa.test", "attendant")

    assert_raises(D::AccessDenied) { uc(:invite_portal_contact).call(finance, customer_id: @customer.id, contact_id: contact.id) }
    assert uc(:invite_portal_contact).call(attendant, customer_id: @customer.id, contact_id: contact.id)
    no_email = uc(:add_contact).call(@actor, @customer.id, { name: "Sem E-mail" })
    error = assert_raises(D::ValidationError) { uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: no_email.id) }

    assert_includes error.errors.fetch("contato").first, "e-mail"
    neighbour = portal_contact(@actor, @other, email: "vizinho@cliente.test")

    assert_raises(D::NotFound) { uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: neighbour.id) }
    uc(:update_customer).call(@actor, @other.id, { status: "blocked" })

    assert_raises(D::ValidationError) { uc(:invite_portal_contact).call(@actor, customer_id: @other.id, contact_id: neighbour.id) }
    small = create_organization(name: "Locadora Pequena", email: "dona@pequena.test", plan: "essencial")
    small_customer = create_customer(small[:actor], name: "Cliente Pequeno")
    small_contact = portal_contact(small[:actor], small_customer, email: "c@pequeno.test")
    limit = assert_raises(D::PlanLimitExceeded) do
      uc(:invite_portal_contact).call(small[:actor], customer_id: small_customer.id, contact_id: small_contact.id)
    end

    assert_includes limit.message, "portal"
    refute uc(:list_portal_accesses).call(small[:actor], small_customer.id)[:enabled]
    assert uc(:list_portal_accesses).call(@actor, @customer.id)[:enabled]
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_raises(D::NotFound) { uc(:invite_portal_contact).call(beta[:actor], customer_id: @customer.id, contact_id: contact.id) }
    assert_raises(D::NotFound) { uc(:list_portal_accesses).call(beta[:actor], @customer.id) }
  end

  def test_new_invitation_replaces_pending_one_and_closed_invitations_are_not_delivered
    contact = portal_contact(@actor, @customer, email: "repetido@cliente.test")
    first = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: contact.id)
    second = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: contact.id)
    drain

    assert_equal 1, @mailer.deliveries.size, "o convite substituído não é enviado"
    assert_equal({ first.id => true, second.id => false },
                 owner_query("SELECT id, revoked_at IS NOT NULL AS revoked FROM portal_invitations").to_h { |r| [r["id"], r["revoked"] == "t"] })
    token = @mailer.token_in
    cancelled = uc(:cancel_portal_invitation).call(@actor, customer_id: @customer.id, invitation_id: second.id)

    assert_equal "revoked", cancelled.status(@clock.now)
    assert_raises(D::ValidationError) { uc(:accept_portal_invitation).call(token: token, name: "Contato", password: PORTAL_PASSWORD) }
    assert_raises(D::InvalidTransition) { uc(:cancel_portal_invitation).call(@actor, customer_id: @customer.id, invitation_id: second.id) }
    assert_raises(D::NotFound) { uc(:cancel_portal_invitation).call(@actor, customer_id: @other.id, invitation_id: second.id) }
    @clock.advance(60)
    third = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: contact.id)
    @clock.advance((7 * 86_400) + 1)
    @mailer.deliveries.clear
    drain

    assert_empty @mailer.deliveries, "convite vencido não gera e-mail"
    assert_equal "expired", uc(:list_portal_accesses).call(@actor, @customer.id)[:invitations].first[:invitation].status(@clock.now)
    assert_equal third.id, uc(:list_portal_accesses).call(@actor, @customer.id)[:invitations].first[:invitation].id
    assert_equal "succeeded", owner_query("SELECT status FROM jobs WHERE kind = 'email.portal_invitation' ORDER BY created_at DESC LIMIT 1").first["status"]
  end

  # Convites em aberto do mesmo e-mail: os do próprio cliente são substituídos com auditoria; o
  # pendente de outro cliente bloqueia o novo convite até ser cancelado; o vencido é substituído.
  def test_replaced_invitations_are_audited_and_other_customers_pending_invitations_are_kept
    shared = "compartilhado@cliente.test"
    own = portal_contact(@actor, @customer, email: shared)
    first = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: own.id)
    @clock.advance(60)
    second = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: own.id)
    cancelled = lambda do
      owner_query(<<~SQL).map { |r| r.values_at("resource_id", "invitation_id", "reason", "replaced_by") }
        SELECT resource_id, details->>'invitation_id' AS invitation_id, details->>'reason' AS reason, details->>'replaced_by' AS replaced_by
          FROM audit_events WHERE action = 'portal.invitation_cancelled' ORDER BY occurred_at, id
      SQL
    end

    assert_equal [[@customer.id, first.id, "replaced", second.id]], cancelled.call
    invited = owner_query("SELECT details->>'replaced_invitation_ids' AS ids FROM audit_events WHERE action = 'portal.invited' ORDER BY occurred_at")

    assert_equal([[], [first.id]], invited.map { |r| JSON.parse(r["ids"]) })
    neighbour = portal_contact(@actor, @other, email: shared)
    blocked = assert_raises(D::Conflict) { uc(:invite_portal_contact).call(@actor, customer_id: @other.id, contact_id: neighbour.id) }

    assert_equal "portal_pending_other_customer", blocked.code
    assert_includes blocked.message, "Cliente Alfa"
    assert_equal({ first.id => true, second.id => false },
                 owner_query("SELECT id, revoked_at IS NOT NULL AS revoked FROM portal_invitations").to_h { |r| [r["id"], r["revoked"] == "t"] })
    @clock.advance(7 * 86_400)
    third = uc(:invite_portal_contact).call(@actor, customer_id: @other.id, contact_id: neighbour.id)

    assert_equal [@customer.id, second.id, "replaced", third.id], cancelled.call.last, "o convite vencido do outro cliente é substituído"
    assert_equal([@other.id], owner_query(<<~SQL).map { |r| r["customer_id"] })
      SELECT customer_id FROM portal_invitations WHERE accepted_at IS NULL AND revoked_at IS NULL
    SQL
  end

  def test_existing_account_is_linked_only_after_login_with_the_same_email
    beta = create_organization(name: "Locadora Beta", email: "compras@beta.test")
    contact = portal_contact(@actor, @customer, email: "compras@beta.test")
    token = invite_and_deliver(@actor, @customer, contact)
    required = assert_raises(D::Conflict) { uc(:accept_portal_invitation).call(token: token, name: "Outro", password: PORTAL_PASSWORD) }

    assert_equal "login_required", required.code
    assert_raises(D::AccessDenied) { uc(:accept_portal_invitation).call(token: token, user_id: @org[:user_id]) }
    linked = uc(:accept_portal_invitation).call(token: token, user_id: beta[:user_id])

    assert_equal beta[:user_id], linked[:user_id]
    kinds = uc(:list_memberships).call(beta[:user_id]).to_h { |m| [m["kind"], m["organization_id"]] }

    assert_equal({ "staff" => beta[:organization_id], "portal" => @org[:organization_id] }, kinds)
    assert_raises(D::ValidationError) { uc(:accept_portal_invitation).call(token: "invalido", name: "X", password: PORTAL_PASSWORD) }
    assert_raises(D::ValidationError) { uc(:accept_portal_invitation).call(token: "#{@org[:organization_id]}.x", user_id: beta[:user_id]) }
  end

  def test_revocation_takes_effect_on_the_next_operation_and_reinvitation_reactivates
    customer = portal_customer(@actor, @customer, email: "revogar@cliente.test")
    sessions = @system.services[:sessions]
    portal_token, = sessions.create(user_id: customer.user_id, organization_id: @org[:organization_id], kind: "portal")
    staff_token, = sessions.create(user_id: customer.user_id, organization_id: @org[:organization_id], kind: "staff")

    assert_equal "Cliente Alfa", uc(:portal_home).call(customer)[:customer].name
    access = uc(:list_portal_accesses).call(@actor, @customer.id)[:accesses].first[:access]

    assert_raises(D::NotFound) { uc(:revoke_portal_access).call(@actor, customer_id: @other.id, access_id: access.id) }
    revoked = uc(:revoke_portal_access).call(@actor, customer_id: @customer.id, access_id: access.id)

    assert_equal "revoked", revoked.status
    error = assert_raises(D::AccessDenied) { uc(:portal_home).call(customer) }

    assert_includes error.message, "revogado"
    assert_raises(D::AccessDenied) { uc(:list_reservations).call(customer) }
    assert_nil sessions.resolve(portal_token), "sessões do portal são encerradas"
    refute_nil sessions.resolve(staff_token), "outras sessões do usuário não são afetadas"
    assert_raises(D::Conflict) { uc(:revoke_portal_access).call(@actor, customer_id: @customer.id, access_id: access.id) }
    assert_empty uc(:list_memberships).call(customer.user_id)
    token = invite_and_deliver(@actor, @customer, uc(:get_customer).call(@actor, @customer.id)[:contacts].first)
    again = uc(:accept_portal_invitation).call(token: token, user_id: customer.user_id)

    assert_equal access.id, again[:access_id], "o registro de acesso é reativado"
    assert uc(:portal_home).call(customer)
  end

  def test_active_access_blocks_invitations_and_links_to_a_single_customer
    customer = portal_customer(@actor, @customer, email: "unico@cliente.test")
    same = uc(:get_customer).call(@actor, @customer.id)[:contacts].first
    already = assert_raises(D::Conflict) { uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: same.id) }

    assert_equal "portal_already_granted", already.code
    other_contact = portal_contact(@actor, @other, email: "unico@cliente.test")
    other = assert_raises(D::Conflict) { uc(:invite_portal_contact).call(@actor, customer_id: @other.id, contact_id: other_contact.id) }

    assert_equal "portal_other_customer", other.code
    owner_query("INSERT INTO portal_invitations (id, organization_id, customer_id, contact_id, email, token_digest, invited_by, expires_at, created_at) " \
                "VALUES ($1, $2, $3, $4, 'unico@cliente.test', $5, $6, $7, $8)",
                [SecureRandom.uuid, @org[:organization_id], @other.id, other_contact.id, A::Identity::Tokens.digest("#{@org[:organization_id]}.manual"),
                 @org[:user_id], @clock.now + 3600, @clock.now])
    conflict = assert_raises(D::Conflict) do
      uc(:accept_portal_invitation).call(token: "#{@org[:organization_id]}.manual", user_id: customer.user_id)
    end

    assert_equal "portal_other_customer", conflict.code
  end
end
