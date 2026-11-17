# frozen_string_literal: true

require_relative "integration_helper"

class QuotesFlowTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-ORC", tracking: "serialized", pricing: { "daily_cents" => 12_000 })
    register_assets(@actor, @camera, @branch, 1)
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")

  def quote_input(**extra)
    { customer_id: @customer.id, branch_id: @branch.id, period: rental, lines: [line(@camera, 1)], valid_until: t("2026-03-05T12:00:00Z"),
      terms: "Entrega no local do evento." }.merge(extra)
  end

  def approved_quote(**extra)
    quote = uc(:create_quote).call(@actor, quote_input(**extra))
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria Compradora")
  end

  def portal_actor(customer)
    user_id = SecureRandom.uuid
    owner_query("INSERT INTO users (id, email, name, password_digest, created_at, updated_at) VALUES ($1, $2, 'Cliente Portal', 'x', now(), now())",
                [user_id, "portal-#{user_id[0, 8]}@example.test"])
    owner_query("INSERT INTO portal_accesses (id, organization_id, user_id, customer_id, created_at) VALUES ($1, $2, $3, $4, now())",
                [SecureRandom.uuid, @org[:organization_id], user_id, customer.id])
    A::Actor.customer(user_id: user_id, organization_id: @org[:organization_id], customer_id: customer.id, ip: "203.0.113.10")
  end

  def test_versions_are_immutable_and_approval_targets_the_current_sent_version
    quote = uc(:create_quote).call(@actor, quote_input)

    assert_match(/\AQ-\d{6}\z/, quote.code)
    assert_equal "draft", quote.status
    assert_raises(D::InvalidTransition) { uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria") }
    uc(:send_quote).call(@actor, quote.id)
    revised = uc(:revise_quote).call(@actor, quote.id, quote_input(terms: "Retirada na loja."))

    assert_equal "draft", revised.status, "nova versão exige reenvio"
    assert_equal 2, revised.current_version
    uc(:send_quote).call(@actor, quote.id)
    stale = assert_raises(D::Conflict) { uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria") }

    assert_equal "stale_quote_version", stale.code
    approved = uc(:approve_quote).call(@actor.with(ip: "198.51.100.7"), quote.id, version: "2", approver_name: "Maria Compradora")

    assert_equal 2, approved.approved_version
    assert_equal "staff", approved.approved_by_type
    assert_equal "Maria Compradora", approved.approved_by_name
    assert_equal "198.51.100.7", approved.approved_ip
    assert_equal @clock.now, approved.approved_at
    data = uc(:get_quote).call(@actor, quote.id)

    assert_equal [2, 1], data[:versions].map(&:number)
    assert_equal "Entrega no local do evento.", data[:versions].last.terms
    assert_equal "Retirada na loja.", data[:current].terms
    assert_raises(D::InvalidTransition) { uc(:revise_quote).call(@actor, quote.id, quote_input(terms: "Outra")) }
    assert_raises(D::AccessDenied, "versões não podem ser alteradas pelo papel da aplicação") do
      @system.transactor.call(tenant_id: @org[:organization_id]) { |tx| tx.execute("UPDATE quote_versions SET terms = 'alterado'") }
    end
    assert_equal 1, owner_query("SELECT count(*) AS n FROM quote_versions WHERE terms = 'Entrega no local do evento.'").first["n"].to_i
  end

  def test_revision_without_changes_and_invalid_validity_are_rejected
    quote = uc(:create_quote).call(@actor, quote_input)

    error = assert_raises(D::ValidationError) { uc(:revise_quote).call(@actor, quote.id, quote_input) }
    assert_includes error.errors["base"].first, "nenhuma alteração"
    assert_raises(D::ValidationError) { uc(:create_quote).call(@actor, quote_input(valid_until: t("2026-03-11T00:00:00Z"))) }
    assert_raises(D::ValidationError) { uc(:create_quote).call(@actor, quote_input(valid_until: t("2026-03-01T00:00:00Z"))) }
    assert_raises(D::ValidationError) { uc(:create_quote).call(@actor, quote_input(hold_policy: "sempre")) }
    assert_raises(D::ValidationError) { uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 2000)) }
  end

  def test_expired_quote_cannot_be_approved_and_requires_new_version
    quote = uc(:create_quote).call(@actor, quote_input)
    uc(:send_quote).call(@actor, quote.id)
    @clock.travel_to(t("2026-03-05T12:00:00Z"))

    error = assert_raises(D::Conflict) { uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria") }
    assert_equal "quote_expired", error.code
    assert_equal "expired", uc(:get_quote).call(@actor, quote.id)[:quote].status
    again = assert_raises(D::Conflict) { uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria") }

    assert_equal "quote_expired", again.code
    renewed = uc(:revise_quote).call(@actor, quote.id, quote_input(valid_until: t("2026-03-08T12:00:00Z")))

    assert_equal "draft", renewed.status
    uc(:send_quote).call(@actor, quote.id)

    assert_equal "approved", uc(:approve_quote).call(@actor, quote.id, version: 2, approver_name: "Maria").status
    assert_equal 1, owner_query("SELECT count(*) AS n FROM audit_events WHERE action = 'quote.expired'").first["n"].to_i
  end

  def test_draft_with_expired_validity_cannot_be_sent
    quote = uc(:create_quote).call(@actor, quote_input)
    @clock.travel_to(t("2026-03-06T00:00:00Z"))

    assert_raises(D::ValidationError) { uc(:send_quote).call(@actor, quote.id) }
  end

  def test_sweeper_expires_sent_quotes_and_releases_the_hold
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 1440))
    sent = uc(:send_quote).call(@actor, quote.id)
    system = A::Actor.system(organization_id: @org[:organization_id])

    assert_empty uc(:expire_quotes).call(system)
    @clock.travel_to(t("2026-03-05T12:00:01Z"))

    assert_equal [quote.id], uc(:expire_quotes).call(system)
    assert_empty uc(:expire_quotes).call(system)
    assert_equal "cancelled", uc(:get_reservation).call(@actor, sent.hold_reservation_id)[:reservation].status
  end

  def test_hold_on_send_blocks_availability_and_conversion_confirms_the_hold
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 1440))
    sent = uc(:send_quote).call(@actor, quote.id)
    hold = uc(:get_reservation).call(@actor, sent.hold_reservation_id)

    assert_equal "held", hold[:reservation].status
    assert_equal @clock.now + (1440 * 60), hold[:reservation].hold_expires_at
    assert_equal 24_000, hold[:reservation].total.cents
    assert_nil hold[:reservation].quote_id
    assert_raises(D::Unavailable) { reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm") }
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria")
    @clock.advance(3600)
    result = uc(:convert_quote).call(@actor, quote.id)

    assert_equal sent.hold_reservation_id, result.reservation.id, "a reserva bloqueada é confirmada"
    assert_equal "confirmed", result.reservation.status
    assert_equal quote.id, result.reservation.quote_id
    assert_equal "converted", result.quote.status
    assert_equal({ contract: nil, quote: result.quote }, uc(:reservation_links).call(@actor, result.reservation.id))
  end

  def test_new_version_releases_the_hold_of_the_previous_send
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 600))
    sent = uc(:send_quote).call(@actor, quote.id)
    uc(:revise_quote).call(@actor, quote.id, quote_input(hold_policy: "none"))

    assert_equal "cancelled", uc(:get_reservation).call(@actor, sent.hold_reservation_id)[:reservation].status
    assert_equal "confirmed", reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm").status
  end

  # O bloqueio do envio pertence ao orçamento: só a conversão do orçamento aprovado o confirma e o
  # período só muda por nova versão. Depois da conversão, a reserva segue as regras normais.
  def test_quote_hold_is_confirmed_only_by_the_conversion
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 1440))
    hold_id = uc(:send_quote).call(@actor, quote.id).hold_reservation_id

    confirm = assert_raises(D::Conflict) { uc(:confirm_reservation).call(@actor, hold_id) }
    assert_equal "quote_hold", confirm.code
    assert_includes confirm.message, "conversão do orçamento aprovado"
    reschedule = assert_raises(D::Conflict) do
      uc(:reschedule_reservation).call(@actor, hold_id, period: period("2026-03-20T08:00:00Z", "2026-03-25T08:00:00Z"))
    end
    assert_includes reschedule.message, "nova versão do orçamento"
    extension = assert_raises(D::Conflict) { uc(:extend_reservation).call(@actor, hold_id, ends_at: t("2026-03-13T08:00:00Z")) }

    assert_equal "quote_hold", extension.code
    hold = uc(:get_reservation).call(@actor, hold_id)[:reservation]

    assert_equal ["held", rental], [hold.status, hold.period]
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria")

    assert_raises(D::Conflict, "aprovado e ainda não convertido") { uc(:confirm_reservation).call(@actor, hold_id) }
    converted = uc(:convert_quote).call(@actor, quote.id).reservation

    assert_equal [hold_id, "confirmed", quote.id, rental], [converted.id, converted.status, converted.quote_id, converted.period]
    assert_equal "confirmed", uc(:confirm_reservation).call(@actor, hold_id).status
    assert_equal t("2026-03-13T08:00:00Z"), uc(:extend_reservation).call(@actor, hold_id, ends_at: t("2026-03-13T08:00:00Z"))[:reservation].period.ends_at
  end

  # Rejeitar libera o bloqueio; nenhuma reserva confirmada sobrevive ao orçamento rejeitado.
  def test_rejection_releases_the_hold_and_frees_the_slot
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 1440))
    hold_id = uc(:send_quote).call(@actor, quote.id).hold_reservation_id
    uc(:reject_quote).call(@actor, quote.id, reason: "Cliente desistiu")

    assert_equal "cancelled", uc(:get_reservation).call(@actor, hold_id)[:reservation].status
    assert_equal 0, owner_query("SELECT count(*) AS n FROM reservations WHERE status IN ('held', 'confirmed')").first["n"].to_i
    assert_equal "confirmed", reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm").status
  end

  # O cancelamento direto do bloqueio equivale ao vencimento: a conversão cria uma reserva nova com o
  # snapshot da versão aprovada.
  def test_direct_cancellation_of_the_hold_works_like_its_expiry
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 1440))
    hold_id = uc(:send_quote).call(@actor, quote.id).hold_reservation_id
    uc(:cancel_reservation).call(@actor, hold_id, reason: "Cliente pediu para liberar a data")
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria")
    result = uc(:convert_quote).call(@actor, quote.id)

    assert result.created
    refute_equal hold_id, result.reservation.id
    assert_equal ["confirmed", 24_000, quote.id], [result.reservation.status, result.reservation.total.cents, result.reservation.quote_id]
  end

  def test_hold_on_send_without_availability_keeps_the_quote_in_draft
    reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm")
    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 60))

    error = assert_raises(D::Unavailable) { uc(:send_quote).call(@actor, quote.id) }
    assert_includes error.message, "bloqueio temporário"
    assert_equal "draft", uc(:get_quote).call(@actor, quote.id)[:quote].status
  end

  def test_conversion_is_idempotent_and_uses_the_approved_price_snapshot
    quote = approved_quote
    uc(:update_product_pricing).call(@actor, @camera.id, pricing: { "daily_cents" => 99_000 })

    first = uc(:convert_quote).call(@actor, quote.id)
    second = uc(:convert_quote).call(@actor, quote.id)

    assert first.created
    refute second.created
    assert_equal first.reservation.id, second.reservation.id
    assert_equal "confirmed", first.reservation.status
    assert_equal "quote", first.reservation.source
    assert_equal 24_000, first.reservation.total.cents, "preço da versão aprovada, não do catálogo atual"
    details = uc(:get_reservation).call(@actor, first.reservation.id)

    assert_equal 24_000, details[:pricing][:summary]["total_cents"]
    assert_equal quote.code, details[:pricing][:summary]["quote_code"]
    assert_equal 12_000, details[:items].first["pricing"]["table"]["daily_cents"]
    assert_equal 1, owner_query("SELECT count(*) AS n FROM reservations WHERE quote_id = $1", [quote.id]).first["n"].to_i
    assert_equal 1, owner_query("SELECT count(*) AS n FROM audit_events WHERE action = 'quote.converted'").first["n"].to_i
  end

  def test_conversion_without_availability_explains_the_quote_did_not_guarantee_it
    quote = approved_quote
    other = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    reserve(@actor, other, @branch, rental, [line(@camera, 1)], mode: "confirm")

    error = assert_raises(D::Unavailable) { uc(:convert_quote).call(@actor, quote.id) }
    assert_includes error.message, "não garantia disponibilidade"
    assert_equal "CAM-ORC", error.shortages.first["sku"]
    assert_equal "approved", uc(:get_quote).call(@actor, quote.id)[:quote].status
  end

  def test_only_approved_quotes_are_converted_and_converted_ones_are_final
    quote = uc(:create_quote).call(@actor, quote_input)

    assert_raises(D::InvalidTransition) { uc(:convert_quote).call(@actor, quote.id) }
    uc(:send_quote).call(@actor, quote.id)
    rejected = uc(:reject_quote).call(@actor, quote.id, reason: "Cliente escolheu outra data")

    assert_equal "rejected", rejected.status
    assert_equal "Cliente escolheu outra data", rejected.rejection_reason
    assert_raises(D::InvalidTransition) { uc(:reject_quote).call(@actor, quote.id, reason: "de novo") }
    assert_equal "draft", uc(:revise_quote).call(@actor, quote.id, quote_input(terms: "Nova proposta")).status
  end

  def test_customer_actor_decides_only_on_own_quotes
    quote = uc(:create_quote).call(@actor, quote_input)
    uc(:send_quote).call(@actor, quote.id)
    other = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    stranger = portal_actor(other)
    owner = portal_actor(@customer)

    assert_raises(D::NotFound) { uc(:approve_quote).call(stranger, quote.id, version: 1, approver_name: "Outro") }
    assert_raises(D::NotFound) { uc(:get_quote).call(stranger, quote.id) }
    assert_equal 0, uc(:list_quotes).call(stranger).total
    assert_raises(D::AccessDenied) { uc(:send_quote).call(owner, quote.id) }
    approved = uc(:approve_quote).call(owner, quote.id, version: 1, approver_name: "Cliente Teste")

    assert_equal "customer", approved.approved_by_type
    assert_equal "203.0.113.10", approved.approved_ip
    assert_equal 1, uc(:list_quotes).call(owner).total
  end

  def test_quotes_are_isolated_between_organizations
    quote = uc(:create_quote).call(@actor, quote_input)
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_raises(D::NotFound) { uc(:get_quote).call(beta[:actor], quote.id) }
    assert_raises(D::NotFound) { uc(:send_quote).call(beta[:actor], quote.id) }
    assert_raises(D::NotFound) { uc(:convert_quote).call(beta[:actor], quote.id) }
    assert_equal 0, uc(:list_quotes).call(beta[:actor]).total
    assert_raises(D::NotFound) { uc(:create_quote).call(beta[:actor], quote_input(branch_id: beta[:branch].id)) }
    assert_equal 1, uc(:list_quotes).call(@actor, search: quote.code).total
    assert_equal 0, uc(:list_quotes).call(@actor, status: "sent").total
  end

  def test_discount_above_role_limit_is_denied
    invite = uc(:invite_member).call(@actor, email: "atendente@alfa.test", role: "attendant")
    token = "#{@org[:organization_id]}.segredo-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    joined = uc(:accept_invitation).call(token: token, name: "Atendente", password: "senha-muito-segura-3")
    attendant = A::Actor.user(user_id: joined[:user_id], organization_id: @org[:organization_id], role: "attendant")

    assert_raises(D::AccessDenied) { uc(:create_quote).call(attendant, quote_input(manual_discount_bps: 1000)) }
    quote = uc(:create_quote).call(attendant, quote_input(manual_discount_bps: 500))

    assert_equal 22_800, uc(:get_quote).call(@actor, quote.id)[:current].total.cents
  end
end
