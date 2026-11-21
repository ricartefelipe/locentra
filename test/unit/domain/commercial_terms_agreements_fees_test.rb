# frozen_string_literal: true

require_relative "../unit_helper"

# Regras de domínio das condições negociadas (vigência, encerramento imediato ou agendado, melhor
# condição) e das tarifas adicionais (catálogo, pedidos, autorização de ajustes e continuidade).
class CommercialTermsAgreementsFeesTest < UnitTest
  P = Domain::Pricing
  M = Domain::Money
  FEE_ID = "00000000-0000-7000-8000-0000000000f1"
  OTHER_FEE_ID = "00000000-0000-7000-8000-0000000000f2"

  def now = t("2026-03-02T12:00:00Z")

  def errors_of(&)
    error = assert_raises(Domain::ValidationError, &)
    error.errors
  end

  def agreement(**overrides)
    P::Agreement.build(id: "a1", organization_id: "o1", customer_id: "k1", product_id: nil, discount_bps: 800, valid_from: nil,
                       valid_until: nil, notes: nil, created_by: "u1", now: now, **overrides)
  end

  def fee(id: FEE_ID, code: "ENTREGA", amount: 15_000, active: true)
    P::Fee.build(id: id, organization_id: "o1", code: code, name: "Entrega", description: nil, default_amount: M.new(amount),
                 created_by: "u1", now: now).then { |f| active ? f : f.set_active(false, now: now) }
  end

  def resolve(requests, catalog: { FEE_ID => fee }, previous: [], may_override: false, limit: 0)
    P::Fees.resolve(requests, catalog: catalog, previous: previous, may_override: may_override, reduction_limit_bps: limit)
  end

  def catalog_request(amount = nil, id: FEE_ID) = P::FeeRequest.catalog(fee_id: id, amount: amount && M.new(amount))

  # Condições negociadas ---------------------------------------------------------------------------------

  def test_agreement_build_adjusts_recent_past_and_validates
    assert_equal now, agreement.valid_from, "vazio vale a partir de agora"
    assert_equal now, agreement(valid_from: now - 86_400).valid_from, "até 24 h no passado é ajustado"
    assert_equal now + 3600, agreement(valid_from: now + 3600).valid_from
    assert_equal ["o início não pode estar mais de 24 horas no passado; deixe em branco para valer a partir de agora"],
                 errors_of { agreement(valid_from: now - 86_401) }["valido_de"]
    assert_equal ["entre 0,01% e 90%"], errors_of { agreement(discount_bps: 9001) }["desconto"]
    assert_equal ["entre 0,01% e 90%"], errors_of { agreement(discount_bps: 0) }["desconto"]
    assert_equal 9000, agreement(discount_bps: "9000").discount_bps
    assert_equal ["deve ser posterior ao início da vigência"], errors_of { agreement(valid_from: now + 60, valid_until: now + 60) }["valido_ate"]
    assert_equal ["deve ser posterior ao momento atual"], errors_of { agreement(valid_until: now) }["valido_ate"]
    assert_equal ["até 500 caracteres"], errors_of { agreement(notes: "a" * 501) }["observacoes"]
    assert_equal "Linha 1\nLinha 2", agreement(notes: " Linha 1\nLinha 2 ").notes
    assert_equal %w[general product], [agreement.scope, agreement(product_id: "p1").scope]
  end

  def test_agreement_status_with_scheduled_end
    scheduled = agreement(valid_from: now + 3600, valid_until: now + 7200)

    assert_equal %w[scheduled active expired], [scheduled.status(now), scheduled.status(now + 3600), scheduled.status(now + 7200)]
    ending = agreement.end_at(now: now, at: now + 600, by: "u2", reason: "Troca de contrato")

    assert_equal ["active", true, "ended", false], [ending.status(now), ending.end_scheduled?(now), ending.status(now + 600),
                                                    ending.end_scheduled?(now + 600)]
    assert ending.effective?(now)
    assert_equal now + 600, ending.effective_end
    assert_equal({ "id" => "a1", "scope" => "general", "product_id" => nil, "discount_bps" => 800, "valid_from" => now.iso8601,
                   "valid_until" => nil, "ended_at" => (now + 600).iso8601 }, ending.to_snapshot)
  end

  def test_agreement_end_rules
    active = agreement(valid_until: now + 86_400)
    immediate = active.end_at(now: now, at: nil, by: "u2", reason: "  Cliente encerrou o contrato ")

    assert_equal [now, "u2", "Cliente encerrou o contrato", "ended"], [immediate.ended_at, immediate.ended_by, immediate.end_reason,
                                                                       immediate.status(now)]
    assert_equal now, active.end_at(now: now, at: now - 3600, by: "u2", reason: "Ajuste").ended_at, "passado recente vira agora"
    assert_equal ["o encerramento não pode estar mais de 24 horas no passado; deixe em branco para encerrar agora"],
                 errors_of { active.end_at(now: now, at: now - 86_401, by: "u2", reason: "Ajuste") }["encerrar_em"]
    assert_equal ["a condição já termina em 2026-03-03T12:00:00Z"],
                 errors_of { active.end_at(now: now, at: now + 86_400, by: "u2", reason: "Ajuste") }["encerrar_em"]
    zone = Domain::TimeZone.new("America/Sao_Paulo")

    assert_equal ["a condição já termina em 03/03/2026 09:00"],
                 errors_of { active.end_at(now: now, at: now + 90_000, by: "u2", reason: "Ajuste", zone: zone) }["encerrar_em"]
    assert_equal %w[encerrar_em motivo], errors_of { active.end_at(now: now, at: now + 90_000, by: "u2", reason: "x") }.keys.sort
    assert_raises(Domain::InvalidTransition) { immediate.end_at(now: now, at: nil, by: "u2", reason: "Outra vez") }
    scheduled_end = active.end_at(now: now, at: now + 600, by: "u2", reason: "Agendado")

    assert_raises(Domain::InvalidTransition) { scheduled_end.end_at(now: now, at: nil, by: "u2", reason: "Antecipar") }
    expired = agreement(valid_until: now + 60)
    error = assert_raises(Domain::InvalidTransition) { expired.end_at(now: now + 60, at: nil, by: "u2", reason: "Tarde demais") }

    assert_equal "Transição inválida em condição negociada: Expirada → Encerrada", error.message
  end

  def test_ending_a_scheduled_agreement_before_its_start_revokes_it
    scheduled = agreement(valid_from: now + 86_400)
    revoked = scheduled.end_at(now: now, at: nil, by: "u2", reason: "Cancelada antes do início")

    assert_equal "ended", revoked.status(now)
    assert_equal "ended", revoked.status(now + 90_000), "a janela efetiva fica vazia"
    refute revoked.effective?(now + 90_000)
  end

  def test_property_best_agreement
    property("melhor condição") do |random|
      candidates = Array.new(random.rand(1..5)) do |i|
        P::Agreement.new(id: "a#{random.rand(100)}-#{i}", organization_id: "o1", customer_id: "k1",
                         product_id: random.rand(2).zero? ? nil : "p1", discount_bps: random.rand(1..4) * 100, valid_from: now,
                         valid_until: nil, notes: nil, created_by: nil, created_at: now, ended_at: nil, ended_by: nil, end_reason: nil)
      end
      best = P::Agreement.best(candidates + [nil])
      top = candidates.map(&:discount_bps).max

      assert_equal top, best.discount_bps
      assert_equal "p1", best.product_id if candidates.any? { |a| a.discount_bps == top && a.product_id }
      tied = candidates.select { |a| a.discount_bps == top && a.product_id == best.product_id }

      assert_equal tied.map(&:id).min, best.id
    end
  end

  # Tarifas ------------------------------------------------------------------------------------------------

  def test_fee_build_revise_and_activation
    built = fee

    assert_equal ["ENTREGA", "Entrega", 15_000, "active", 1], [built.code, built.name, built.default_amount.cents, built.status, built.lock_version]
    errors = errors_of do
      P::Fee.build(id: FEE_ID, organization_id: "o1", code: "x", name: "E", description: "a" * 501, default_amount: M.zero, created_by: nil,
                   now: now)
    end

    assert_equal %w[codigo descricao nome valor_padrao], errors.keys.sort
    assert_equal ["valor positivo"], errors["valor_padrao"]
    revised = built.revise({ default_amount: M.new(18_000), description: "Até 30 km" }, now: now + 60)

    assert_equal [18_000, "Até 30 km", 2, now + 60], [revised.default_amount.cents, revised.description, revised.lock_version, revised.updated_at]
    assert_equal({ "default_amount_cents" => [15_000, 18_000], "description" => [nil, "Até 30 km"] }, built.changes(revised))
    assert_same built, built.revise({ name: " Entrega " }, now: now)
    assert_raises(ArgumentError) { built.revise({ code: "OUTRA" }, now: now) }
    assert_raises(Domain::ValidationError) { built.revise({ default_amount: nil }, now: now) }
    inactive = built.set_active(false, now: now)

    assert_equal ["inactive", now], [inactive.status, inactive.deactivated_at]
    assert_same inactive, inactive.set_active(false, now: now)
    assert_nil inactive.set_active(true, now: now).deactivated_at
  end

  def test_fee_requests_validate_input
    assert_equal FEE_ID, P::FeeRequest.catalog(fee_id: FEE_ID.upcase).fee_id
    assert_nil P::FeeRequest.catalog(fee_id: FEE_ID).amount
    assert_equal ["identificador inválido"], errors_of { P::FeeRequest.catalog(fee_id: "ENTREGA") }["tarifas"]
    assert_equal ["o valor da tarifa deve ser positivo"], errors_of { P::FeeRequest.catalog(fee_id: FEE_ID, amount: M.zero) }["tarifas"]
    custom = P::FeeRequest.custom(description: "  Taxa de estacionamento ", amount: M.new(3_000))

    assert_equal ["Taxa de estacionamento", 3_000, true], [custom.description, custom.amount.cents, custom.custom?]
    assert_raises(Domain::ValidationError) { P::FeeRequest.custom(description: "x", amount: M.new(3_000)) }
    assert_raises(Domain::ValidationError) { P::FeeRequest.custom(description: "Taxa", amount: M.new(-1)) }
  end

  def test_fees_at_default_need_no_override
    resolution = resolve([catalog_request, catalog_request(15_000, id: OTHER_FEE_ID)],
                         catalog: { FEE_ID => fee, OTHER_FEE_ID => fee(id: OTHER_FEE_ID, code: "MONTAGEM") })

    assert_empty resolution.overrides
    assert_equal({ "fee_id" => FEE_ID, "code" => "ENTREGA", "description" => "Entrega", "amount_cents" => 15_000,
                   "default_amount_cents" => 15_000, "source" => "catalog" }, resolution.entries.first)
    assert_equal([15_000, 15_000], resolution.entries.map { |e| e["amount_cents"] })
  end

  def test_fee_adjustments_require_permission_and_respect_the_reduction_limit
    error = assert_raises(Domain::AccessDenied) { resolve([catalog_request(20_000)]) }

    assert_equal "valor diferente do padrão ou tarifa avulsa exige a permissão de ajustar tarifas (gerente, administrador ou proprietário): " \
                 "Entrega R$ 200,00 (padrão R$ 150,00)", error.message
    above = resolve([catalog_request(20_000)], may_override: true)

    assert_equal [{ "fee_id" => FEE_ID, "code" => "ENTREGA", "description" => "Entrega", "amount_cents" => 20_000,
                    "default_amount_cents" => 15_000, "source" => "catalog" }], above.overrides
    assert_equal 12_000, resolve([catalog_request(12_000)], may_override: true, limit: 2_000).entries.first["amount_cents"], "20% exato"
    error = assert_raises(Domain::AccessDenied) { resolve([catalog_request(11_999)], may_override: true, limit: 2_000) }

    assert_equal "redução da tarifa ENTREGA acima do limite autorizado para o papel (20%)", error.message
    assert_raises(Domain::AccessDenied, "credenciais têm limite 0") { resolve([catalog_request(14_999)], may_override: true, limit: 0) }
    assert_equal 20_000, resolve([catalog_request(20_000)], may_override: true, limit: 0).entries.first["amount_cents"], "acima do padrão não é redução"
  end

  def test_custom_fees_require_permission
    request = P::FeeRequest.custom(description: "Taxa de estacionamento", amount: M.new(3_000))
    error = assert_raises(Domain::AccessDenied) { resolve([request]) }

    assert_includes error.message, "Taxa de estacionamento R$ 30,00 (avulsa)"
    resolution = resolve([request], may_override: true)

    assert_equal [{ "fee_id" => nil, "code" => nil, "description" => "Taxa de estacionamento", "amount_cents" => 3_000,
                    "default_amount_cents" => nil, "source" => "custom" }], resolution.overrides
  end

  def test_fee_resolution_errors
    assert_equal ["a tarifa ENTREGA foi informada mais de uma vez"], errors_of { resolve([catalog_request, catalog_request(16_000)]) }["tarifas"]
    assert_equal ["a tarifa ENTREGA está inativa"], errors_of { resolve([catalog_request], catalog: { FEE_ID => fee(active: false) }) }["tarifas"]
    missing = assert_raises(Domain::NotFound) { resolve([catalog_request(id: OTHER_FEE_ID)]) }

    assert_equal "tarifa não encontrada", missing.message
    many = Array.new(11) { |i| P::FeeRequest.custom(description: "Taxa #{i}", amount: M.new(100)) }

    assert_equal ["no máximo 10 tarifas"], errors_of { resolve(many, may_override: true) }["tarifas"]
  end

  def test_entries_kept_from_the_previous_version_are_already_authorized
    previous = [
      { "fee_id" => FEE_ID, "code" => "ENTREGA", "description" => "Entrega", "amount_cents" => 20_000, "default_amount_cents" => 15_000,
        "source" => "catalog" },
      { "fee_id" => nil, "code" => nil, "description" => "Taxa de estacionamento", "amount_cents" => 3_000, "default_amount_cents" => nil,
        "source" => "custom" }
    ]
    kept = [catalog_request(20_000), P::FeeRequest.custom(description: "Taxa de estacionamento", amount: M.new(3_000))]
    resolution = resolve(kept, previous: previous, catalog: { FEE_ID => fee(active: false) })

    assert_empty resolution.overrides, "mantidas sem fees.override, mesmo com a tarifa inativa"
    assert_equal([20_000, 3_000], resolution.entries.map { |e| e["amount_cents"] })
    assert_raises(Domain::AccessDenied) { resolve([catalog_request(21_000)], previous: previous) }
    assert_raises(Domain::AccessDenied) { resolve([P::FeeRequest.custom(description: "Taxa de estacionamento", amount: M.new(3_500))], previous: previous) }
    default_kept = [{ "fee_id" => FEE_ID, "amount_cents" => 15_000, "default_amount_cents" => 15_000, "source" => "catalog" }]

    assert_equal 18_000, resolve([catalog_request], catalog: { FEE_ID => fee(amount: 18_000) }, previous: default_kept).entries.first["amount_cents"],
                 "sem valor, vale o padrão vigente"
  end

  # Cada entrada da versão anterior autoriza no máximo um pedido idêntico: a cópia excedente é um
  # ajuste novo (exige fees.override e aparece nos ajustes).
  def test_each_previous_entry_authorizes_a_single_identical_request
    parking = { "fee_id" => nil, "code" => nil, "description" => "Taxa de estacionamento", "amount_cents" => 3_000,
                "default_amount_cents" => nil, "source" => "custom" }
    copy = -> { P::FeeRequest.custom(description: "Taxa de estacionamento", amount: M.new(3_000)) }

    assert_raises(Domain::AccessDenied) { resolve([copy.call, copy.call], previous: [parking]) }
    assert_raises(Domain::AccessDenied) { resolve(Array.new(10) { copy.call }, previous: [parking]) }
    assert_empty resolve([copy.call, copy.call], previous: [parking, parking]).overrides, "duas entradas anteriores autorizam duas cópias"
    authorized = resolve([copy.call, copy.call], previous: [parking], may_override: true)

    assert_equal 1, authorized.overrides.size, "a cópia excedente entra nos ajustes"
    assert_equal 2, authorized.entries.size
  end

  # A avulsa só é mantida a partir de outra avulsa: o texto e o valor de uma tarifa do catálogo da
  # versão anterior não autorizam uma avulsa idêntica.
  def test_catalog_entry_of_the_previous_version_does_not_authorize_a_custom_fee
    delivery = { "fee_id" => FEE_ID, "code" => "ENTREGA", "description" => "Entrega", "amount_cents" => 15_000,
                 "default_amount_cents" => 15_000, "source" => "catalog" }

    assert_raises(Domain::AccessDenied) { resolve([P::FeeRequest.custom(description: "Entrega", amount: M.new(15_000))], previous: [delivery]) }
  end
end
