# frozen_string_literal: true

require "digest"
require_relative "integration_helper"

class ContractsFlowTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor].with(ip: "198.51.100.20")
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Joana Locatária")
    @camera = create_product(@actor, sku: "CAM-CTR", tracking: "serialized", pricing: { "daily_cents" => 10_000 }, deposit: D::Money.new(50_000))
    register_assets(@actor, @camera, @branch, 1)
    @reservation = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm")
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")
  def issue = uc(:issue_contract).call(@actor, @reservation.id)

  # Texto das strings do PDF (Prawn grava cada linha como string hexadecimal em Windows-1252).
  def pdf_text(bytes)
    bytes.b.scan(/<([0-9a-f]+)> Tj/).map { |(hex)| [hex].pack("H*").force_encoding("Windows-1252").encode("UTF-8") }.join(" ")
  end

  def download(attachment_id) = uc(:download_attachment).call(@actor, attachment_id)

  def test_issue_generates_pdf_from_real_data_registers_sha256_and_is_idempotent
    contract = issue

    assert_match(/\AC-\d{6}\z/, contract.code)
    assert_equal "issued", contract.status
    assert_equal contract.id, issue.id, "emissão repetida devolve o mesmo contrato"
    data = uc(:get_contract).call(@actor, contract.id)
    document = data[:documents].first

    assert_equal 1, data[:documents].size
    row, bytes = download(document["attachment_id"])

    assert bytes.start_with?("%PDF"), "o arquivo gerado é um PDF"
    assert_equal Digest::SHA256.hexdigest(bytes), document["sha256"]
    assert_equal row["sha256"], document["sha256"]
    assert_equal "application/pdf", row["content_type"]
    assert_in_delta (@clock.now + (1826 * 86_400)).to_i, row["retain_until"].to_i, 1
    text = pdf_text(bytes)

    [contract.code, "Joana Locatária", "CAM-CTR", "10/03/2026 05:00", "12/03/2026 05:00", "R$ 200,00", "R$ 500,00",
     "aceite eletrônico simples", "não equivale a assinatura digital certificada", "72 h ou mais antes do início: multa de 0%"].each do |fragment|
      assert_includes text, fragment
    end
    terms = data[:contract].terms

    assert_equal 20_000, terms["contracted_total_cents"]
    assert_equal 50_000, terms["deposit_cents"]
    assert_equal "America/Sao_Paulo", terms["period"]["timezone"]
    assert_equal D::Organizations::CancellationPolicy::DEFAULT["tiers"], terms["cancellation_policy"]["tiers"]
    assert_equal contract.code, document["data_snapshot"]["contract_code"]
    assert_raises(D::Conflict) { uc(:remove_attachment).call(@actor, document["attachment_id"]) }
    assert_equal 1, owner_query("SELECT count(*) AS n FROM outbox_events WHERE event_type = 'contract.issued'").first["n"].to_i
  end

  def test_issue_requires_a_confirmed_reservation
    held = reserve(@actor, @customer, @branch, period("2026-03-20T08:00:00Z", "2026-03-21T08:00:00Z"), [line(@camera, 1)])

    error = assert_raises(D::Conflict) { uc(:issue_contract).call(@actor, held.id) }
    assert_equal "reservation_not_confirmed", error.code
    assert_equal 0, owner_query("SELECT count(*) AS n FROM contracts").first["n"].to_i
  end

  def test_extension_amendment_records_adjustment_and_new_document_version
    contract = issue

    result = uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-13T08:00:00Z"))

    assert_equal 10_000, result[:adjustment].cents
    assert_equal 2, result[:contract].current_document_version
    data = uc(:get_contract).call(@actor, contract.id)
    amendment = data[:amendments].first

    assert_equal [1, "extension", 10_000, 2], amendment.values_at("number", "kind", "amount_delta_cents", "document_version")
    assert_equal "12/03/2026 05:00", amendment["changes"]["from_end_local"]
    assert_equal([2, 1], data[:documents].map { |d| d["version"] })
    refute_equal data[:documents].first["sha256"], data[:documents].last["sha256"]
    assert_equal 30_000, data[:current_total].cents
    pricing = uc(:get_reservation).call(@actor, @reservation.id)

    assert_equal t("2026-03-13T08:00:00Z"), pricing[:reservation].period.ends_at
    assert_equal([["extension", 10_000]], pricing[:pricing][:adjustments].map { |a| a.values_at("kind", "amount_cents") })
    text = pdf_text(download(data[:documents].first["attachment_id"]).last)

    assert_includes text, "Aditivo 1"
    assert_includes text, "13/03/2026 05:00"
    assert_includes text, "Total contratado vigente: R$ 300,00"
  end

  def test_extension_invading_another_reservation_is_refused_without_amendment
    contract = issue
    blocker = reserve(@actor, @customer, @branch, period("2026-03-12T08:00:00Z", "2026-03-13T08:00:00Z"), [line(@camera, 1)], mode: "confirm")

    error = assert_raises(D::Unavailable) { uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-12T20:00:00Z")) }
    assert_equal blocker.code, error.shortages.first["conflict"]
    data = uc(:get_contract).call(@actor, contract.id)

    assert_empty data[:amendments]
    assert_equal 1, data[:contract].current_document_version
    assert_equal 1, data[:documents].size
    assert_empty uc(:get_reservation).call(@actor, @reservation.id)[:pricing][:adjustments]
    assert_equal rental, uc(:get_reservation).call(@actor, @reservation.id)[:reservation].period
    assert_equal 1, owner_query("SELECT count(*) AS n FROM attachments WHERE owner_type = 'contract'").first["n"].to_i
  end

  def test_reservation_with_contract_must_be_changed_through_the_contract
    issue

    reschedule = assert_raises(D::Conflict) do
      uc(:reschedule_reservation).call(@actor, @reservation.id, period: period("2026-03-11T08:00:00Z", "2026-03-13T08:00:00Z"))
    end
    assert_equal "contract_amendment_required", reschedule.code
    assert_includes reschedule.message, "aditivo"
    extension = assert_raises(D::Conflict) { uc(:extend_reservation).call(@actor, @reservation.id, ends_at: t("2026-03-13T08:00:00Z")) }

    assert_includes extension.message, "aditivo"
    cancel = assert_raises(D::Conflict) { uc(:cancel_reservation).call(@actor, @reservation.id, reason: "desistência") }

    assert_includes cancel.message, "cancele pelo contrato"
    assert_equal "confirmed", uc(:get_reservation).call(@actor, @reservation.id)[:reservation].status
  end

  def test_cancellation_applies_the_policy_tier_for_the_notice_given
    contract = issue

    assert_equal 0, uc(:preview_contract_cancellation).call(@actor, contract.id).fee_bps
    @clock.travel_to(t("2026-03-08T20:00:00Z"))
    preview = uc(:preview_contract_cancellation).call(@actor, contract.id)

    assert_equal [3000, 6_000, 36], [preview.fee_bps, preview.fee.cents, preview.hours_before]
    @clock.travel_to(t("2026-03-09T20:00:00Z"))

    assert_equal 20_000, uc(:preview_contract_cancellation).call(@actor, contract.id).fee.cents
    @clock.travel_to(t("2026-03-08T20:00:00Z"))
    result = uc(:cancel_contract).call(@actor, contract.id, reason: "Evento adiado")

    assert_equal "cancelled", result[:contract].status
    assert_equal 6_000, result[:contract].cancellation_fee_cents
    details = uc(:get_reservation).call(@actor, @reservation.id)

    assert_equal "cancelled", details[:reservation].status
    assert_equal([["cancellation_fee", 6_000]], details[:pricing][:adjustments].map { |a| a.values_at("kind", "amount_cents") })
    assert_equal 0, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE active").first["n"].to_i
    assert_raises(D::InvalidTransition) { uc(:cancel_contract).call(@actor, contract.id, reason: "de novo") }
    assert_equal 1, owner_query("SELECT count(*) AS n FROM outbox_events WHERE event_type = 'contract.cancelled'").first["n"].to_i
  end

  def test_cancellation_with_notice_has_no_fee_and_amendments_raise_the_base
    contract = issue
    uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-13T08:00:00Z"))
    @clock.travel_to(t("2026-03-09T00:00:00Z"))

    assert_equal 9_000, uc(:preview_contract_cancellation).call(@actor, contract.id).fee.cents, "30% de R$ 300,00"
    @clock.travel_to(t("2026-03-02T12:00:00Z"))
    result = uc(:cancel_contract).call(@actor, contract.id, reason: "Cliente cancelou com antecedência")

    assert_equal 0, result[:preview].fee.cents
    kinds = uc(:get_reservation).call(@actor, @reservation.id)[:pricing][:adjustments].map { |a| a["kind"] }

    assert_equal ["extension"], kinds, "sem multa, nenhum ajuste de cancelamento é gravado"
  end

  def test_acceptance_is_recorded_once_and_activates_the_contract
    contract = issue

    assert_raises(D::ValidationError) { uc(:accept_contract).call(@actor, contract.id, name: "Joana", document: "52998224725") }
    assert_raises(D::ValidationError) do
      uc(:accept_contract).call(@actor, contract.id, name: "Joana Locatária", document: "123.456.789-00", confirmed: true)
    end
    accepted = uc(:accept_contract).call(@actor, contract.id, name: "Joana Locatária", document: "529.982.247-25", user_agent: "Navegador/1.0",
                                                              confirmed: true)

    assert_equal "active", accepted.status
    document = uc(:get_contract).call(@actor, contract.id)[:documents].first

    assert_equal ["Joana Locatária", "52998224725", "198.51.100.20", "Navegador/1.0", "staff"],
                 document.values_at("accepted_by_name", "accepted_by_document", "accepted_ip", "user_agent", "accepted_via")
    assert_equal D::Contracts::ACCEPTANCE_STATEMENT, document["acceptance_statement"]
    again = assert_raises(D::Conflict) do
      uc(:accept_contract).call(@actor, contract.id, name: "Joana Locatária", document: "52998224725", confirmed: true)
    end
    assert_equal "already_accepted", again.code
    uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-13T08:00:00Z"))

    assert_equal "active", uc(:accept_contract).call(@actor, contract.id, name: "Joana Locatária", document: "52998224725", confirmed: true).status
  end

  def test_documents_terms_and_amendments_are_immutable_in_the_database
    contract = issue
    uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-13T08:00:00Z"))
    tenant = ->(&block) { @system.transactor.call(tenant_id: @org[:organization_id], &block) }

    assert_raises(D::ValidationError) { tenant.call { |tx| tx.execute("UPDATE contracts SET terms_snapshot = '{}'::jsonb") } }
    assert_raises(D::ValidationError) { tenant.call { |tx| tx.execute("UPDATE contracts SET code = 'C-999999'") } }
    assert_raises(D::ValidationError) { tenant.call { |tx| tx.execute("UPDATE contract_documents SET sha256 = repeat('0', 64)") } }
    assert_raises(D::AccessDenied) { tenant.call { |tx| tx.execute("UPDATE contract_amendments SET amount_delta_cents = 0") } }
    assert_raises(D::AccessDenied) { tenant.call { |tx| tx.execute("DELETE FROM contract_documents") } }
    assert_raises(D::AccessDenied) { tenant.call { |tx| tx.execute("DELETE FROM contracts") } }
    assert_equal 10_000, owner_query("SELECT amount_delta_cents FROM contract_amendments").first["amount_delta_cents"].to_i
  end

  def test_contract_closes_only_after_the_reservation_is_completed
    contract = issue
    uc(:accept_contract).call(@actor, contract.id, name: "Joana Locatária", document: "52998224725", confirmed: true)

    error = assert_raises(D::Conflict) { uc(:close_contract).call(@actor, contract.id) }
    assert_equal "reservation_not_completed", error.code
    owner_query("UPDATE reservations SET status = 'completed' WHERE id = $1", [@reservation.id])
    closed = uc(:close_contract).call(@actor, contract.id)

    assert_equal "closed", closed.status
    assert_raises(D::InvalidTransition) { uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-13T08:00:00Z")) }
    assert_raises(D::InvalidTransition) do
      uc(:accept_contract).call(@actor, contract.id, name: "Joana Locatária", document: "52998224725", confirmed: true)
    end
    assert_raises(D::ValidationError, "contrato encerrado é imutável no banco") do
      @system.transactor.call(tenant_id: @org[:organization_id]) { |tx| tx.execute("UPDATE contracts SET status = 'active'") }
    end
  end

  def test_contract_from_converted_quote_carries_quote_terms
    other = period("2026-03-20T08:00:00Z", "2026-03-21T08:00:00Z")
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: other, lines: [line(@camera, 1)],
                                             valid_until: t("2026-03-06T00:00:00Z"), terms: "Montagem incluída no valor." })
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Joana Locatária")
    reservation = uc(:convert_quote).call(@actor, quote.id).reservation

    contract = uc(:issue_contract).call(@actor, reservation.id)

    assert_equal "Montagem incluída no valor.", contract.terms["conditions"]
    assert_equal [quote.code, 1], contract.terms["quote"].values_at("code", "version")
    assert_equal quote.id, contract.quote_id
    links = uc(:reservation_links).call(@actor, reservation.id)

    assert_equal [contract.id, quote.id], [links[:contract].id, links[:quote].id]
  end

  def test_contracts_are_isolated_between_organizations
    contract = issue
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")
    document = uc(:get_contract).call(@actor, contract.id)[:documents].first

    assert_raises(D::NotFound) { uc(:get_contract).call(beta[:actor], contract.id) }
    assert_raises(D::NotFound) { uc(:issue_contract).call(beta[:actor], @reservation.id) }
    assert_raises(D::NotFound) { uc(:cancel_contract).call(beta[:actor], contract.id, reason: "intruso") }
    assert_raises(D::NotFound) { uc(:download_attachment).call(beta[:actor], document["attachment_id"]) }
    assert_equal 0, uc(:list_contracts).call(beta[:actor]).total
    assert_equal 1, uc(:list_contracts).call(@actor, search: "joana").total
    assert_equal 0, uc(:list_contracts).call(@actor, status: "active").total
  end

  def test_customer_actor_accepts_only_own_contract
    contract = issue
    user_id = SecureRandom.uuid
    other = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    owner_query("INSERT INTO users (id, email, name, password_digest, created_at, updated_at) VALUES ($1, 'portal@example.test', 'Portal', 'x', now(), now())",
                [user_id])
    owner_query("INSERT INTO portal_accesses (id, organization_id, user_id, customer_id, created_at) VALUES ($1, $2, $3, $4, now())",
                [SecureRandom.uuid, @org[:organization_id], user_id, other.id])
    stranger = A::Actor.customer(user_id: user_id, organization_id: @org[:organization_id], customer_id: other.id, ip: "203.0.113.5")

    assert_raises(D::NotFound) { uc(:get_contract).call(stranger, contract.id) }
    assert_raises(D::NotFound) do
      uc(:accept_contract).call(stranger, contract.id, name: "Outro Cliente", document: "11144477735", confirmed: true)
    end
    owner_query("UPDATE portal_accesses SET customer_id = $1 WHERE user_id = $2", [@customer.id, user_id])
    owner = A::Actor.customer(user_id: user_id, organization_id: @org[:organization_id], customer_id: @customer.id, ip: "203.0.113.5")
    accepted = uc(:accept_contract).call(owner, contract.id, name: "Joana Locatária", document: "52998224725", confirmed: true)

    assert_equal "active", accepted.status
    assert_equal "portal", uc(:get_contract).call(@actor, contract.id)[:documents].first["accepted_via"]
  end
end
