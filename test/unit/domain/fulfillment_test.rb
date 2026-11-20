# frozen_string_literal: true

require_relative "../unit_helper"

class FulfillmentTest < UnitTest
  F = Locentra::Domain::Fulfillment
  C = Locentra::Domain::Customers
  R = Locentra::Domain::Reservations
  Money = Locentra::Domain::Money
  LINE_ID = "00000000-0000-7000-8000-0000000000a1"
  OTHER_ID = "00000000-0000-7000-8000-0000000000a2"

  def reservation(status = "confirmed")
    R::Reservation.new(id: "r1", organization_id: "o1", branch_id: "b1", customer_id: "c1", code: "R-000001", status: status, source: "staff",
                       period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), hold_expires_at: nil, quote_id: nil, notes: nil,
                       total: Money.zero, deposit: Money.zero, version: 1)
  end

  def asset_line(**changes)
    F::PickupLine.from_allocation(id: LINE_ID, pickup_id: "p1", reservation_id: "r1",
                                  allocation: { "id" => "al1", "asset_id" => "a1", "stock_pool_id" => nil, "product_id" => "prod",
                                                "reservation_item_id" => "item1", "quantity" => 1 }).with(**changes)
  end

  def stock_line(**changes)
    F::PickupLine.from_allocation(id: OTHER_ID, pickup_id: "p1", reservation_id: "r1",
                                  allocation: { "id" => "al2", "asset_id" => nil, "stock_pool_id" => "pool", "product_id" => "chairs",
                                                "reservation_item_id" => "item2", "quantity" => 5 }).with(**changes)
  end

  def entry(outcome: "ok", quantity: 1, line: LINE_ID, **extra)
    F::ReturnEntry.build(pickup_line_id: line, outcome: outcome, quantity: quantity, **extra)
  end

  def test_pickup_state_machine
    now = t("2026-03-09T10:00:00Z")
    pickup = F::Pickup.start(id: "p1", organization_id: "o1", reservation: reservation, now: now)

    assert_predicate pickup, :picking?
    assert_equal "Em separação", pickup.status_label
    assert_raises(Locentra::Domain::InvalidTransition) { F::Pickup.start(id: "p", organization_id: "o", reservation: reservation("held"), now: now) }
    picker = F::Picker.new(kind: "customer", contact_id: nil, name: "Ana", document: "52998224725")
    delivered = pickup.deliver(picker, now, notes: "  balcão  ")

    assert_predicate delivered, :delivered?
    assert_equal ["balcão", 2], [delivered.notes, delivered.version]
    assert_raises(Locentra::Domain::InvalidTransition) { delivered.cancel(now) }
    assert_raises(Locentra::Domain::InvalidTransition) { delivered.deliver(picker, now) }
    assert_equal "cancelled", pickup.cancel(now).status
  end

  def test_picker_rules
    person = C::Customer.build(id: "c", organization_id: "o", kind: "individual", name: "Ana Lima", document: "52998224725")
    company = C::Customer.build(id: "c", organization_id: "o", kind: "company", name: "Produtora", document: "11222333000181")
    authorized = C::Contact.build(id: "k", organization_id: "o", customer_id: "c", name: "Bruno", document: "111.444.777-35", authorized_pickup: true)
    plain = C::Contact.build(id: "k2", organization_id: "o", customer_id: "c", name: "Carla")

    assert_equal(["customer", "529.982.247-25", "Cliente"], F::Picker.customer(person).then { |p| [p.kind, p.formatted_document, p.kind_label] })
    assert_raises(Locentra::Domain::ValidationError) { F::Picker.customer(company) }
    assert_equal(["contact", "k", "Contato autorizado"], F::Picker.contact(authorized).then { |p| [p.kind, p.contact_id, p.kind_label] })
    assert_raises(Locentra::Domain::ValidationError) { F::Picker.contact(plain) }
    assert_raises(Locentra::Domain::ValidationError) { F::Picker.contact(authorized.with(document: "12345678900")) }
  end

  def test_asset_line_check_and_delivery
    line = asset_line

    assert_predicate line, :asset?
    assert_equal "Aguardando conferência", line.status_label
    checked = line.check_asset("a2")

    assert_equal %w[a2 checked], [checked.asset_id, checked.status]
    assert_raises(Locentra::Domain::ValidationError) { line.check_quantity(1) }
    delivered = checked.deliver

    assert_equal ["delivered", 1, 0], [delivered.status, delivered.delivered_quantity, delivered.undelivered_quantity]
    assert_raises(Locentra::Domain::InvalidTransition) { delivered.check_asset("a3") }
    assert_raises(Locentra::Domain::InvalidTransition) { delivered.cancel }
    skipped = line.deliver

    assert_equal ["not_delivered", 0, 1], [skipped.status, skipped.delivered_quantity, skipped.undelivered_quantity]
    assert_equal 0, skipped.pending_return
    assert_equal "cancelled", line.cancel.status
  end

  def test_stock_line_partial_check_and_delivery
    line = stock_line

    assert_raises(Locentra::Domain::ValidationError) { line.check_asset("x") }
    assert_raises(Locentra::Domain::ValidationError) { line.check_quantity(6) }
    assert_equal "pending", line.check_quantity(0).status
    partial = line.check_quantity(3).deliver

    assert_equal ["partial", 3, 2], [partial.status, partial.delivered_quantity, partial.undelivered_quantity]
    assert_equal "delivered", line.check_quantity(5).deliver.status
    assert_equal 3, partial.pending_return
    returned = partial.register_return("ok", 2).register_return("missing", 1)

    assert_equal [2, 1, 0], [returned.returned_quantity, returned.missing_quantity, returned.pending_return]
    refute_predicate returned, :outstanding?
    error = assert_raises(Locentra::Domain::Conflict) { returned.register_return("ok", 1) }
    assert_equal "already_returned", error.code
  end

  def test_return_entry_rules
    assert_raises(Locentra::Domain::ValidationError) { entry(outcome: "lost") }
    assert_raises(Locentra::Domain::ValidationError) { entry(quantity: 0) }
    assert_raises(Locentra::Domain::ValidationError) { entry(quantity: "um") }
    assert_raises(Locentra::Domain::ValidationError) { entry(line: "x") }
    assert_raises(Locentra::Domain::ValidationError) { entry(outcome: "damaged") }
    assert_raises(Locentra::Domain::ValidationError) { entry(outcome: "missing", notes: "ok") }
    damaged = entry(outcome: "damaged", notes: "tela quebrada", requires_inspection: false)

    assert damaged.requires_inspection, "avaria sempre exige inspeção"
    assert_predicate damaged, :damaged?
    missing = entry(outcome: "missing", notes: "não devolvido", requires_inspection: true)

    refute missing.requires_inspection, "falta nunca passa por inspeção"
    assert_equal "Faltante", missing.outcome_label
    assert entry(requires_inspection: "1").requires_inspection
    refute entry.requires_inspection
    assert_equal 3, entry(quantity: "3").quantity
  end

  def test_return_plan_accumulates_and_detects_completion
    lines = { LINE_ID => asset_line.check_asset("a1").deliver, OTHER_ID => stock_line.check_quantity(5).deliver }

    assert_raises(Locentra::Domain::ValidationError) { F::ReturnPlan.apply(lines, []) }
    assert_raises(Locentra::Domain::NotFound) { F::ReturnPlan.apply(lines, [entry(line: "00000000-0000-7000-8000-0000000000ff")]) }
    assert_raises(Locentra::Domain::ValidationError) { F::ReturnPlan.apply(lines, [entry(quantity: 2)]) }
    partial = F::ReturnPlan.apply(lines, [entry, entry(line: OTHER_ID, quantity: 2)])

    refute F::ReturnPlan.complete?(partial)
    assert_raises(Locentra::Domain::Conflict) { F::ReturnPlan.apply(partial, [entry(line: OTHER_ID, quantity: 4)]) }
    done = F::ReturnPlan.apply(partial, [entry(line: OTHER_ID, quantity: 2), entry(line: OTHER_ID, outcome: "missing", notes: "sumiu")])

    assert F::ReturnPlan.complete?(done)
    assert_equal [4, 1], [done[OTHER_ID].returned_quantity, done[OTHER_ID].missing_quantity]
  end

  def test_late_fee_policy_for_simple_items_and_kits
    zone = Locentra::Domain::TimeZone.new("America/Sao_Paulo")
    table = { "daily_cents" => 10_000 }
    items = { "item1" => { "pricing" => { "table" => table }, "quantity" => 1, "tracking" => "kit" },
              "item2" => { "pricing" => { "table" => table }, "quantity" => 5, "tracking" => "bulk" } }
    kit_line = asset_line.check_asset("a1").deliver
    second_component = asset_line.with(id: "00000000-0000-7000-8000-0000000000a3", asset_id: "a9").check_asset("a9").deliver
    before = { LINE_ID => kit_line, second_component.id => second_component, OTHER_ID => stock_line.check_quantity(5).deliver }
    scheduled = t("2026-03-11T08:00:00Z")
    late = t("2026-03-11T14:00:00Z")
    entries = [entry, entry(line: OTHER_ID, quantity: 3), entry(line: OTHER_ID, outcome: "missing", quantity: 2, notes: "faltam")]
    after = F::ReturnPlan.apply(before, entries)
    charges = F::LateFeePolicy.charges(items: items, entries: entries, before: before, after: after, scheduled_end: scheduled, returned_at: late, zone: zone)

    assert_equal [["item2", 3, 30_000]], charges.map { |c| [c[:item_id], c[:quantity], c[:amount].cents] }, "kit ainda incompleto não é cobrado"
    rest = [entry(line: second_component.id)]
    final = F::ReturnPlan.apply(after, rest)
    kit = F::LateFeePolicy.charges(items: items, entries: rest, before: after, after: final, scheduled_end: scheduled, returned_at: late, zone: zone)

    assert_equal([["item1", 1, 10_000]], kit.map { |c| [c[:item_id], c[:quantity], c[:amount].cents] })
    assert_empty F::LateFeePolicy.charges(items: items, entries: entries, before: before, after: after, scheduled_end: scheduled,
                                          returned_at: scheduled, zone: zone)
    unpriced = items.merge("item2" => items["item2"].merge("pricing" => {}))

    assert_empty F::LateFeePolicy.charges(items: unpriced, entries: entries.drop(1), before: before, after: after, scheduled_end: scheduled,
                                          returned_at: late, zone: zone)
  end
end
