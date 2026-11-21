# frozen_string_literal: true

require_relative "../unit_helper"

# Precificação com condições comerciais e casos de uso de cadastro, com portas em memória (sem banco):
# o que o Pricer repassa aos repositórios, o que entra no resumo gravado e as operações nulas.
class CommercialTermsApplicationTest < UnitTest
  A = Locentra::Application
  CT = A::CommercialTerms
  P = Domain::Pricing
  M = Domain::Money
  FEE_ID = "00000000-0000-7000-8000-0000000000f1"
  Product = Data.define(:id, :sku, :name, :tracking, :pricing, :deposit)

  # Transação em memória: contexto de organização e ponto de restauração que apenas executa o bloco.
  class Tx
    def tenant_id! = "o1"
    def savepoint = yield
  end

  # Unidade de trabalho em memória: confere a permissão do ator e executa o bloco.
  class Uow
    def run(actor, permission = nil)
      A::Authorizer.authorize!(actor, permission) if permission
      yield Tx.new, actor
    end
  end

  class Audit
    attr_reader :records

    def initialize = @records = []
    def record(_tx, _actor, action, type, id, details = {}) = @records << [action, type, id, details]
  end

  # Porta de precificação: registra as chamadas e devolve o que o teste configurou.
  class Pricing
    attr_reader :calls, :redemptions
    attr_accessor :coupon, :agreements, :fees, :redemption_error

    def initialize
      @calls = []
      @redemptions = []
      @agreements = {}
      @fees = {}
    end

    def find_coupon(_tx, code, now:, lock: false)
      @calls << [:find_coupon, code, lock, now]
      @coupon
    end

    def applicable_agreement(_tx, customer_id, product_id, now)
      @calls << [:applicable_agreement, customer_id, product_id, now]
      @agreements[product_id] || @agreements[:general]
    end

    def fees_by_ids(_tx, ids)
      @calls << [:fees_by_ids, ids.sort]
      @fees.slice(*ids)
    end

    def insert_redemption(_tx, row)
      raise @redemption_error if @redemption_error

      @redemptions << row
    end
  end

  # Cadastro de cupons e tarifas em memória, com o controle otimista do repositório real.
  class Records
    attr_reader :updates
    attr_accessor :stored, :concurrent_change

    def initialize(stored = nil)
      @stored = stored
      @updates = []
    end

    def lock(_tx, id, **) = @stored && @stored.id == id ? @stored : nil
    def lock_by_code(_tx, code, **) = @stored && @stored.code == code ? @stored : nil
    def find(tx, id, **) = lock(tx, id)
    def find_by_code(tx, code, **) = lock_by_code(tx, code)

    def insert(_tx, record)
      return 0 if @stored && @stored.code == record.code

      @stored = record
      1
    end

    def update(_tx, record, expected_lock_version)
      return 0 if @concurrent_change || @stored.lock_version != expected_lock_version

      @updates << record
      @stored = record
      1
    end
  end

  def now = t("2026-03-02T12:00:00Z")
  def clock = TestClock.new(now)
  def zone = Domain::TimeZone.new("America/Sao_Paulo")
  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")
  def owner = A::Actor.user(user_id: "u1", organization_id: "o1", role: "owner")
  def attendant = A::Actor.user(user_id: "u2", organization_id: "o1", role: "attendant")

  def product(id, daily: 10_000)
    Product.new(id: id, sku: "SKU-#{id}", name: "Produto #{id}", tracking: "bulk",
                pricing: { "daily_cents" => daily }, deposit: M.new(5_000))
  end

  def products(*ids) = ids.to_h { |id| [id, { product: product(id) }] }
  def line(id, quantity = 1) = Domain::Reservations::Line.new(product_id: id, quantity: quantity)

  def agreement(id, bps, product_id: nil)
    P::Agreement.new(id: id, organization_id: "o1", customer_id: "k1", product_id: product_id, discount_bps: bps, valid_from: now - 60,
                     valid_until: nil, notes: "Observação interna", created_by: "u1", created_at: now - 60, ended_at: nil, ended_by: nil,
                     end_reason: nil)
  end

  def coupon(**overrides)
    P::Coupons.build(id: "00000000-0000-7000-8000-0000000000c1", organization_id: "o1", code: "BEMVINDO10", kind: "percent", value: 1000,
                     description: nil, valid_from: nil, valid_until: nil, max_redemptions: nil, min_subtotal_cents: nil, created_by: "u1",
                     now: now, **overrides)
  end

  def fee(amount: 15_000)
    P::Fee.build(id: FEE_ID, organization_id: "o1", code: "ENTREGA", name: "Entrega", description: nil, default_amount: M.new(amount),
                 created_by: "u1", now: now)
  end

  def pricer(pricing) = A::Reservations::Pricer.new(pricing: pricing, ids: SequentialIds.new)

  def price(pricing, ids: %w[p1], **)
    pricer(pricing).price(Tx.new, products: products(*ids), lines: ids.map { |id| line(id) }, period: rental, zone: zone, customer_id: "k1",
                                  now: now, **)
  end

  # Pricer -----------------------------------------------------------------------------------------------

  def test_pricer_keeps_fee_overrides_out_of_the_stored_summary
    pricing = Pricing.new
    pricing.fees = { FEE_ID => fee }
    requests = [P::FeeRequest.catalog(fee_id: FEE_ID, amount: M.new(20_000)),
                P::FeeRequest.custom(description: "Taxa de estacionamento", amount: M.new(3_000))]
    priced = price(pricing, fees: requests, fee_override: true)

    assert_equal([20_000, 3_000], priced.summary["fees"].map { |entry| entry["amount_cents"] })
    assert_equal(%w[catalog custom], priced.summary["fees"].map { |entry| entry["source"] })
    assert_equal 23_000, priced.summary["fees_cents"]
    assert_equal 20_000 + 23_000, priced.summary["total_cents"]
    assert_equal 2, priced.overrides.size
    assert_equal %w[agreements coupon coupon_code coupon_discount_cents deposit_cents fees fees_cents manual_discount_bps manual_discount_cents
                    period priced_at subtotal_cents timezone total_cents], priced.summary.keys.sort
    refute_includes JSON.generate(priced.summary), "override", "ajustes ficam só na auditoria"
    assert_includes pricing.calls, [:fees_by_ids, [FEE_ID]]
  end

  def test_pricer_requires_the_override_permission_for_adjusted_fees
    pricing = Pricing.new
    pricing.fees = { FEE_ID => fee }
    adjusted = [P::FeeRequest.catalog(fee_id: FEE_ID, amount: M.new(20_000))]

    error = assert_raises(Domain::AccessDenied) { price(pricing, fees: adjusted) }
    assert_includes error.message, "exige a permissão de ajustar tarifas"
    assert_empty price(pricing, fees: [P::FeeRequest.catalog(fee_id: FEE_ID)]).overrides
    assert_raises(Domain::AccessDenied) do
      price(pricing, fees: [P::FeeRequest.catalog(fee_id: FEE_ID, amount: M.new(14_000))], fee_override: true, discount_limit_bps: 500)
    end
    kept = [{ "fee_id" => FEE_ID, "amount_cents" => 20_000, "default_amount_cents" => 15_000, "source" => "catalog" }]

    assert_empty price(pricing, fees: adjusted, previous_fees: kept).overrides, "entrada mantida da versão anterior"
    assert_raises(Domain::NotFound) { price(Pricing.new, fees: adjusted, fee_override: true) }
  end

  def test_pricer_records_the_agreement_applied_to_each_line
    pricing = Pricing.new
    general = agreement("a-geral", 800)
    pricing.agreements = { general: general, "p2" => agreement("a-produto", 1000, product_id: "p2") }
    priced = price(pricing, ids: %w[p1 p2 p3])

    assert_equal(%w[a-geral a-produto a-geral], priced.items.map { |item| item["negotiated_agreement_id"] })
    assert_equal([800, 1000, 800], priced.items.map { |item| item["negotiated_discount_bps"] })
    assert_equal %w[a-geral a-produto], priced.summary["agreements"].map { |entry| entry["id"] }, "cada condição aparece uma vez"
    assert_equal general.to_snapshot, priced.summary["agreements"].first
    refute_includes JSON.generate(priced.summary), "Observação interna"
    assert_equal([18_400, 18_000, 18_400], priced.items.map { |item| item["total_cents"] })
    assert_equal(3, pricing.calls.count { |call| call.first == :applicable_agreement && call.last == now })
    without = price(Pricing.new)

    assert_nil without.items.first["negotiated_agreement_id"]
    assert_empty without.summary["agreements"]
    assert_nil without.summary["coupon"]
  end

  def test_pricer_passes_lock_and_instant_to_the_coupon_lookup
    pricing = Pricing.new
    pricing.coupon = coupon
    priced = price(pricing, coupon_code: "  bemvindo10 ", lock_coupon: true)

    assert_equal([[:find_coupon, "BEMVINDO10", true, now]], pricing.calls.select { |call| call.first == :find_coupon })
    assert_equal 2_000, priced.summary["coupon_discount_cents"]
    assert_equal coupon.to_snapshot, priced.summary["coupon"]
    assert_equal coupon, priced.coupon
    price(pricing, coupon_code: "BEMVINDO10")

    assert_equal([:find_coupon, "BEMVINDO10", false, now], pricing.calls.rfind { |call| call.first == :find_coupon })
    assert_nil price(pricing, coupon_code: "   ").coupon, "campo vazio não consulta o cupom"
    pricing.coupon = nil
    error = assert_raises(Domain::ValidationError) { price(pricing, coupon_code: "NAOEXISTE") }

    assert_equal({ "cupom" => ["cupom inexistente"] }, error.errors)
    pricing.coupon = P::Coupons.set_active(coupon, false, now: now)
    error = assert_raises(Domain::ValidationError) { price(pricing, coupon_code: "BEMVINDO10") }

    assert_equal({ "cupom" => ["cupom desativado"] }, error.errors)
  end

  def test_product_without_price_table_has_no_agreement
    pricing = Pricing.new
    pricing.agreements = { general: agreement("a-geral", 800) }
    free = { "p1" => { product: product("p1").with(pricing: {}) } }
    priced = pricer(pricing).price(Tx.new, products: free, lines: [line("p1")], period: rental, zone: zone, customer_id: "k1", now: now)

    assert_equal [0, nil], priced.items.first.values_at("total_cents", "negotiated_agreement_id")
    assert_empty priced.summary["agreements"]
    assert_empty pricing.calls
  end

  def test_record_redemption_writes_one_row_per_reservation_with_coupon
    pricing = Pricing.new
    reservation = Data.define(:id).new(id: "r1")
    subject = pricer(pricing)

    assert_nil subject.record_redemption(Tx.new, price(pricing), reservation: reservation, actor_id: "u1", now: now)
    assert_empty pricing.redemptions, "sem cupom, nada é gravado"
    pricing.coupon = coupon
    priced = price(pricing, coupon_code: "BEMVINDO10", lock_coupon: true)
    row = subject.record_redemption(Tx.new, priced, reservation: reservation, actor_id: "u1", now: now)

    assert_equal [row], pricing.redemptions
    assert_equal [coupon.id, "r1", 20_000, 2_000, "u1", now],
                 row.values_at("coupon_id", "reservation_id", "subtotal_cents", "discount_cents", "redeemed_by", "redeemed_at")
    pricing.redemption_error = Domain::ValidationError.new({ "base" => ["dados inválidos"] })
    error = assert_raises(Domain::ValidationError) { subject.record_redemption(Tx.new, priced, reservation: reservation, actor_id: "u1", now: now) }

    assert_equal({ "cupom" => ["cupom esgotado"] }, error.errors, "recusa do gatilho de limite")
  end

  # Cadastro ---------------------------------------------------------------------------------------------

  def coupon_use_cases(records, audit)
    deps = { uow: Uow.new, coupons: records, audit: audit, clock: clock }
    { create: CT::CreateCoupon.new(**deps, ids: SequentialIds.new), update: CT::UpdateCoupon.new(**deps),
      activate: CT::SetCouponActive.new(**deps) }
  end

  def test_coupon_changes_without_difference_are_not_audited
    records = Records.new(coupon(description: "Boas-vindas", max_redemptions: 10))
    audit = Audit.new
    use_cases = coupon_use_cases(records, audit)
    same = use_cases[:update].call(owner, "BEMVINDO10", { description: " Boas-vindas ", max_redemptions: "10" })

    assert_equal [false, records.stored], [same.changed, same.record]
    refute use_cases[:activate].call(owner, records.stored.id, active: true).changed
    assert_empty audit.records
    assert_empty records.updates
    changed = use_cases[:update].call(owner, records.stored.id, { description: "Nova" }, lock_version: "1")

    assert_equal [true, "Nova", 2], [changed.changed, changed.record.description, changed.record.lock_version]
    assert_equal [["coupon.updated", "coupon", changed.record.id, { "changes" => { "description" => %w[Boas-vindas Nova] } }]], audit.records
    assert use_cases[:activate].call(owner, "bemvindo10", active: false).changed
    refute use_cases[:activate].call(owner, "bemvindo10", active: false).changed
    assert_equal %w[coupon.updated coupon.deactivated], audit.records.map(&:first)
    assert use_cases[:activate].call(owner, "bemvindo10", active: true).changed
    assert_equal "coupon.reactivated", audit.records.last.first
  end

  def test_stale_coupon_versions_are_refused
    records = Records.new(coupon)
    audit = Audit.new
    update = coupon_use_cases(records, audit)[:update]
    error = assert_raises(Domain::Conflict) { update.call(owner, "BEMVINDO10", { description: "Nova" }, lock_version: 7) }

    assert_equal ["stale_coupon", "o cupom foi alterado por outra operação; revise os valores atuais"], [error.code, error.message]
    records.concurrent_change = true
    error = assert_raises(Domain::Conflict) { update.call(owner, "BEMVINDO10", { description: "Nova" }) }

    assert_equal "stale_coupon", error.code, "gravação recusada pela versão no banco"
    assert_empty audit.records
    assert_raises(Domain::NotFound) { update.call(owner, "OUTRO", { description: "Nova" }) }
    assert_raises(Domain::NotFound) { update.call(owner, " ", { description: "Nova" }) }
    assert_raises(Domain::AccessDenied) { update.call(attendant, "BEMVINDO10", { description: "Nova" }) }
  end

  def test_coupon_creation_audits_and_refuses_a_repeated_code
    records = Records.new
    audit = Audit.new
    create = coupon_use_cases(records, audit)[:create]
    created = create.call(owner, { code: "volta20", kind: "fixed", value: 2_000, valid_until: now + 86_400, max_redemptions: 5 })

    assert_equal %w[VOLTA20 o1 u1], [created.code, created.organization_id, created.created_by]
    assert_equal [["coupon.created", "coupon", created.id,
                   { "code" => "VOLTA20", "kind" => "fixed", "value" => 2_000, "valid_from" => nil, "valid_until" => (now + 86_400).iso8601,
                     "max_redemptions" => 5, "min_subtotal_cents" => 0 }]], audit.records
    error = assert_raises(Domain::Conflict) { create.call(owner, { code: "VOLTA20", kind: "percent", value: 500 }) }

    assert_equal ["coupon_code_taken", "já existe cupom com o código VOLTA20 (inclusive desativado)"], [error.code, error.message]
    assert_equal 1, audit.records.size
    assert_raises(Domain::AccessDenied) { create.call(attendant, { code: "OUTRO10", kind: "percent", value: 1000 }) }
  end

  def test_composition_with_an_open_transaction_still_checks_the_permission
    records = Records.new(coupon)
    audit = Audit.new
    use_cases = coupon_use_cases(records, audit)

    assert use_cases[:update].call(owner, "BEMVINDO10", { description: "Nova" }, tx: Tx.new).changed
    assert_raises(Domain::AccessDenied) { use_cases[:update].call(attendant, "BEMVINDO10", { description: "Outra" }, tx: Tx.new) }
    assert_raises(Domain::AccessDenied) { use_cases[:activate].call(attendant, "BEMVINDO10", active: false, tx: Tx.new) }
    assert_equal 1, audit.records.size
  end

  def test_fee_changes_without_difference_are_not_audited_and_stale_versions_are_refused
    records = Records.new(fee)
    audit = Audit.new
    deps = { uow: Uow.new, fees: records, audit: audit, clock: clock }
    update = CT::UpdateFee.new(**deps)
    activate = CT::SetFeeActive.new(**deps)

    refute update.call(owner, "entrega", { name: " Entrega ", default_amount: M.new(15_000) }).changed
    refute activate.call(owner, FEE_ID, active: true).changed
    assert_empty audit.records
    error = assert_raises(Domain::Conflict) { update.call(owner, FEE_ID, { name: "Frete" }, lock_version: 3) }

    assert_equal ["stale_fee", "a tarifa foi alterada por outra operação; revise os valores atuais"], [error.code, error.message]
    changed = update.call(owner, FEE_ID, { default_amount: M.new(18_000) }, lock_version: 1)

    assert_equal [true, 18_000], [changed.changed, changed.record.default_amount.cents]
    assert_equal({ "changes" => { "default_amount_cents" => [15_000, 18_000] } }, audit.records.last.last)
    assert activate.call(owner, "ENTREGA", active: false).changed
    assert_equal ["fee.deactivated", "fee", FEE_ID, { "code" => "ENTREGA" }], audit.records.last
    missing = assert_raises(Domain::NotFound) { update.call(owner, "LIMPEZA", { name: "Limpeza" }) }

    assert_equal "tarifa não encontrada", missing.message
    create = CT::CreateFee.new(**deps, ids: SequentialIds.new)
    error = assert_raises(Domain::Conflict) { create.call(owner, { code: "entrega", name: "Entrega", default_amount: M.new(1_000) }) }

    assert_equal "fee_code_taken", error.code
  end

  def test_list_filters_are_validated_before_any_query
    coupons = CT::ListCoupons.new(uow: Uow.new, coupons: nil, clock: clock)
    fees = CT::ListFees.new(uow: Uow.new, fees: nil)

    assert_equal ["inválida"], assert_raises(Domain::ValidationError) { coupons.call(owner, status: "vencido") }.errors["situacao"]
    assert_equal ["inválida"], assert_raises(Domain::ValidationError) { coupons.call(owner, sort: "value") }.errors["ordenacao"]
    assert_equal ["até 40 caracteres"], assert_raises(Domain::ValidationError) { coupons.call(owner, search: "x" * 41) }.errors["busca"]
    assert_equal ["inválida"], assert_raises(Domain::ValidationError) { fees.call(owner, status: "expired") }.errors["situacao"]
    assert_equal ["inválida"], assert_raises(Domain::ValidationError) { fees.call(owner, sort: "valid_until") }.errors["ordenacao"]
    assert_raises(Domain::ValidationError) { fees.call(owner, limit: 101) }
  end
end
