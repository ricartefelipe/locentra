# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/commercial_terms_support"

# Cadastro de cupons e uso por reserva: o uso é uma linha do livro por reserva e deixa de ser ativo
# pela situação da reserva (cancelamento ou expiração), sem nenhuma escrita no cupom.
class CommercialTermsCouponsTest < DatabaseTest
  include CommercialTermsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor].with(request_id: "req-cupons-0001")
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @chairs = bulk("CAD-CUP")
  end

  def bulk(sku)
    create_product(@actor, sku: sku, tracking: "bulk", pricing: { "daily_cents" => 10_000 }).tap { |product| stock(@actor, product, @branch, 20) }
  end

  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def book(product: @chairs, day: 10, mode: "confirm", **) = reserve(@actor, @customer, @branch, window(day), [line(product, 1)], mode: mode, **)
  def coupon_error(**) = error_fields { book(**) }["cupom"]
  def system_actor = A::Actor.system(organization_id: @org[:organization_id])
  def coupon_row(id) = owner_query("SELECT redemptions, lock_version, updated_at FROM coupons WHERE id = $1", [id]).first

  def test_coupon_is_created_redeemed_by_a_reservation_and_listed_with_its_uses
    coupon = create_coupon(" bemvindo10 ", description: "Boas-vindas", max_redemptions: 100, valid_until: @clock.now + (30 * 86_400))
    reservation = book(coupon_code: "bemvindo10")
    summary = summary_of(reservation)

    assert_equal ["BEMVINDO10", 10_000, 1_000, 9_000], summary.values_at("coupon_code", "subtotal_cents", "coupon_discount_cents", "total_cents")
    assert_equal coupon.to_snapshot, summary["coupon"]
    assert_equal coupon.id, summary["coupon"]["id"]
    use = redemptions_of(coupon.id).first

    assert_equal [reservation.id, reservation.code, "confirmed", "Cliente Teste", 10_000, 1_000, @clock.now, "active", nil],
                 [use[:reservation_id], use[:reservation_code], use[:reservation_status], use[:customer_name], use[:subtotal].cents,
                  use[:discount].cents, use[:redeemed_at], use[:state], use[:released_at]]
    data = coupon_data("bemvindo10")

    assert_equal ["1 de 100", "active", "Dona Locadora Alfa", false, 99], [data[:coupon].usage_text, data[:status], data[:created_by_name],
                                                                           data[:deletable], data[:coupon].remaining]
    assert_equal data[:coupon], coupon_data(coupon.id.upcase)[:coupon], "referência por identificador ou por código"
    assert_equal ["coupon.created"], data[:history].map { |event| event["action"] }, "o histórico do cupom não recebe os usos"
    page = uc(:list_coupons).call(@actor, status: "active", search: "bemv", sort: "-created_at")

    assert_equal [1, "BEMVINDO10", "active"], [page.total, page.items.first[:coupon].code, page.items.first[:status]]
  end

  def test_coupon_registration_and_use_are_audited_with_actor_and_request
    coupon = create_coupon("AUDITADO", kind: "fixed", value: 2_500, min_subtotal_cents: 5_000)
    reservation = book(coupon_code: "AUDITADO")
    created = audit_events("coupon.created").first

    assert_equal ["user", @org[:user_id], "coupon", coupon.id, "req-cupons-0001"],
                 created.values_at("actor_type", "actor_id", "resource_type", "resource_id", "request_id")
    assert_equal({ "code" => "AUDITADO", "kind" => "fixed", "value" => 2_500, "valid_from" => nil, "valid_until" => nil, "max_redemptions" => nil,
                   "min_subtotal_cents" => 5_000 }, created["details"])
    used = audit_events("reservation.created").first

    assert_equal [reservation.id, "req-cupons-0001"], used.values_at("resource_id", "request_id")
    assert_equal [coupon.id, "AUDITADO", 0], used["details"].values_at("coupon_id", "coupon_code", "fees_cents")
    refute used["details"].key?("fee_overrides")
    plain = book(day: 12)

    refute audit_events("reservation.created").find { |event| event["resource_id"] == plain.id }["details"].key?("coupon_id")
    row = owner_query("SELECT coupon_id, reservation_id, subtotal_cents, discount_cents, redeemed_by FROM coupon_redemptions").first

    assert_equal [coupon.id, reservation.id, "10000", "2500", @org[:user_id]], row.values
    assert_equal 7_500, reservation.total.cents
  end

  def test_invalid_registrations_are_refused_with_field_errors
    errors = error_fields { create_coupon("x", kind: "brinde", value: 0, max_redemptions: 0, valid_until: @clock.now - 60) }

    assert_equal %w[codigo maximo_usos tipo valido_ate], errors.keys.sort
    assert_equal ["entre 0,01% e 100%"], error_fields { create_coupon("CEM", value: 10_001) }["valor"]
    create_coupon("REPETIDO")
    uc(:set_coupon_active).call(@actor, "REPETIDO", active: false)

    assert_equal("coupon_code_taken", conflict_code { create_coupon("repetido") })
    assert_raises(D::NotFound) { coupon_data("INEXISTENTE") }
    assert_raises(D::NotFound) { coupon_data(SecureRandom.uuid) }
    assert_raises(D::NotFound) { uc(:update_coupon).call(@actor, "", { description: "x" }) }
    assert_equal 1, owner_query("SELECT count(*) AS n FROM coupons").first["n"].to_i
  end

  def test_each_rejection_has_its_own_message_and_deactivation_is_reversible
    coupon = create_coupon("REGRAS", valid_from: @clock.now + 3_600, valid_until: @clock.now + 7_200, min_subtotal_cents: 20_000)

    assert_equal ["cupom inexistente"], coupon_error(coupon_code: "NAOEXISTE")
    assert_equal ["cupom ainda não está vigente"], coupon_error(coupon_code: "REGRAS")
    @clock.advance(3_600)

    assert_equal ["subtotal abaixo do mínimo do cupom (R$ 200,00)"], coupon_error(coupon_code: "REGRAS")
    uc(:update_coupon).call(@actor, coupon.id, { min_subtotal_cents: nil })
    deactivated = uc(:set_coupon_active).call(@actor, coupon.id, active: false)

    assert_equal [true, false, @clock.now], [deactivated.changed, deactivated.record.active, deactivated.record.deactivated_at]
    assert_equal ["cupom desativado"], coupon_error(coupon_code: "REGRAS")
    refute uc(:set_coupon_active).call(@actor, "regras", active: false).changed, "desativar de novo é operação nula"
    reactivated = uc(:set_coupon_active).call(@actor, coupon.id, active: true)

    assert_equal [true, nil, 4], [reactivated.record.active, reactivated.record.deactivated_at, reactivated.record.lock_version]
    assert_equal 9_000, book(coupon_code: "REGRAS").total.cents
    @clock.advance(3_600)

    assert_equal ["cupom expirado"], coupon_error(coupon_code: "REGRAS", day: 12)
    assert_equal %w[coupon.created coupon.deactivated coupon.reactivated coupon.updated],
                 coupon_data(coupon.id)[:history].map { |event| event["action"] }.sort
    assert_equal([{ "code" => "REGRAS" }], audit_events("coupon.deactivated").map { |event| event["details"] })
    assert_equal 1, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i, "reservas recusadas são desfeitas por inteiro"
  end

  # A vigência editada é gravada: a precificação das reservas seguintes e a consulta leem o banco.
  def test_edited_validity_is_stored_and_applies_to_the_next_reservations
    coupon = create_coupon("VIGENCIA", valid_until: @clock.now + 3_600)
    @clock.advance(3_600)

    assert_equal ["cupom expirado"], coupon_error(coupon_code: "VIGENCIA")
    uc(:update_coupon).call(@actor, coupon.id, { valid_until: @clock.now + 7_200 })

    assert_equal 9_000, book(coupon_code: "VIGENCIA").total.cents, "fim estendido"
    uc(:update_coupon).call(@actor, coupon.id, { valid_from: @clock.now + 60, valid_until: @clock.now + 120 })
    stored = coupon_data(coupon.id)[:coupon]

    assert_equal [@clock.now + 60, @clock.now + 120, @clock.now], [stored.valid_from, stored.valid_until, stored.updated_at]
    assert_equal ["cupom ainda não está vigente"], coupon_error(coupon_code: "VIGENCIA", day: 12)
    @clock.advance(120)

    assert_equal ["cupom expirado"], coupon_error(coupon_code: "VIGENCIA", day: 12), "fim encurtado"
    uc(:update_coupon).call(@actor, coupon.id, { valid_from: nil, valid_until: nil })

    assert_equal([nil, nil], coupon_data(coupon.id)[:coupon].then { |c| [c.valid_from, c.valid_until] })
    assert_equal 9_000, book(coupon_code: "VIGENCIA", day: 12).total.cents, "sem prazo"
  end

  def test_coupon_edit_validates_active_uses_and_uses_optimistic_control
    coupon = create_coupon("EDITAVEL", description: "Antiga", max_redemptions: 5)
    2.times { |i| book(coupon_code: "EDITAVEL", day: 10 + i) }

    assert_equal ["não pode ser menor que os usos ativos (2)"],
                 error_fields { uc(:update_coupon).call(@actor, coupon.id, { max_redemptions: 1 }) }["maximo_usos"]
    unchanged = uc(:update_coupon).call(@actor, coupon.id, { description: "Antiga", max_redemptions: 5 }, lock_version: 1)

    assert_equal [false, 1], [unchanged.changed, unchanged.record.lock_version]
    assert_empty audit_events("coupon.updated"), "alteração sem mudança não é auditada"
    @clock.advance(60)
    revised = uc(:update_coupon).call(@actor, "editavel", { description: nil, max_redemptions: 2, valid_until: @clock.now + 86_400 }, lock_version: 1)

    assert_equal [true, nil, 2, 2, @clock.now], [revised.changed, revised.record.description, revised.record.max_redemptions,
                                                 revised.record.lock_version, revised.record.updated_at]
    assert_equal({ "changes" => { "description" => ["Antiga", nil], "max_redemptions" => [5, 2],
                                  "valid_until" => [nil, (@clock.now + 86_400).iso8601] } }, audit_events("coupon.updated").first["details"])
    assert_equal("stale_coupon", conflict_code { uc(:update_coupon).call(@actor, coupon.id, { description: "Perdida" }, lock_version: 1) })
    assert_equal(["exhausted", "2 de 2"], coupon_data(coupon.id).then { |data| [data[:status], data[:coupon].usage_text] })
    assert_equal ["cupom esgotado"], coupon_error(coupon_code: "EDITAVEL", day: 14)
    assert_raises(ArgumentError) { uc(:update_coupon).call(@actor, coupon.id, { code: "OUTRO" }) }
    assert_equal(["EDITAVEL", "percent", 1000], coupon_data(coupon.id)[:coupon].then { |c| [c.code, c.kind, c.value] })
  end

  def test_only_coupons_never_used_can_be_deleted
    unused = create_coupon("SEMUSO")
    used = create_coupon("COMUSO")
    legacy = create_coupon("LEGADO")
    reservation = book(coupon_code: "COMUSO")
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Cliente desistiu")
    owner_query("UPDATE coupons SET redemptions = 1 WHERE id = $1", [legacy.id])

    assert_equal([true, false, false], [unused, used, legacy].map { |coupon| coupon_data(coupon.id)[:deletable] })
    assert uc(:delete_coupon).call(@actor, "semuso")
    assert_raises(D::NotFound) { coupon_data(unused.id) }
    assert_equal([{ "code" => "SEMUSO" }], audit_events("coupon.deleted").map { |event| event["details"] })
    error = assert_raises(D::Conflict) { uc(:delete_coupon).call(@actor, used.id) }

    assert_equal ["coupon_in_use", "o cupom COMUSO já foi usado e não pode ser excluído; desative-o"], [error.code, error.message]
    assert_equal "coupon_in_use", conflict_code { uc(:delete_coupon).call(@actor, legacy.id) }, "contador da versão 1.0.0"
    assert_equal(["1 (sem limite)", 1, 1], coupon_data(legacy.id)[:coupon].then { |c| [c.usage_text, c.legacy_redemptions, c.total_redemptions] })
    assert_equal(["0 (sem limite)", 1], coupon_data(used.id)[:coupon].then { |c| [c.usage_text, c.total_redemptions] })
    assert_raises(D::NotFound) { uc(:delete_coupon).call(@actor, "SEMUSO") }
  end

  def test_cancellation_releases_the_use_without_writing_to_the_coupon
    coupon = create_coupon("UNICO", max_redemptions: 1)
    before = coupon_row(coupon.id)
    first = book(coupon_code: "UNICO")

    assert_equal ["cupom esgotado"], coupon_error(coupon_code: "UNICO", day: 12)
    @clock.advance(120)
    uc(:cancel_reservation).call(@actor, first.id, reason: "Cliente desistiu")
    released = redemptions_of(coupon.id).first

    assert_equal ["released_cancelled", "cancelled", @clock.now], released.values_at(:state, :reservation_status, :released_at)
    assert_equal(["0 de 1", "active"], coupon_data(coupon.id).then { |data| [data[:coupon].usage_text, data[:status]] })
    second = book(coupon_code: "UNICO", day: 12)

    assert_equal(%w[active released_cancelled], redemptions_of(coupon.id).map { |use| use[:state] })
    assert_equal before, coupon_row(coupon.id), "cancelamento e novo uso não gravam no cupom"
    assert_equal 2, coupon_data(coupon.id)[:coupon].total_redemptions
    contract = uc(:issue_contract).call(@actor, second.id)
    uc(:cancel_contract).call(@actor, contract.id, reason: "Evento cancelado pelo cliente")

    assert_equal "cancelled", status_of(second)
    assert_equal ["0 de 1", %w[released_cancelled released_cancelled]],
                 [usage(coupon.id), redemptions_of(coupon.id).map { |use| use[:state] }], "cancelamento pelo contrato"
    assert_equal(["coupon.created"], coupon_data(coupon.id)[:history].map { |event| event["action"] })
  end

  # Três caminhos de expiração do bloqueio temporário: tentativa de confirmação vencida, expiração em
  # lote do alocador (outra reserva no mesmo produto) e varredura do worker.
  def test_every_expiration_path_releases_the_use
    coupon = create_coupon("EXPIRA")
    tables = bulk("MESA-CUP")
    lights = bulk("LUZ-CUP")
    attempted = book(product: lights, mode: "hold", hold_minutes: 10, coupon_code: "EXPIRA")
    batch = book(mode: "hold", hold_minutes: 10, coupon_code: "EXPIRA")
    swept = book(product: tables, mode: "hold", hold_minutes: 10, coupon_code: "EXPIRA")

    assert_equal "3 (sem limite)", usage(coupon.id)
    @clock.advance(600)

    assert_equal "0 (sem limite)", usage(coupon.id), "bloqueios vencidos deixam de contar antes de qualquer varredura"
    assert_raises(D::HoldExpired) { uc(:confirm_reservation).call(@actor, attempted.id) }
    book(day: 14)
    uc(:expire_holds).call(system_actor)

    assert_equal(%w[expired expired expired], [attempted, batch, swept].map { |reservation| status_of(reservation) })
    uses = redemptions_of(coupon.id)

    assert_equal [%w[released_expired] * 3, [@clock.now] * 3], [uses.map { |use| use[:state] }, uses.map { |use| use[:released_at] }]
    assert_equal %w[allocation confirmation_attempt sweeper],
                 audit_events("reservation.expired").map { |event| event["details"]["trigger"] }.sort
    assert_equal 1, coupon_row(coupon.id)["lock_version"].to_i
  end

  # O uso do bloqueio vencido aparece liberado na hora; para o limite, ainda conta durante a carência
  # (uma confirmação que leu o relógio antes do vencimento pode estar em andamento) e deixa de contar
  # depois dela, mesmo sem varredura.
  def test_expired_hold_not_yet_swept_stops_counting_against_the_limit_after_the_grace
    coupon = create_coupon("BLOQUEIO", max_redemptions: 1)
    hold = book(mode: "hold", hold_minutes: 10, coupon_code: "BLOQUEIO")
    other = bulk("MESA-BLQ")
    @clock.advance(599)

    assert_equal ["cupom esgotado"], coupon_error(product: other, coupon_code: "BLOQUEIO")
    @clock.advance(1)
    expired_at = @clock.now

    assert_equal(["0 de 1", "active"], coupon_data(coupon.id).then { |data| [data[:coupon].usage_text, data[:status]] })
    assert_equal ["cupom esgotado"], coupon_error(product: other, coupon_code: "BLOQUEIO"), "dentro da carência"
    @clock.advance(D::Pricing::Redemptions::LIMIT_GRACE - 1)

    assert_equal ["cupom esgotado"], coupon_error(product: other, coupon_code: "BLOQUEIO")
    @clock.advance(1)
    accepted = book(product: other, coupon_code: "BLOQUEIO")

    assert_equal %w[held confirmed], [status_of(hold), status_of(accepted)], "o bloqueio vencido continua sem varredura"
    uses = redemptions_of(coupon.id)

    assert_equal [%w[active released_expired], [nil, expired_at]], [uses.map { |use| use[:state] }, uses.map { |use| use[:released_at] }]
    assert_equal(["1 de 1", "exhausted"], coupon_data(coupon.id).then { |data| [data[:coupon].usage_text, data[:status]] })
    assert_raises(D::HoldExpired) { uc(:confirm_reservation).call(@actor, hold.id) }
    assert_equal "1 de 1", usage(coupon.id)
  end

  # Orçamentos não aplicam cupons: o bloqueio do envio e a reserva convertida usam o snapshot da
  # versão, sem uso registrado; um snapshot pré-calculado com cupom é recusado.
  def test_quotes_and_converted_reservations_never_redeem_coupons
    create_coupon("SOBALCAO")
    input = { customer_id: @customer.id, branch_id: @branch.id, period: window, lines: [line(@chairs, 1)], valid_until: @clock.now + 86_400,
              hold_policy: "hold_on_send", coupon_code: "SOBALCAO" }
    quote = uc(:create_quote).call(@actor, input)
    version = uc(:get_quote).call(@actor, quote.id)[:current]

    assert_equal [nil, nil, 10_000], version.pricing.values_at("coupon", "coupon_code", "total_cents")
    uc(:send_quote).call(@actor, quote.id)
    uc(:revise_quote).call(@actor, quote.id, input.merge(terms: "Entrega no local."))
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: 2, approver_name: "Maria Compradora")
    converted = uc(:convert_quote).call(@actor, quote.id).reservation

    assert_equal ["confirmed", 10_000], [converted.status, converted.total.cents]
    assert_equal(%w[cancelled confirmed], owner_query("SELECT status FROM reservations ORDER BY created_at, code").map { |row| row["status"] })
    assert_equal 0, owner_query("SELECT count(*) AS n FROM coupon_redemptions").first["n"].to_i
    assert_equal "0 (sem limite)", usage("SOBALCAO")
    snapshot = { items: version.items, summary: version.pricing.merge("coupon_code" => "SOBALCAO") }

    assert_equal ["o snapshot de preços não pode conter cupom"], error_fields { book(day: 10, pricing_snapshot: snapshot) }["precos"]
    with_coupon = { items: version.items, summary: version.pricing.merge("coupon" => { "code" => "SOBALCAO" }) }

    assert_equal ["o snapshot de preços não pode conter cupom"], error_fields { book(day: 10, pricing_snapshot: with_coupon) }["precos"]
  end
end
