# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/portal_support"

# Portal do cliente pelos casos de uso: concessão por convite com e-mail entregue pelo worker,
# aceite, revogação imediata, escopo por cliente e por organização, solicitação de reserva,
# disponibilidade sem dados internos, extrato financeiro e download restrito de documentos.
class PortalFlowTest < DatabaseTest
  include WorkerHelpers
  include PortalHelpers

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Cliente Alfa")
    @other = create_customer(@actor, name: "Cliente Vizinho", document: "11144477735")
    @camera = create_product(@actor, sku: "CAM-PORTAL", tracking: "serialized", pricing: { "daily_cents" => 15_000 })
    register_assets(@actor, @camera, @branch, 2)
    worker_system
    drain
    @mailer.deliveries.clear
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z")
  def document_of(actor, contract) = uc(:get_contract).call(actor, contract.id)[:documents].first["attachment_id"]

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

  def test_reservations_and_quotes_are_scoped_to_the_customer
    alfa = portal_customer(@actor, @customer, email: "alfa@cliente.test")
    neighbour = portal_customer(@actor, @other, email: "vizinho@cliente.test")
    own_reservation = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm")
    other_reservation = reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    own_quote = sent_quote(@actor, @customer, @branch, @camera, 20)
    other_quote = sent_quote(@actor, @other, @branch, @camera, 20)
    draft = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, lines: [line(@camera, 1)], period: rental,
                                             valid_until: t("2026-03-06T12:00:00Z") })

    assert_equal([own_reservation.id], uc(:list_reservations).call(alfa).items.map { |row| row[:reservation].id })
    assert_raises(D::NotFound) { uc(:get_reservation).call(alfa, other_reservation.id) }
    assert_equal([own_quote.id], uc(:list_quotes).call(alfa).items.map { |row| row[:quote].id })
    assert_raises(D::NotFound) { uc(:get_quote).call(alfa, draft.id) }
    assert_raises(D::NotFound) { uc(:approve_quote).call(alfa, other_quote.id, version: 1, approver_name: "Intruso") }
    assert_raises(D::NotFound) { uc(:reject_quote).call(alfa, other_quote.id, reason: "Intruso") }
    approved = uc(:approve_quote).call(alfa.with(ip: "203.0.113.30"), own_quote.id, version: 1, approver_name: "Paula Compras")

    assert_equal %w[customer 203.0.113.30], [approved.approved_by_type, approved.approved_ip]
    assert_equal "rejected", uc(:reject_quote).call(neighbour, other_quote.id, reason: "Fora do orçamento").status
    cancelled = reserve(@actor, @customer, @branch, period("2026-03-15T08:00:00Z", "2026-03-16T08:00:00Z"), [line(@camera, 1)], mode: "hold")
    uc(:cancel_reservation).call(@actor, cancelled.id, reason: "Desistência")
    home = uc(:portal_home).call(alfa)

    assert_equal([own_reservation.id], home[:reservations].map { |row| row[:reservation].id }, "a página inicial mostra somente reservas vigentes")
    assert_equal [0, 0], [home[:quotes_total], home[:contracts_total]], "orçamento já aprovado não aguarda decisão"
    assert_raises(D::AccessDenied) { uc(:portal_home).call(alfa.with(customer_id: @other.id)) }
  end

  def test_contracts_and_documents_are_scoped_to_the_customer_and_the_organization
    alfa = portal_customer(@actor, @customer, email: "alfa@cliente.test")
    own_contract = contract_for(@actor, @customer, @branch, @camera, 10)
    other_contract = contract_for(@actor, @other, @branch, @camera, 10)

    assert_equal([own_contract.id], uc(:list_contracts).call(alfa).items.map { |row| row[:contract].id })
    assert_raises(D::NotFound) { uc(:get_contract).call(alfa, other_contract.id) }
    assert_raises(D::NotFound) do
      uc(:accept_contract).call(alfa, other_contract.id, name: "Intruso Silva", document: "52998224725", confirmed: true)
    end
    row, bytes = uc(:download_attachment).call(alfa, document_of(@actor, own_contract))

    assert_equal "application/pdf", row["content_type"]
    assert bytes.start_with?("%PDF")
    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, document_of(@actor, other_contract)) }
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")
    beta_product = create_product(beta[:actor], sku: "CAM-BETA", tracking: "serialized")
    register_assets(beta[:actor], beta_product, beta[:branch], 1)
    beta_contract = contract_for(beta[:actor], create_customer(beta[:actor], name: "Cliente Beta"), beta[:branch], beta_product, 12)

    assert_raises(D::NotFound) { uc(:get_contract).call(alfa, beta_contract.id) }
    assert_raises(D::NotFound) { uc(:get_reservation).call(alfa, beta_contract.reservation_id) }
    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, document_of(beta[:actor], beta_contract)) }
    assert_raises(D::AccessDenied) { uc(:portal_home).call(alfa.with(organization_id: beta[:organization_id])) }
  end

  def test_non_contract_attachments_are_not_downloadable_by_customers
    alfa = portal_customer(@actor, @customer, email: "anexos@cliente.test")
    pdf = "%PDF-1.4 documento interno"
    attachment = uc(:upload_attachment).call(@actor, owner_type: "customer", owner_id: @customer.id, filename: "ficha.pdf", bytes: pdf)
    contract = contract_for(@actor, @customer, @branch, @camera, 14)
    note = uc(:upload_attachment).call(@actor, owner_type: "contract", owner_id: contract.id, filename: "nota-interna.pdf", bytes: pdf)

    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, attachment["id"]) }
    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, note["id"]) }
    assert_equal pdf, uc(:download_attachment).call(@actor, note["id"]).last
  end

  def test_availability_hides_internal_data_and_request_creates_portal_request
    alfa = portal_customer(@actor, @customer, email: "pedido@cliente.test")
    kit = create_product(@actor, sku: "KIT-INATIVO", tracking: "bulk")
    owner_query("UPDATE products SET active = false WHERE id = $1", [kit.id])
    reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    rows = uc(:portal_availability).call(alfa, branch_id: @branch.id, period: rental)

    assert_equal [@camera.id], rows.map(&:product_id), "somente produtos ativos"
    assert_equal({ product_id: @camera.id, name: @camera.name, description: nil, category: nil, requested: nil, available: true }, rows.first.to_h)
    two = uc(:portal_availability).call(alfa, branch_id: @branch.id, period: rental, lines: [line(@camera, 2)]).first

    assert_equal [2, false], [two.requested, two.available]
    assert_raises(D::ValidationError) { uc(:portal_availability).call(alfa, branch_id: @branch.id, period: period("2026-03-01T08:00:00Z", "2026-03-02T08:00:00Z")) }
    assert_raises(D::ValidationError) { uc(:portal_availability).call(alfa, branch_id: @branch.id, period: period("2026-03-10T08:00:00Z", "2026-07-10T08:00:00Z")) }
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_raises(D::NotFound) { uc(:portal_availability).call(alfa, branch_id: beta[:branch].id, period: rental) }
    assert_equal [@branch.id], uc(:portal_availability).branches(alfa).map(&:id)
    assert_raises(D::AccessDenied) { uc(:portal_availability).call(@actor, branch_id: @branch.id, period: rental) }
    reservation = uc(:portal_request_reservation).call(alfa, branch_id: @branch.id, period: rental, lines: [line(@camera, 2)], notes: "Entrega às 8h")

    assert_equal %w[requested portal], [reservation.status, reservation.source]
    assert_equal @customer.id, reservation.customer_id
    assert_equal 30_000, reservation.total.cents
    assert_equal 0, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE reservation_id = $1", [reservation.id]).first["n"].to_i,
                 "a solicitação não aloca disponibilidade"
    audit = owner_query("SELECT actor_type, actor_id FROM audit_events WHERE action = 'reservation.created' AND resource_id = $1", [reservation.id]).first

    assert_equal ["customer", alfa.user_id], audit.values_at("actor_type", "actor_id")
    assert_raises(D::AccessDenied) { uc(:portal_request_reservation).call(@actor, branch_id: @branch.id, period: rental, lines: [line(@camera, 1)]) }
    assert_raises(D::ValidationError) { uc(:portal_request_reservation).call(alfa, branch_id: @branch.id, period: rental, lines: []) }
    assert_raises(D::NotFound) { uc(:portal_request_reservation).call(alfa, branch_id: @branch.id, period: rental, lines: [line(kit, 1)]) }
  end

  def test_statement_shows_only_the_customer_charges_and_deposits
    alfa = portal_customer(@actor, @customer, email: "financeiro@cliente.test")
    own = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm")
    other = reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    [own, other].each { |reservation| uc(:sync_reservation_charges).call(@actor, reservation.id) }
    rental_charge = uc(:finance).reservation(@actor, own.id)[:receivables].first[:receivable]
    uc(:register_payment).call(@actor, { purpose: "receivable", receivable_id: rental_charge.id, method: "pix", amount: D::Money.new(5_000) })
    deposit = uc(:open_deposit).call(@actor, own.id, kind: "paid_deposit", amount: D::Money.new(20_000))
    uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "pix", amount: D::Money.new(20_000) })
    statement = uc(:finance).customer_statement(alfa)

    assert_equal([own.id], statement[:receivables].map { |row| row[:receivable].reservation_id })
    assert_equal [10_000, "partial"], [statement[:receivables].first[:balance].outstanding.cents, statement[:receivables].first[:balance].status]
    assert_equal [10_000, 1], [statement[:totals][:open].cents, statement[:totals][:open_count]]
    assert_equal([[own.id, 20_000]], statement[:deposits].map { |row| [row[:deposit].reservation_id, row[:ledger].balance.cents] })
    assert_equal %i[deposits receivables totals], statement.keys.sort, "sem diário, alertas ou dados do provedor"
    staff = uc(:finance).customer_statement(@actor, customer_id: @other.id)

    assert_equal([other.id], staff[:receivables].map { |row| row[:receivable].reservation_id })
    auditor = staff_member(@org, "auditor@alfa.test", "auditor")

    assert uc(:finance).customer_statement(auditor, customer_id: @customer.id)
    assert_raises(D::AccessDenied) { uc(:finance).customer_statement(staff_member(@org, "atende@alfa.test", "attendant"), customer_id: @customer.id) }
    assert_equal 10_000, uc(:portal_home).call(alfa)[:totals][:open].cents
  end
end
