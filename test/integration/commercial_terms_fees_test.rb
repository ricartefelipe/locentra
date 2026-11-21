# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/commercial_terms_support"
require_relative "../support/portal_support"

# Tarifas adicionais em reservas e orçamentos: valor padrão para quem registra o documento, ajuste e
# tarifa avulsa com a permissão de ajustar tarifas, redução limitada ao desconto do papel e
# continuidade das tarifas já autorizadas na nova versão do orçamento.
class CommercialTermsFeesTest < DatabaseTest
  include CommercialTermsSupport
  include PortalHelpers

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-TAR", tracking: "bulk", pricing: { "daily_cents" => 10_000 }, deposit: D::Money.new(5_000))
    stock(@actor, @chairs, @branch, 50)
    @delivery = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    @manager = staff_member(@org, "gerente@alfa.test", "manager")
    @attendant = staff_member(@org, "atendente@alfa.test", "attendant")
  end

  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))

  def book(actor, fees, day: 10, **)
    reserve(actor, @customer, @branch, window(day), [line(@chairs, 1)], mode: "confirm", fees: fees, **)
  end

  def quote_input(fees, **extra)
    { customer_id: @customer.id, branch_id: @branch.id, period: window, lines: [line(@chairs, 1)], valid_until: @clock.now + 86_400, fees: fees,
      terms: "Entrega no local do evento." }.merge(extra)
  end

  def current_version(quote) = uc(:get_quote).call(@actor, quote.id)[:current]
  def denied(&) = assert_raises(D::AccessDenied, &).message
  def parking = custom_fee("Taxa de estacionamento", 3_000)

  def stored_pricing
    rows = owner_query("SELECT pricing::text AS pricing FROM reservations UNION ALL SELECT pricing::text FROM quote_versions")
    rows.map { |row| row["pricing"] }
  end

  def pdf_text(contract)
    document = uc(:get_contract).call(@actor, contract.id)[:documents].first
    bytes = uc(:download_attachment).call(@actor, document["attachment_id"]).last
    bytes.b.scan(/<([0-9a-f]+)> Tj/).map { |(hex)| [hex].pack("H*").force_encoding("Windows-1252").encode("UTF-8") }.join(" ")
  end

  def test_catalog_fee_at_the_default_amount_needs_only_the_document_permission
    reservation = book(@attendant, [catalog_fee(@delivery)], coupon_code: create_coupon("DEZ").code, manual_discount_bps: 500)
    summary = summary_of(reservation)

    assert_equal [{ "fee_id" => @delivery.id, "code" => "ENTREGA", "description" => "Entrega e retirada no local", "amount_cents" => 15_000,
                    "default_amount_cents" => 15_000, "source" => "catalog" }], summary["fees"]
    assert_equal [10_000, 1_000, 450, 15_000, 23_550], summary.values_at("subtotal_cents", "coupon_discount_cents", "manual_discount_cents",
                                                                         "fees_cents", "total_cents")
    assert_equal 23_550, reservation.total.cents, "subtotal − cupom − desconto manual + tarifas"
    details = audit_events("reservation.created").first["details"]

    assert_equal [15_000, false], [details["fees_cents"], details.key?("fee_overrides")]
    quote = uc(:create_quote).call(@attendant, quote_input([catalog_fee(@delivery)]))
    version = current_version(quote)

    assert_equal [summary["fees"], 25_000], [version.pricing["fees"], version.total.cents]
    assert_equal([15_000, false], audit_events("quote.created").first["details"].then { |d| [d["fees_cents"], d.key?("fee_overrides")] })
    assert_equal 15_000, book(@attendant, [catalog_fee(@delivery, 15_000)], day: 12).total.cents - 10_000, "valor igual ao padrão não é ajuste"
  end

  def test_attendant_cannot_adjust_amounts_or_add_custom_fees
    message = denied { book(@attendant, [catalog_fee(@delivery, 20_000)]) }

    assert_equal "valor diferente do padrão ou tarifa avulsa exige a permissão de ajustar tarifas (gerente, administrador ou proprietário): " \
                 "Entrega e retirada no local R$ 200,00 (padrão R$ 150,00)", message
    assert_includes denied { book(@attendant, [catalog_fee(@delivery, 14_999)]) }, "R$ 149,99 (padrão R$ 150,00)"
    assert_includes denied { book(@attendant, [parking]) }, "Taxa de estacionamento R$ 30,00 (avulsa)"
    assert_includes denied { uc(:create_quote).call(@attendant, quote_input([catalog_fee(@delivery), parking])) }, "exige a permissão de ajustar tarifas"
    assert_equal [0, 0], [owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i,
                          owner_query("SELECT count(*) AS n FROM quotes").first["n"].to_i]
  end

  def test_manager_adjustments_are_audited_and_never_stored_in_the_pricing_snapshot
    reservation = book(@manager, [catalog_fee(@delivery, 20_000), parking])
    summary = summary_of(reservation)

    assert_equal([[20_000, 15_000, "catalog"], [3_000, nil, "custom"]],
                 summary["fees"].map { |fee| fee.values_at("amount_cents", "default_amount_cents", "source") })
    assert_equal [23_000, 33_000], summary.values_at("fees_cents", "total_cents")
    expected = [
      { "fee_id" => @delivery.id, "code" => "ENTREGA", "description" => "Entrega e retirada no local", "amount_cents" => 20_000,
        "default_amount_cents" => 15_000, "source" => "catalog" },
      { "fee_id" => nil, "code" => nil, "description" => "Taxa de estacionamento", "amount_cents" => 3_000, "default_amount_cents" => nil,
        "source" => "custom" }
    ]
    created = audit_events("reservation.created").first

    assert_equal [expected, 23_000, @manager.user_id], [created["details"]["fee_overrides"], created["details"]["fees_cents"], created["actor_id"]]
    uc(:create_quote).call(@manager, quote_input([catalog_fee(@delivery, 20_000)]))

    assert_equal expected.first(1), audit_events("quote.created").first["details"]["fee_overrides"]
    stored_pricing.each { |pricing| refute_match(/override/, pricing) }
    assert_equal 2, stored_pricing.size
  end

  def test_reduction_is_limited_to_the_manual_discount_limit_of_the_role
    assert_equal 22_000, book(@manager, [catalog_fee(@delivery, 12_000)]).total.cents, "20% exatos para o gerente"
    message = denied { book(@manager, [catalog_fee(@delivery, 11_999)], day: 12) }

    assert_equal "redução da tarifa ENTREGA acima do limite autorizado para o papel (20%)", message
    assert_equal 10_001, book(@actor, [catalog_fee(@delivery, 1)], day: 12).total.cents, "proprietário sem limite de redução"
    assert_equal 30_000, book(@manager, [catalog_fee(@delivery, 20_000)], day: 14).total.cents, "acima do padrão não é redução"
  end

  def test_credential_with_override_scope_raises_but_never_reduces
    scopes = %w[reservations.read reservations.write fees.override]
    credential = uc(:authenticate_credential).call(uc(:create_credential).call(@actor, name: "ERP", scopes: scopes, expires_in_days: 30)["token"])
    plain = uc(:authenticate_credential).call(uc(:create_credential).call(@actor, name: "Loja", scopes: scopes.first(2), expires_in_days: 30)["token"])

    assert_equal 33_000, book(credential, [catalog_fee(@delivery, 20_000), parking]).total.cents
    assert_equal("redução da tarifa ENTREGA acima do limite autorizado para o papel (0%)",
                 denied { book(credential, [catalog_fee(@delivery, 14_999)], day: 12) })
    assert_equal 25_000, book(plain, [catalog_fee(@delivery)], day: 12).total.cents
    assert_includes denied { book(plain, [catalog_fee(@delivery, 20_000)], day: 14) }, "exige a permissão de ajustar tarifas"
    created = audit_events("reservation.created").first

    assert_equal ["api", credential.credential_id, 2], [created["actor_type"], created["actor_id"], created["details"]["fee_overrides"].size]
  end

  def test_inactive_repeated_unknown_and_excessive_fees_are_refused
    assembly = create_fee("MONTAGEM", "Montagem e desmontagem", 25_000)
    uc(:set_fee_active).call(@actor, assembly.id, active: false)
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    foreign = create_fee("ENTREGA", "Entrega da Beta", 20_000, actor: other[:actor])

    assert_equal ["a tarifa MONTAGEM está inativa"], error_fields { book(@actor, [catalog_fee(assembly)]) }["tarifas"]
    assert_equal ["a tarifa ENTREGA foi informada mais de uma vez"],
                 error_fields { book(@actor, [catalog_fee(@delivery), catalog_fee(@delivery, 16_000)]) }["tarifas"]
    assert_equal "tarifa não encontrada", assert_raises(D::NotFound) { book(@actor, [catalog_fee(foreign)]) }.message
    many = Array.new(11) { |i| custom_fee("Taxa #{i}", 100) }

    assert_equal ["no máximo 10 tarifas"], error_fields { book(@actor, many) }["tarifas"]
    assert_equal 11_000, book(@actor, many.first(10)).total.cents
    uc(:set_fee_active).call(@actor, assembly.id, active: true)

    assert_equal 50_000, book(@attendant, [catalog_fee(@delivery), catalog_fee(assembly)], day: 12).total.cents
    assert_equal %w[fee.created fee.deactivated fee.reactivated], uc(:get_fee).call(@actor, "montagem")[:history].map { |e| e["action"] }.sort
  end

  def test_attendant_revision_keeps_fees_already_authorized_by_the_manager
    kept = [catalog_fee(@delivery, 20_000), parking]
    quote = uc(:create_quote).call(@manager, quote_input(kept))
    uc(:set_fee_active).call(@actor, @delivery.id, active: false)
    uc(:revise_quote).call(@attendant, quote.id, quote_input(kept, terms: "Retirada na loja."))
    second = current_version(quote)

    assert_equal [2, [20_000, 3_000], 33_000], [second.number, second.pricing["fees"].map { |fee| fee["amount_cents"] }, second.total.cents]
    revised = audit_events("quote.revised").first

    assert_equal [23_000, false, @attendant.user_id], [revised["details"]["fees_cents"], revised["details"].key?("fee_overrides"), revised["actor_id"]]
    assert_equal ["a tarifa ENTREGA está inativa"],
                 error_fields { uc(:revise_quote).call(@attendant, quote.id, quote_input([catalog_fee(@delivery), parking])) }["tarifas"]
    assert_includes denied { uc(:revise_quote).call(@attendant, quote.id, quote_input([kept.first, custom_fee("Taxa de estacionamento", 3_500)])) },
                    "R$ 35,00 (avulsa)"
    uc(:set_fee_active).call(@actor, @delivery.id, active: true)

    assert_includes denied { uc(:revise_quote).call(@attendant, quote.id, quote_input([catalog_fee(@delivery, 21_000), parking])) },
                    "R$ 210,00 (padrão R$ 150,00)"
    unchanged = error_fields { uc(:revise_quote).call(@attendant, quote.id, quote_input(kept, terms: "Retirada na loja.")) }

    assert_includes unchanged["base"].first, "nenhuma alteração"
    uc(:revise_quote).call(@attendant, quote.id, quote_input([kept.first], terms: "Retirada na loja."))

    assert_equal [3, 30_000], current_version(quote).then { |version| [version.number, version.total.cents] }, "versão que só muda as tarifas"
    uc(:revise_quote).call(@manager, quote.id, quote_input([parking], terms: "Retirada na loja."))

    assert_equal 1, audit_events("quote.revised").last["details"]["fee_overrides"].size, "avulsa nova na versão exige e audita o ajuste"
    stored_pricing.each { |pricing| refute_match(/override/, pricing) }
  end

  def test_default_amount_change_applies_to_new_versions_unless_the_fee_was_kept_adjusted
    quote = uc(:create_quote).call(@attendant, quote_input([catalog_fee(@delivery)]))
    result = uc(:update_fee).call(@actor, @delivery.id, { default_amount: D::Money.new(18_000), description: "Até 30 km" }, lock_version: 1)

    assert_equal [true, 18_000, 2], [result.changed, result.record.default_amount.cents, result.record.lock_version]
    assert_equal({ "changes" => { "default_amount_cents" => [15_000, 18_000], "description" => [nil, "Até 30 km"] } },
                 audit_events("fee.updated").first["details"])
    assert_equal 25_000, current_version(quote).total.cents, "versões já registradas não mudam"
    uc(:revise_quote).call(@attendant, quote.id, quote_input([catalog_fee(@delivery)]))

    assert_equal([28_000, 18_000], current_version(quote).then { |v| [v.total.cents, v.pricing["fees"].first["default_amount_cents"]] })
    uc(:revise_quote).call(@attendant, quote.id, quote_input([catalog_fee(@delivery, 18_000)], terms: "Retirada na loja."))

    assert_equal 28_000, current_version(quote).total.cents
    assert_equal("stale_fee", conflict_code { uc(:update_fee).call(@actor, @delivery.id, { name: "Frete" }, lock_version: 1) })
    refute uc(:update_fee).call(@actor, "ENTREGA", { description: "Até 30 km" }).changed
    assert_equal 1, audit_events("fee.updated").size
    assert_equal("fee_code_taken", conflict_code { create_fee("entrega", "Outra entrega", 1_000) })
    page = uc(:list_fees).call(@attendant, status: "active", search: "entre")

    assert_equal [1, "ENTREGA", "Dona Locadora Alfa"], [page.total, page.items.first.code, uc(:get_fee).call(@attendant, @delivery.id)[:created_by_name]]
  end

  def test_conversion_carries_fees_to_the_reservation_the_charge_the_terms_and_the_pdf
    create_agreement(@customer, 800)
    quote = uc(:create_quote).call(@manager, quote_input([catalog_fee(@delivery), parking]))
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria Compradora")
    reservation = uc(:convert_quote).call(@actor, quote.id).reservation
    summary = summary_of(reservation)

    assert_equal current_version(quote).pricing["fees"], summary["fees"]
    assert_equal [9_200, 18_000, 27_200], summary.values_at("subtotal_cents", "fees_cents", "total_cents")
    uc(:sync_reservation_charges).call(@actor, reservation.id)
    rental = uc(:finance).reservation(@actor, reservation.id)[:receivables].map { |row| row[:receivable] }.find { |r| r.kind == "rental" }

    assert_equal 27_200, rental.amount.cents, "a cobrança da locação inclui as tarifas"
    contract = uc(:issue_contract).call(@actor, reservation.id)
    pricing = contract.terms["pricing"]

    assert_equal [summary["fees"], summary["agreements"], nil], pricing.values_at("fees", "agreements", "coupon")
    assert_equal [800, 800], contract.terms["items"].first.values_at("negotiated_discount_bps", "negotiated_discount_cents")
    text = pdf_text(contract)

    ["condição negociada -8% (-R$ 8,00)", "Condição negociada do cliente: 8% em todos os produtos", "Entrega e retirada no local: R$ 150,00",
     "Taxa de estacionamento: R$ 30,00", "Valor da locação na emissão: R$ 272,00"].each { |fragment| assert_includes text, fragment }
    refute_includes text, "?", "nenhum caractere fora da codificação do documento"
    refute_includes text, "avulsa", "marcações internas não vão ao cliente"
    refute_includes text, "padrão"
  end

  def test_contract_pdf_describes_coupons_and_product_agreements
    create_agreement(@customer, 1_000, product: "CAD-TAR")
    create_coupon("BEMVINDO10")
    create_coupon("FIXO5", kind: "fixed", value: 500)
    percent = uc(:issue_contract).call(@actor, book(@actor, [], coupon_code: "BEMVINDO10").id)
    fixed = uc(:issue_contract).call(@actor, book(@actor, [catalog_fee(@delivery)], day: 12, coupon_code: "FIXO5").id)

    assert_equal ["BEMVINDO10", "percent", 1000], percent.terms["pricing"]["coupon"].values_at("code", "kind", "value")
    text = pdf_text(percent)

    ["Condição negociada do cliente: 10% em CAD-TAR", "Desconto por cupom BEMVINDO10 (10%): -R$ 9,00", "condição negociada -10% (-R$ 10,00)",
     "Valor da locação na emissão: R$ 81,00"].each { |fragment| assert_includes text, fragment }
    assert_includes pdf_text(fixed), "Desconto por cupom FIXO5 (valor fixo): -R$ 5,00"
    refute_includes text + pdf_text(fixed), "?"
  end
end
