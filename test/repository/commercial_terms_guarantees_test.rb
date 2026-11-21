# frozen_string_literal: true

require_relative "repository_helper"
require_relative "../support/commercial_terms_support"

# Garantias do banco para as condições comerciais, exercitadas com o papel de aplicação real:
# privilégios de coluna, gatilhos, exclusion constraint das condições, chaves compostas e as consultas
# dos repositórios de tarifas e de condições negociadas.
class CommercialTermsGuaranteesTest < DatabaseTest
  include CommercialTermsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-GAR", tracking: "bulk", pricing: { "daily_cents" => 10_000 })
    stock(@actor, @chairs, @branch, 20)
    @agreements = @system.repos[:price_agreements]
    @fees = @system.repos[:fees]
  end

  def now = @clock.now
  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def book(day: 10, **) = reserve(@actor, @customer, @branch, window(day), [line(@chairs, 1)], mode: "confirm", **)
  def denied(sql, params = []) = assert_raises(D::AccessDenied, sql) { tenant_tx { |tx| tx.execute(sql, params) } }
  def invalid(sql, params = []) = assert_raises(D::ValidationError, sql) { tenant_tx { |tx| tx.execute(sql, params) } }

  def agreement(from:, to: nil, product: nil, bps: 500, customer: @customer)
    Pricing::Agreement.new(id: SecureRandom.uuid, organization_id: @org[:organization_id], customer_id: customer.id, product_id: product&.id,
                           discount_bps: bps, valid_from: from, valid_until: to, notes: nil, created_by: @org[:user_id], created_at: now,
                           ended_at: nil, ended_by: nil, end_reason: nil)
  end

  def insert(record) = tenant_tx { |tx| @agreements.insert(tx, record) }.then { record }
  def overlapping?(record) = tenant_tx { |tx| @agreements.overlapping?(tx, record) }
  def end_at(record, at) = tenant_tx { |tx| @agreements.end_agreement(tx, record.with(ended_at: at, ended_by: @org[:user_id], end_reason: "Troca")) }
  def effective(at, product: @chairs, customer_id: @customer.id)
    tenant_tx { |tx| @system.repos[:pricing].effective_agreements(tx, customer_id, product.id, at) }
  end

  # Condição aplicada na precificação: a melhor entre as vigentes, como no Pricer.
  def applicable(at, product: @chairs) = Locentra::Domain::Pricing::Agreement.best(effective(at, product: product))

  def test_application_role_writes_only_the_editable_columns
    coupon = create_coupon("IMUTAVEL")
    fee = create_fee("ENTREGA", "Entrega", 15_000)
    condition = create_agreement(@customer, 800)
    book(coupon_code: "IMUTAVEL")

    denied("UPDATE coupons SET code = 'OUTRO' WHERE id = $1", [coupon.id])
    denied("UPDATE coupons SET kind = 'fixed' WHERE id = $1", [coupon.id])
    denied("UPDATE coupons SET value = 9000 WHERE id = $1", [coupon.id])
    denied("UPDATE additional_fees SET code = 'OUTRA' WHERE id = $1", [fee.id])
    denied("UPDATE coupon_redemptions SET discount_cents = 0")
    denied("DELETE FROM coupon_redemptions")
    denied("UPDATE customer_price_agreements SET discount_bps = 9000 WHERE id = $1", [condition.id])
    denied("UPDATE customer_price_agreements SET valid_until = now() WHERE id = $1", [condition.id])
    denied("DELETE FROM customer_price_agreements WHERE id = $1", [condition.id])
    denied("DELETE FROM additional_fees WHERE id = $1", [fee.id])

    assert_equal(1, tenant_tx { |tx| tx.execute("UPDATE coupons SET description = 'Editável' WHERE id = $1", [coupon.id]) })
    assert_equal(1, tenant_tx { |tx| tx.execute("UPDATE additional_fees SET name = 'Frete' WHERE id = $1", [fee.id]) })
  end

  def test_worker_role_does_not_write_commercial_terms
    checks = owner_query(<<~SQL).first
      SELECT has_column_privilege('locentra_worker', 'coupons', 'active', 'UPDATE') AS coupon_update,
             has_table_privilege('locentra_worker', 'coupons', 'DELETE') AS coupon_delete,
             has_table_privilege('locentra_worker', 'coupon_redemptions', 'UPDATE, DELETE') AS redemption_write,
             has_column_privilege('locentra_worker', 'customer_price_agreements', 'ended_at', 'UPDATE') AS agreement_update,
             has_any_column_privilege('locentra_worker', 'additional_fees', 'UPDATE') AS fee_update,
             has_column_privilege('locentra_app', 'coupons', 'code', 'UPDATE') AS app_code,
             has_column_privilege('locentra_app', 'coupons', 'redemptions', 'UPDATE') AS app_legacy_counter,
             has_table_privilege('locentra_app', 'coupons', 'DELETE') AS app_delete
    SQL

    assert_equal %w[f f f f f f t t], checks.values
  end

  def test_agreement_is_ended_only_once_with_date_and_reason
    condition = create_agreement(@customer, 800)
    locked = tenant_tx { |tx| @agreements.lock(tx, condition.id) }

    assert_equal condition, locked
    invalid("UPDATE customer_price_agreements SET ended_by = $2 WHERE id = $1", [condition.id, @org[:user_id]])
    invalid("UPDATE customer_price_agreements SET ended_at = $2 WHERE id = $1", [condition.id, now])
    invalid("UPDATE customer_price_agreements SET ended_at = $2, end_reason = 'x' WHERE id = $1", [condition.id, now])
    end_at(condition, now)
    invalid("UPDATE customer_price_agreements SET ended_at = $2, end_reason = 'De novo' WHERE id = $1", [condition.id, now + 60])
    invalid("UPDATE customer_price_agreements SET end_reason = 'Outro motivo' WHERE id = $1", [condition.id])
    assert_raises(D::InvalidTransition) { end_at(condition, now + 60) }
    stored = tenant_tx { |tx| @agreements.find(tx, condition.id) }

    assert_equal [now, @org[:user_id], "Troca"], [stored.ended_at, stored.ended_by, stored.end_reason]
    assert_nil(tenant_tx { |tx| @agreements.find(tx, SecureRandom.uuid) })
    assert_raises(PG::CheckViolation, "responsável sem data de encerramento") do
      owner_query(<<~SQL, [SecureRandom.uuid, @org[:organization_id], @customer.id, @chairs.id, @org[:user_id]])
        INSERT INTO customer_price_agreements (id, organization_id, customer_id, product_id, discount_bps, valid_from, created_at, ended_by)
        VALUES ($1, $2, $3, $4, 500, now(), now(), $5)
      SQL
    end
  end

  def test_pricing_snapshots_of_reservations_and_items_cannot_change
    reservation = book

    invalid("UPDATE reservations SET pricing = '{}' WHERE id = $1", [reservation.id])
    invalid("UPDATE reservations SET pricing = pricing || '{\"total_cents\": 1}' WHERE id = $1", [reservation.id])
    invalid("UPDATE reservation_items SET pricing = '{}' WHERE reservation_id = $1", [reservation.id])

    assert_equal(1, tenant_tx { |tx| tx.execute("UPDATE reservations SET pricing = pricing, notes = 'Observação' WHERE id = $1", [reservation.id]) })
    assert_equal 10_000, summary_of(reservation)["total_cents"]
    assert_raises(PG::CheckViolation, "o proprietário do esquema também não altera") do
      owner_query("UPDATE reservation_items SET pricing = '{}' WHERE reservation_id = $1", [reservation.id])
    end
  end

  def test_overlapping_agreements_of_the_same_scope_are_refused
    general = insert(agreement(from: now, to: now + 86_400))
    again = agreement(from: now + 3_600)

    assert overlapping?(again)
    assert_raises(A::AllocationConflict) { insert(again) }
    specific = agreement(from: now, product: @chairs, bps: 1000)

    refute overlapping?(specific), "condição geral e condição do produto coexistem"
    insert(specific)
    assert_raises(A::AllocationConflict) { insert(agreement(from: now + 60, product: @chairs)) }
    other_customer = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    insert(agreement(from: now, customer: other_customer))
    following = agreement(from: now + 86_400)

    refute overlapping?(following), "vigência semiaberta: a seguinte começa no instante em que a anterior termina"
    insert(following)

    assert_equal [general.id, specific.id], [applicable(now, product: create_product(@actor, sku: "OUTRO", tracking: "bulk")).id, applicable(now).id]
  end

  def test_ended_and_scheduled_agreements_free_the_period
    current = insert(agreement(from: now))
    replacement = agreement(from: now + 86_400, bps: 1000)

    assert_raises(A::AllocationConflict) { insert(replacement) }
    end_at(current, now + 86_400)

    refute overlapping?(replacement), "encerramento agendado e nova condição a partir do mesmo instante"
    insert(replacement)
    assert_raises(A::AllocationConflict) { insert(agreement(from: now + 86_399)) }
    assert_equal [current.id, current.id, replacement.id],
                 [now, now + 86_399, now + 86_400].map { |at| applicable(at).id }, "troca sem intervalo e sem sobreposição"
    end_at(replacement, now)

    assert_nil applicable(now + 86_400), "encerrada antes do início: a janela efetiva fica vazia"
    third = agreement(from: now + 86_400, to: now + 172_800, bps: 300)

    refute overlapping?(third)
    insert(third)

    assert_equal [third.id, nil], [applicable(now + 100_000)&.id, applicable(now + 172_800)&.id]
  end

  def test_best_effective_agreement_prefers_the_greatest_discount_then_the_product
    lens = create_product(@actor, sku: "LEN-GAR", tracking: "bulk")
    general = insert(agreement(from: now, bps: 800))
    specific = insert(agreement(from: now, product: @chairs, bps: 800))
    smaller = insert(agreement(from: now, product: lens, bps: 500))

    assert_equal specific.id, applicable(now).id, "em empate, a condição do produto"
    assert_equal general.id, applicable(now, product: lens).id, "a geral maior vence a do produto"
    assert_equal smaller.id, tenant_tx { |tx| @agreements.find(tx, smaller.id) }.id
    assert_nil applicable(now - 1), "antes do início"
    assert_equal [general.id, specific.id].sort, effective(now).map(&:id).sort, "vigentes: a geral e a do produto"
    assert_empty effective(now, customer_id: SecureRandom.uuid)
  end

  def test_composite_keys_keep_uses_inside_the_organization_and_protect_used_coupons
    coupon = create_coupon("CHAVE")
    unused = create_coupon("LIVRE")
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    foreign_customer = create_customer(other[:actor])
    foreign_product = create_product(other[:actor], sku: "CAD-B", tracking: "bulk")
    foreign = reserve(other[:actor], foreign_customer, other[:branch], window, [line(foreign_product, 1)], mode: "request")
    row = { "id" => SecureRandom.uuid, "coupon_id" => coupon.id, "reservation_id" => foreign.id, "subtotal_cents" => 1_000, "discount_cents" => 100,
            "redeemed_by" => nil, "redeemed_at" => now }

    assert_raises(D::NotFound) { tenant_tx { |tx| @system.repos[:pricing].insert_redemption(tx, row) } }
    assert_raises(D::NotFound) { tenant_tx(other) { |tx| @system.repos[:pricing].insert_redemption(tx, row) } }
    book(coupon_code: "CHAVE")

    assert_raises(D::NotFound, "a chave estrangeira do livro de usos impede a exclusão") { tenant_tx { |tx| @system.repos[:coupons].delete(tx, coupon.id) } }
    assert_equal 0, tenant_tx(other) { |tx| @system.repos[:coupons].delete(tx, unused.id) }, "outra organização não exclui"
    assert_equal(1, tenant_tx { |tx| @system.repos[:coupons].delete(tx, unused.id) })
    invalid("INSERT INTO coupon_redemptions (id, organization_id, coupon_id, reservation_id, subtotal_cents, discount_cents, redeemed_at) " \
            "SELECT $1, organization_id, coupon_id, reservation_id, 100, 200, now() FROM coupon_redemptions", [SecureRandom.uuid])
  end

  def test_fee_repository_searches_sorts_and_updates_with_optimistic_control
    delivery = create_fee("ENTREGA", "Entrega e retirada", 15_000)
    @clock.advance(60)
    assembly = create_fee("MONT_1", "Montagem 100% inclusa", 25_000)
    @clock.advance(60)
    cleaning = create_fee("LIMPEZA", "higienização", 8_000)
    uc(:set_fee_active).call(@actor, cleaning.id, active: false)
    list = ->(**options) { tenant_tx { |tx| @fees.search(tx, status: nil, search: "", sort: "name", limit: 10, offset: 0, **options) } }
    names = ->(**options) { list.call(**options).first.map(&:code) }

    assert_equal [%w[ENTREGA LIMPEZA MONT_1], 3], [names.call, list.call.last], "ordenação por nome sem diferenciar maiúsculas"
    assert_equal %w[ENTREGA LIMPEZA MONT_1], names.call(sort: "code")
    assert_equal %w[LIMPEZA MONT_1 ENTREGA], names.call(sort: "-created_at")
    assert_equal [%w[ENTREGA MONT_1], %w[LIMPEZA]], [names.call(status: "active"), names.call(status: "inactive")]
    assert_equal [%w[MONT_1], %w[MONT_1], %w[ENTREGA]], [names.call(search: "t_"), names.call(search: "100%"), names.call(search: "RETIRADA")]
    assert_equal([%w[LIMPEZA], 3], list.call(limit: 1, offset: 1).then { |items, total| [items.map(&:code), total] })
    assert_raises(D::ValidationError) { list.call(sort: "valor") }
    revised = delivery.revise({ default_amount: D::Money.new(18_000) }, now: now)

    assert_equal([1, 0], tenant_tx { |tx| [@fees.update(tx, revised, 1), @fees.update(tx, revised, 1)] })
    stored = tenant_tx { |tx| [@fees.find(tx, delivery.id), @fees.find_by_code(tx, "ENTREGA"), @fees.lock(tx, delivery.id), @fees.lock_by_code(tx, "ENTREGA")] }

    assert_equal [revised], stored.uniq
    assert_equal({ assembly.id => assembly }, tenant_tx { |tx| @system.repos[:pricing].fees_by_ids(tx, [assembly.id, SecureRandom.uuid]) })
    assert_empty(tenant_tx { |tx| @system.repos[:pricing].fees_by_ids(tx, []) })
  end

  def test_agreement_listing_orders_by_situation_and_hides_products_without_scope
    past = insert(agreement(from: now - 86_400, product: @chairs))
    end_at(past, now)
    @clock.advance(60)
    current = create_agreement(@customer, 800, notes: "Contrato anual")
    scheduled = create_agreement(@customer, 1_000, product: "CAD-GAR", valid_from: now + 86_400)
    list = lambda do |products, limit: 10, offset: 0|
      tenant_tx { |tx| @agreements.for_customer(tx, @customer.id, limit: limit, offset: offset, products: products, now: now) }
    end
    rows, total = list.call(true)

    assert_equal [3, [scheduled.id, current.id, past.id]], [total, rows.map { |row| row[:agreement].id }], "encerradas por último"
    assert_equal([["CAD-GAR", "Produto CAD-GAR"], [nil, nil]], rows.first(2).map { |row| row.values_at(:product_sku, :product_name) })
    assert_equal ["Dona Locadora Alfa", "Dona Locadora Alfa"], rows.last.values_at(:created_by_name, :ended_by_name)
    assert_nil rows.first[:ended_by_name]
    assert_equal([[nil, nil]], list.call(false, limit: 1).first.map { |row| row.values_at(:product_sku, :product_name) })
    assert_equal([past.id], list.call(true, limit: 2, offset: 2).first.map { |row| row[:agreement].id })
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_equal [[], 0], tenant_tx(other) { |tx| @agreements.for_customer(tx, @customer.id, limit: 10, offset: 0, products: true, now: now) }
    assert_nil tenant_tx(other) { |tx| @agreements.lock(tx, current.id) }
    assert_nil tenant_tx(other) { |tx| @system.repos[:catalog].find_product_by_sku(tx, "CAD-GAR") }
    assert_equal @chairs.id, tenant_tx { |tx| @system.repos[:catalog].find_product_by_sku(tx, "CAD-GAR") }.id
  end
end
