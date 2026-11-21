# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/commercial_terms_support"

# Condições negociadas por cliente: vale o maior desconto entre a condição do produto e a geral, com
# vigência semiaberta, encerramento único (imediato ou agendado) e sem sobreposição no mesmo escopo.
class CommercialTermsAgreementsTest < DatabaseTest
  include CommercialTermsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor].with(request_id: "req-condicoes-0001")
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = bulk("CAM-COND", 45_000)
    @lens = bulk("LEN-COND", 12_000)
  end

  def bulk(sku, daily)
    create_product(@actor, sku: sku, tracking: "bulk", pricing: { "daily_cents" => daily }).tap { |product| stock(@actor, product, @branch, 20) }
  end

  def now = @clock.now
  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 2))
  def book(*products, day: 10) = reserve(@actor, @customer, @branch, window(day), products.map { |product| line(product, 1) }, mode: "request")
  def items_of(reservation) = uc(:get_reservation).call(@actor, reservation.id)[:items].map { |item| item["pricing"] }
  def listed = uc(:list_price_agreements).call(@actor, @customer.id).items
  def finish(agreement, **) = uc(:end_price_agreement).call(@actor, agreement.id, **)

  def test_greatest_discount_between_product_and_general_agreement_is_applied_and_traceable
    general = create_agreement(@customer, 800, notes: "Contrato anual de produção")
    specific = create_agreement(@customer, 1_000, product: @lens.id)
    reservation = book(@camera, @lens)
    camera, lens = items_of(reservation)

    assert_equal [general.id, 800, 7_200, 82_800], camera.values_at("negotiated_agreement_id", "negotiated_discount_bps",
                                                                    "negotiated_discount_cents", "total_cents")
    assert_equal [specific.id, 1_000, 2_400, 21_600], lens.values_at("negotiated_agreement_id", "negotiated_discount_bps",
                                                                     "negotiated_discount_cents", "total_cents")
    summary = summary_of(reservation)

    assert_equal [104_400, 104_400], summary.values_at("subtotal_cents", "total_cents")
    assert_equal [general.to_snapshot, specific.to_snapshot], summary["agreements"]
    refute_includes JSON.generate(summary), "Contrato anual", "observações internas não entram no snapshot"
    assert_equal([["general", nil], ["product", @lens.id]], summary["agreements"].map { |entry| entry.values_at("scope", "product_id") })
    other = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    plain = reserve(@actor, other, @branch, window(14), [line(@camera, 1)], mode: "request")

    assert_equal [90_000, []], summary_of(plain).values_at("total_cents", "agreements"), "a condição vale só para o cliente"
    created = audit_events("price_agreement.created").first

    assert_equal ["user", @org[:user_id], "price_agreement", general.id, "req-condicoes-0001"],
                 created.values_at("actor_type", "actor_id", "resource_type", "resource_id", "request_id")
    assert_equal({ "customer_id" => @customer.id, "product_id" => nil, "discount_bps" => 800, "valid_from" => now.iso8601, "valid_until" => nil },
                 created["details"])
  end

  def test_tie_prefers_the_product_agreement_and_a_greater_general_one_wins
    general = create_agreement(@customer, 1_000)
    tied = create_agreement(@customer, 1_000, product: "cam-cond")
    smaller = create_agreement(@customer, 500, product: @lens.id)
    camera, lens = items_of(book(@camera, @lens))

    assert_equal [tied.id, general.id], [camera["negotiated_agreement_id"], lens["negotiated_agreement_id"]]
    assert_equal [1_000, 1_000], [camera["negotiated_discount_bps"], lens["negotiated_discount_bps"]]
    assert_equal "product", smaller.scope
    assert_equal @camera.id, tied.product_id, "o SKU é aceito sem diferenciar maiúsculas"
  end

  def test_scheduled_agreement_applies_only_from_its_start
    scheduled = create_agreement(@customer, 800, valid_from: now + 86_400, valid_until: now + (3 * 86_400))

    assert_equal ["scheduled", now + 86_400], [listed.first[:status], scheduled.valid_from]
    assert_equal 90_000, book(@camera).total.cents
    @clock.advance(86_400)

    assert_equal [82_800, "active"], [book(@camera, day: 12).total.cents, listed.first[:status]]
    @clock.advance(2 * 86_400)

    assert_equal [90_000, "expired"], [book(@camera, day: 14).total.cents, listed.first[:status]], "fim exclusivo"
    assert_raises(D::InvalidTransition) { finish(scheduled, reason: "Tarde demais") }
  end

  def test_ending_an_agreement_does_not_change_existing_reservations
    agreement = create_agreement(@customer, 800)
    before = book(@camera)
    @clock.advance(3_600)
    ended = finish(agreement, reason: "  Contrato encerrado pelo cliente ")

    assert_equal [now, @org[:user_id], "Contrato encerrado pelo cliente", "ended"], [ended.ended_at, ended.ended_by, ended.end_reason,
                                                                                     ended.status(now)]
    assert_equal [82_800, agreement.id], [summary_of(before)["total_cents"], items_of(before).first["negotiated_agreement_id"]]
    assert_equal [90_000, []], summary_of(book(@camera, day: 14)).values_at("total_cents", "agreements")
    details = audit_events("price_agreement.ended").first["details"]

    assert_equal({ "customer_id" => @customer.id, "reason" => "Contrato encerrado pelo cliente", "ended_at" => now.iso8601, "scheduled" => false,
                   "previous_status" => "active" }, details)
    error = assert_raises(D::InvalidTransition) { finish(agreement, reason: "Outra vez") }

    assert_equal "Transição inválida em condição negociada: Encerrada → Encerrada", error.message
    item = listed.first

    assert_equal ["ended", "Dona Locadora Alfa", "Dona Locadora Alfa", nil], item.values_at(:status, :created_by_name, :ended_by_name, :product)
    assert_equal 800, create_agreement(@customer, 800).discount_bps, "encerrar e cadastrar em seguida"
  end

  def test_scheduled_end_allows_a_replacement_without_gap_or_overlap
    current = create_agreement(@customer, 800)
    switch = now + (2 * 86_400)

    assert_equal("price_agreement_overlap", conflict_code { create_agreement(@customer, 1_200, valid_from: switch) })
    ending = finish(current, reason: "Renegociação anual", at: switch)

    assert_equal ["active", true], [ending.status(now), ending.end_scheduled?(now)]
    assert audit_events("price_agreement.ended").first["details"]["scheduled"]
    replacement = create_agreement(@customer, 1_200, valid_from: switch)

    assert_equal [%w[scheduled active], 2], [listed.map { |item| item[:status] }, uc(:list_price_agreements).call(@actor, @customer.id).total]
    assert_equal 82_800, book(@camera).total.cents
    @clock.advance((2 * 86_400) - 1)

    assert_equal current.id, items_of(book(@camera, day: 12)).first["negotiated_agreement_id"]
    @clock.advance(1)

    assert_equal [replacement.id, 1_200], items_of(book(@camera, day: 14)).first.values_at("negotiated_agreement_id", "negotiated_discount_bps")
    assert_equal(%w[active ended], listed.map { |item| item[:status] })
    assert_raises(D::InvalidTransition) { finish(current, reason: "Já encerrada") }
  end

  def test_overlapping_agreements_and_invalid_input_are_refused
    create_agreement(@customer, 800, valid_until: now + (10 * 86_400))
    error = assert_raises(D::Conflict) { create_agreement(@customer, 500, valid_from: now + 86_400) }

    assert_equal ["price_agreement_overlap", "já existe condição vigente ou agendada para este cliente e escopo no período; " \
                                             "encerre-a ou agende o encerramento antes"], [error.code, error.message]
    assert_equal 500, create_agreement(@customer, 500, valid_from: now + (10 * 86_400)).discount_bps, "a seguinte começa no fim da anterior"
    assert_equal ["entre 0,01% e 90%"], error_fields { create_agreement(@customer, 9_001, product: @lens.id) }["desconto"]
    assert_equal ["o início não pode estar mais de 24 horas no passado; deixe em branco para valer a partir de agora"],
                 error_fields { create_agreement(@customer, 500, product: @lens.id, valid_from: now - 86_401) }["valido_de"]
    assert_equal ["deve ser posterior ao momento atual"],
                 error_fields { create_agreement(@customer, 500, product: @lens.id, valid_until: now) }["valido_ate"]
    assert_equal ["até 500 caracteres"], error_fields { create_agreement(@customer, 500, product: @lens.id, notes: "a" * 501) }["observacoes"]
    adjusted = create_agreement(@customer, 500, product: @lens.id, valid_from: now - 3_600)

    assert_equal now, adjusted.valid_from, "início recente no passado vale a partir de agora"
    assert_equal 3, owner_query("SELECT count(*) AS n FROM customer_price_agreements").first["n"].to_i
  end

  def test_product_and_customer_references_are_checked_inside_the_organization
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    foreign = create_product(other[:actor], sku: "CAM-BETA", tracking: "bulk")
    foreign_customer = create_customer(other[:actor])

    assert_equal "produto não encontrado", assert_raises(D::NotFound) { create_agreement(@customer, 500, product: foreign.id) }.message
    assert_raises(D::NotFound) { create_agreement(@customer, 500, product: "CAM-BETA") }
    assert_raises(D::NotFound) { create_agreement(@customer, 500, product: "INEXISTENTE") }
    assert_equal "cliente não encontrado", assert_raises(D::NotFound) { create_agreement(foreign_customer, 500) }.message
    assert_raises(D::ValidationError) { uc(:create_price_agreement).call(@actor, "cliente", { discount_bps: 500 }) }
    owner_query("UPDATE products SET active = false WHERE id = $1", [@lens.id])

    assert_equal ["produto inativo"], error_fields { create_agreement(@customer, 500, product: "LEN-COND") }["produto"]
    blocked = uc(:update_customer).call(@actor, @customer.id, { status: "blocked" })

    assert_equal "blocked", blocked.status
    assert_equal @camera.id, create_agreement(@customer, 500, product: " cam-cond ").product_id, "cliente em qualquer situação"
    assert_empty audit_events("price_agreement.created", org: other)
  end

  def test_end_requires_reason_instant_before_the_effective_end_and_the_right_customer
    agreement = create_agreement(@customer, 800, valid_until: now + 86_400)
    other = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    missing = assert_raises(D::NotFound) { finish(agreement, reason: "Encerrar", customer_id: other.id) }

    assert_equal "condição negociada não encontrada", missing.message
    assert_raises(D::NotFound) { uc(:end_price_agreement).call(@actor, SecureRandom.uuid, reason: "Encerrar") }
    assert_raises(D::NotFound) { uc(:end_price_agreement).call(@actor, "condicao", reason: "Encerrar") }
    assert_equal ["deve ter entre 3 e 500 caracteres"], error_fields { finish(agreement, reason: "ok") }["motivo"]
    assert_equal ["a condição já termina em 03/03/2026 09:00"], error_fields { finish(agreement, reason: "Encerrar", at: now + 86_400) }["encerrar_em"]
    assert_equal ["o encerramento não pode estar mais de 24 horas no passado; deixe em branco para encerrar agora"],
                 error_fields { finish(agreement, reason: "Encerrar", at: now - 90_000) }["encerrar_em"]
    assert_empty audit_events("price_agreement.ended")
    ended = finish(agreement, reason: "Encerrar", at: now - 600, customer_id: @customer.id)

    assert_equal now, ended.ended_at, "instante recente no passado vale agora"
    scheduled = create_agreement(@customer, 500, valid_from: now + 86_400)
    revoked = finish(scheduled, reason: "Cadastrada por engano")

    assert_equal %w[ended scheduled], [revoked.status(now + 90_000), audit_events("price_agreement.ended").last["details"]["previous_status"]]
    assert_equal 90_000, book(@camera, day: 14).total.cents
  end

  def test_listing_is_paginated_and_shows_the_product_only_with_catalog_scope
    create_agreement(@customer, 800)
    create_agreement(@customer, 1_000, product: @lens.id)
    page = uc(:list_price_agreements).call(@actor, @customer.id, limit: 1, offset: 1)

    assert_equal [2, 1, 1], [page.total, page.items.size, page.offset]
    products = listed.map { |item| item[:product] }

    assert_includes products, { id: @lens.id, sku: "LEN-COND", name: "Produto LEN-COND" }
    assert_includes products, nil
    token = uc(:create_credential).call(@actor, name: "BI", scopes: %w[price_agreements.read], expires_in_days: 30)["token"]
    credential = uc(:authenticate_credential).call(token)

    assert_equal([nil, nil], uc(:list_price_agreements).call(credential, @customer.id).items.map { |item| item[:product] })
    assert_raises(D::NotFound) { uc(:list_price_agreements).call(@actor, SecureRandom.uuid) }
    assert_raises(D::ValidationError) { uc(:list_price_agreements).call(@actor, @customer.id, limit: 101) }
  end
end
