# frozen_string_literal: true

require_relative "../unit_helper"

# Regras de domínio das condições comerciais: códigos, cupons e usos derivados da reserva. Condições
# negociadas e tarifas ficam em commercial_terms_agreements_fees_test.rb.
class CommercialTermsDomainTest < UnitTest
  P = Domain::Pricing
  M = Domain::Money

  def now = t("2026-03-02T12:00:00Z")

  def coupon_attrs(**overrides)
    { id: "c1", organization_id: "o1", code: "BEMVINDO10", kind: "percent", value: 1000, description: nil, valid_from: nil,
      valid_until: nil, max_redemptions: nil, min_subtotal_cents: nil, created_by: "u1", now: now }.merge(overrides)
  end

  def coupon(**overrides) = P::Coupons.build(**coupon_attrs(**overrides))

  def errors_of(&)
    error = assert_raises(Domain::ValidationError, &)
    error.errors
  end

  # Códigos --------------------------------------------------------------------------------------------

  def test_codes_are_normalized_and_validated
    assert_equal "BEM-VINDO_10", P::Codes.coupon!("  bem-vindo_10 ")
    assert_equal "AB1", P::Codes.coupon!("ab1")
    assert_equal "TAXA", P::Codes.normalize(" taxa ")
    assert_equal "EN", P::Codes.fee!("en")
    assert_equal "X" * 40, P::Codes.coupon!("x" * 40)
    ["AB", "X" * 41, "-ABC", "_ABC", "PROMOÇÃO", "COM ESPAÇO", ""].each do |code|
      assert_equal ["use de 3 a 40 caracteres: letras sem acento, números, hífen ou sublinhado"], errors_of { P::Codes.coupon!(code) }["codigo"],
                   code
    end
    assert_equal ["use de 2 a 30 caracteres: letras sem acento, números, hífen ou sublinhado"], errors_of { P::Codes.fee!("A") }["codigo"]
    assert_raises(Domain::ValidationError) { P::Codes.fee!("X" * 31) }
    assert_equal ["não use o formato de identificador"], errors_of { P::Codes.coupon!("00000000-0000-7000-8000-000000000001") }["codigo"]
    assert_equal ["não use o formato de identificador"], errors_of { P::Codes.fee!("00000000-0000-7000-8000-000000000001", "cod") }["cod"]
  end

  # Cupons ---------------------------------------------------------------------------------------------

  def test_coupon_build_accepts_both_kinds_and_normalizes_input
    percent = coupon(code: "bemvindo10", description: "  Boas-vindas\nPrimeira locação  ", max_redemptions: "100",
                     valid_until: now + 86_400)

    assert_equal ["BEMVINDO10", 1000, 100, 0, true, 1, 0], [percent.code, percent.value, percent.max_redemptions, percent.min_subtotal_cents,
                                                            percent.active, percent.lock_version, percent.redemptions]
    assert_equal "Boas-vindas\nPrimeira locação", percent.description, "quebra de linha interna preservada"
    fixed = coupon(code: "FIXO50", kind: "fixed", value: M.new(5_000), min_subtotal_cents: M.new(30_000), valid_from: now - 86_400)

    assert_equal [5_000, 30_000], [fixed.value, fixed.min_subtotal_cents]
    assert_equal "active", fixed.status(now), "início no passado significa já vigente"
    assert_equal 10_000, coupon(value: 10_000).value
    assert_equal 1, coupon(value: 1).value
  end

  def test_coupon_build_reports_every_invalid_field
    errors = errors_of do
      coupon(code: "x", kind: "brinde", description: "a" * 201, valid_from: now + 7200, valid_until: now + 3600, max_redemptions: 0,
             min_subtotal_cents: -1)
    end

    assert_equal %w[codigo descricao maximo_usos subtotal_minimo tipo valido_ate], errors.keys.sort
    assert_equal ["até 200 caracteres"], errors["descricao"], "texto longo é recusado, nunca cortado"
    assert_equal ["deve ser posterior ao início da vigência"], errors["valido_ate"]
    assert_equal ["use percent ou fixed"], errors["tipo"]
    assert_equal ["entre 1 e 1.000.000"], errors_of { coupon(max_redemptions: 1_000_001) }["maximo_usos"]
    assert_equal ["entre 1 e 1.000.000"], errors_of { coupon(max_redemptions: "muitos") }["maximo_usos"]
    assert_equal ["0 ou positivo"], errors_of { coupon(min_subtotal_cents: -1) }["subtotal_minimo"]
    assert_equal ["não pode estar no passado"], errors_of { coupon(valid_until: now) }["valido_ate"]
    assert_equal ["deve ser posterior ao início da vigência"], errors_of { coupon(valid_from: now + 10, valid_until: now + 10) }["valido_ate"]
  end

  def test_coupon_value_limits_by_kind
    assert_equal ["entre 0,01% e 100%"], errors_of { coupon(value: 0) }["valor"]
    assert_equal ["entre 0,01% e 100%"], errors_of { coupon(value: 10_001) }["valor"]
    assert_equal ["entre 0,01% e 100%"], errors_of { coupon(value: "12,5") }["valor"], "o domínio recebe pontos-base"
    assert_equal ["valor positivo"], errors_of { coupon(kind: "fixed", value: 0) }["valor"]
    assert_equal ["valor positivo"], errors_of { coupon(kind: "fixed", value: M::MAX_CENTS + 1) }["valor"]
    assert_equal ["valor positivo"], errors_of { coupon(kind: "fixed", value: nil) }["valor"]
    assert_equal ["entre 0,01% e 100%"], errors_of { coupon(value: 1.5) }["valor"], "Float nunca é aceito"
  end

  def test_coupon_revise_changes_only_given_keys
    original = coupon(description: "Antiga", max_redemptions: 10, min_subtotal_cents: 5_000, valid_from: now - 60, valid_until: now + 86_400)
    revised = P::Coupons.revise(original, { description: "Nova", max_redemptions: nil }, now: now + 60)

    assert_equal ["Nova", nil, 5_000, 2, now + 60], [revised.description, revised.max_redemptions, revised.min_subtotal_cents,
                                                     revised.lock_version, revised.updated_at]
    assert_equal [original.code, original.kind, original.value], [revised.code, revised.kind, revised.value]
    cleared = P::Coupons.revise(original, { description: nil, valid_from: nil, valid_until: nil, min_subtotal_cents: nil }, now: now)

    assert_equal [nil, nil, nil, 0], [cleared.description, cleared.valid_from, cleared.valid_until, cleared.min_subtotal_cents]
    assert_same original, P::Coupons.revise(original, { description: " Antiga ", max_redemptions: "10" }, now: now)
    assert_same original, P::Coupons.revise(original, {}, now: now)
    assert_raises(ArgumentError) { P::Coupons.revise(original, { code: "OUTRO" }, now: now) }
    assert_equal({ "description" => %w[Antiga Nova], "max_redemptions" => [10, nil] }, P::Coupons.changes(original, revised))
    assert_equal({ "valid_from" => [(now - 60).iso8601, nil], "valid_until" => [(now + 86_400).iso8601, nil], "description" => ["Antiga", nil],
                   "min_subtotal_cents" => [5_000, 0] }.sort.to_h, P::Coupons.changes(original, cleared).sort.to_h)
  end

  def test_coupon_revise_validates_the_resulting_state
    used = coupon(max_redemptions: 10).with(redemptions: 4)

    assert_equal ["não pode ser menor que os usos ativos (4)"], errors_of { P::Coupons.revise(used, { max_redemptions: 3 }, now: now) }["maximo_usos"]
    assert_equal 4, P::Coupons.revise(used, { max_redemptions: 4 }, now: now).max_redemptions
    expiring = coupon(valid_until: now + 60)

    assert_equal ["não pode estar no passado"], errors_of { P::Coupons.revise(expiring, { valid_until: now - 1 }, now: now) }["valido_ate"]
    later = now + 120

    assert_equal "Nova", P::Coupons.revise(expiring, { description: "Nova" }, now: later).description, "fim inalterado já vencido é aceito"
    # Cupom da 1.0.0 gravado antes da CHECK de vigência: fim anterior ao início.
    legacy = coupon.with(valid_from: now + 3600, valid_until: now + 60)

    assert_equal ["deve ser posterior ao início da vigência"],
                 errors_of { P::Coupons.revise(legacy, { description: "x" }, now: now) }["valido_ate"]
    oversized = coupon.with(max_redemptions: 5_000_000)

    assert_equal ["entre 1 e 1.000.000"], errors_of { P::Coupons.revise(oversized, { description: "x" }, now: now) }["maximo_usos"],
                 "máximo da 1.0.0 acima do limite: erro no campo, mesmo sem a chave"
    assert_equal 1_000, P::Coupons.revise(oversized, { max_redemptions: 1_000 }, now: now).max_redemptions
    refute P::Coupons.set_active(oversized, false, now: now).active, "a desativação não depende da validação dos campos"
    assert_equal ["até 200 caracteres"], errors_of { P::Coupons.revise(used, { description: "a" * 201 }, now: now) }["descricao"]
  end

  def test_coupon_activation_is_idempotent
    active = coupon
    inactive = P::Coupons.set_active(active, false, now: now)

    assert_equal [false, now, 2], [inactive.active, inactive.deactivated_at, inactive.lock_version]
    assert_same inactive, P::Coupons.set_active(inactive, false, now: now + 1)
    reactivated = P::Coupons.set_active(inactive, true, now: now + 2)

    assert_equal [true, nil, 3], [reactivated.active, reactivated.deactivated_at, reactivated.lock_version]
    assert_equal({ "active" => [true, false] }, P::Coupons.changes(active, inactive))
  end

  def test_coupon_status_precedence_and_rejections
    base = coupon(max_redemptions: 1, min_subtotal_cents: 30_000, valid_from: now - 60, valid_until: now + 60).with(redemptions: 1)
    subtotal = M.new(50_000)
    table = [
      [base.with(active: false, valid_until: now), "inactive", "cupom desativado"],
      [base.with(valid_until: now), "expired", "cupom expirado"],
      [base.with(valid_from: now + 1), "scheduled", "cupom ainda não está vigente"],
      [base, "exhausted", "cupom esgotado"],
      [base.with(redemptions: 0), "active", nil]
    ]
    table.each do |candidate, status, rejection|
      assert_equal status, candidate.status(now)
      assert_equal [rejection], [candidate.rejection(subtotal, now)]
    end
    assert_equal "subtotal abaixo do mínimo do cupom (R$ 300,00)", base.with(redemptions: 0).rejection(M.new(29_999), now)
    assert base.with(redemptions: 0).applicable?(M.new(30_000), now)
    assert_equal "active", base.with(valid_from: now, redemptions: 0).status(now), "início inclusivo"
  end

  def test_coupon_usage_text_remaining_and_snapshot
    limited = coupon(max_redemptions: 100).with(redemptions: 3)

    assert_equal "3 de 100", limited.usage_text
    assert_equal 97, limited.remaining
    assert_equal "1.234 de 1.000.000", limited.with(redemptions: 1234, max_redemptions: 1_000_000).usage_text
    assert_equal "3 (sem limite)", limited.with(max_redemptions: nil).usage_text
    assert_nil limited.with(max_redemptions: nil).remaining
    assert_equal 0, limited.with(redemptions: 120).remaining
    snapshot = coupon(valid_until: Time.new(2027, 11, 20, 0, 0, 0, "-03:00"), description: "Boas-vindas").to_snapshot

    assert_equal({ "id" => "c1", "code" => "BEMVINDO10", "kind" => "percent", "value" => 1000, "description" => "Boas-vindas",
                   "valid_from" => nil, "valid_until" => "2027-11-20T03:00:00Z" }, snapshot)
  end

  def test_totals_use_the_specific_coupon_rejection
    exhausted = coupon(max_redemptions: 1).with(redemptions: 1)
    error = assert_raises(Domain::ValidationError) { P::Totals.compose(lines: [{ "total_cents" => 100 }], coupon: exhausted, now: now) }

    assert_equal({ "cupom" => ["cupom esgotado"] }, error.errors)
  end

  def test_property_coupon_applicability_discount_and_totals
    property("cupom aplicável e totais inteiros") do |random|
      at = now + random.rand(-10_000..10_000)
      max = random.rand(0..3).zero? ? nil : random.rand(1..5)
      candidate = P::Coupon.new(
        code: "PROP", kind: random.rand(2).zero? ? "percent" : "fixed", value: random.rand(1..10_000), active: random.rand(5).positive?,
        valid_from: random.rand(2).zero? ? nil : now + random.rand(-5_000..5_000),
        valid_until: random.rand(2).zero? ? nil : now + random.rand(-5_000..15_000), max_redemptions: max,
        redemptions: random.rand(0..6), min_subtotal_cents: random.rand(0..20_000)
      )
      subtotal = M.new(random.rand(0..50_000))

      assert_equal candidate.status(at) == "active" && subtotal.cents >= candidate.min_subtotal_cents, candidate.applicable?(subtotal, at)
      discount = candidate.discount(subtotal)

      assert discount.cents.between?(0, subtotal.cents)
      next unless candidate.applicable?(subtotal, at)

      fees = Array.new(random.rand(0..3)) { { "amount_cents" => random.rand(1..9_000) } }
      manual = random.rand(0..2_000)
      totals = P::Totals.compose(lines: [{ "total_cents" => subtotal.cents }], fees: fees, coupon: candidate, manual_discount_bps: manual,
                                 discount_limit_bps: 2_000, now: at)
      expected = totals["subtotal_cents"] - totals["coupon_discount_cents"] - totals["manual_discount_cents"] + totals["fees_cents"]

      assert_equal expected, totals["total_cents"]
      assert(totals.values_at("subtotal_cents", "coupon_discount_cents", "manual_discount_cents", "fees_cents", "total_cents").all?(Integer))
    end
  end

  # Usos -----------------------------------------------------------------------------------------------

  def test_redemption_state_for_every_reservation_status
    expected = {
      "requested" => "active", "confirmed" => "active", "in_progress" => "active", "completed" => "active",
      "cancelled" => "released_cancelled", "expired" => "released_expired"
    }

    expected.each { |status, state| assert_equal state, P::Redemptions.state(status, nil, now), status }
    assert_equal "active", P::Redemptions.state("held", now + 1, now)
    assert_equal "released_expired", P::Redemptions.state("held", now, now), "bloqueio vencido no próprio instante"
    assert_equal "released_expired", P::Redemptions.state("held", now - 1, now), "vencido e ainda não varrido"
    assert P::Redemptions.active?("held", now + 1, now)
    refute P::Redemptions.active?("cancelled", nil, now)
    assert_equal Domain::Reservations::STATUSES.keys.sort, (expected.keys + ["held"]).sort
  end

  # Para o limite, o bloqueio vencido conta durante a carência; as demais situações seguem active?.
  def test_expired_hold_counts_toward_the_limit_during_the_grace
    grace = P::Redemptions::LIMIT_GRACE

    assert_equal now - grace, P::Redemptions.limit_reference(now)
    assert P::Redemptions.counts_toward_limit?("held", now, now), "vencido no próprio instante"
    assert P::Redemptions.counts_toward_limit?("held", now - grace + 1, now)
    refute P::Redemptions.counts_toward_limit?("held", now - grace, now), "carência esgotada"
    counted = Domain::Reservations::STATUSES.keys.select { |status| P::Redemptions.counts_toward_limit?(status, now + 60, now) }

    assert_equal %w[completed confirmed held in_progress requested], counted.sort
  end

  def test_property_expired_hold_never_becomes_an_active_use_again
    reservation = Domain::Reservations::Reservation.new(
      id: "r1", organization_id: "o1", branch_id: "b1", customer_id: "k1", code: "R-1", status: "held", source: "staff",
      period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), hold_expires_at: now, quote_id: nil, notes: nil,
      total: M.zero, deposit: M.zero, version: 2
    )
    operations = [
      ->(r, at) { r.confirm(at) }, ->(r, at) { r.reschedule(period("2026-03-12T08:00:00Z", "2026-03-13T08:00:00Z"), at) },
      ->(r, at) { r.extend_to(t("2026-03-11T10:00:00Z"), at) }, ->(r, at) { r.hold(at + 600) }, ->(r, at) { r.expire(at) },
      ->(r, _at) { r.cancel }, ->(r, _at) { r.start }, ->(r, _at) { r.complete }
    ]
    property("bloqueio vencido não volta a contar") do |random|
      current = reservation
      at = now + random.rand(0..86_400)
      random.rand(1..4).times do
        current = operations.sample(random: random).call(current, at)
      rescue Domain::Error
        nil
      end

      refute P::Redemptions.active?(current.status, current.hold_expires_at, at), "situação final #{current.status}"
    end
  end

  # Textos e erros compartilhados ------------------------------------------------------------------------

  def test_percent_parse
    assert_equal([1000, 1250, 1234, 5, 10_000], %w[10 12,5 12.34 0,05 100].map { |v| Domain::Percent.parse(v, "desconto") })
    assert_nil Domain::Percent.parse("  ", "desconto")
    assert_nil Domain::Percent.parse(nil, "desconto")
    ["0,001", "1e2", "Infinity", "-5", "+5", "12,", "1.000,5", "abc"].each do |value|
      error = assert_raises(Domain::ValidationError, value) { Domain::Percent.parse(value, "desconto") }

      assert_equal({ "desconto" => ["percentual inválido (até duas casas decimais)"] }, error.errors)
    end
  end

  def test_optional_text_without_truncation_and_feminine_not_found
    text = Domain::Organizations::Text

    assert_equal "Linha 1\n\nLinha 2", text.optional!("  Linha 1\n\nLinha 2  ", "descricao", max: 20)
    assert_nil text.optional!("   ", "descricao", max: 20)
    assert_equal "a\nb\nc", text.optional!("a\r\nb\rc", "descricao", max: 5), "quebras CRLF e CR viram LF e contam como uma"
    assert_equal({ "descricao" => ["até 5 caracteres"] }, assert_raises(Domain::ValidationError) { text.optional!("123456", "descricao", max: 5) }.errors)
    assert_equal "tarifa não encontrada", Domain::NotFound.new("tarifa", feminine: true).message
    assert_equal "cupom não encontrado", Domain::NotFound.new("cupom").message
    assert_equal "recurso não encontrado", Domain::NotFound.new.message
  end
end
