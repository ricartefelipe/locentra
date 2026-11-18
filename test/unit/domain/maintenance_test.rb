# frozen_string_literal: true

require_relative "../unit_helper"

class MaintenanceDomainTest < UnitTest
  M = Locentra::Domain::Maintenance
  Money = Locentra::Domain::Money

  def now = t("2026-03-09T10:00:00Z")

  def inspection(**extra)
    M::Inspection.build(id: "i1", organization_id: "o1", product_id: "p1", branch_id: "b1", reason: "Avariado na devolução", created_at: now,
                        asset_id: "a1", **extra)
  end

  def order(**extra)
    M::Order.build(id: "m1", organization_id: "o1", code: "OM-000001", product_id: "p1", branch_id: "b1", description: "Troca do display",
                   opened_at: now, asset_id: "a1", **extra)
  end

  def report(**extra)
    M::DamageReport.build(id: "d1", organization_id: "o1", code: "AV-000001", reservation_id: "r1", reservation_item_id: "ri1", return_line_id: "rl1",
                          product_id: "p1", quantity: 1, kind: "damage", severity: "moderate", description: "Tela trincada",
                          estimated_cost: Money.new(10_000), asset_id: "a1", **extra)
  end

  def test_inspection_decisions
    pending = inspection

    assert_predicate pending, :pending?
    assert_predicate pending, :asset?
    assert_equal "Pendente", pending.status_label
    approved = pending.approve("  ok  ", now)

    assert_equal ["approved", "ok", now], [approved.status, approved.decision_notes, approved.decided_at]
    assert_raises(Locentra::Domain::InvalidTransition) { approved.reject("tarde", "m1", now) }
    assert_raises(Locentra::Domain::ValidationError) { pending.reject(" ", "m1", now) }
    rejected = pending.reject("display danificado", "m1", now)

    assert_equal %w[rejected m1], [rejected.status, rejected.maintenance_order_id]
    assert_raises(Locentra::Domain::InvalidTransition) { rejected.approve(nil, now) }
    stock = inspection(asset_id: nil, stock_pool_id: "pool", quantity: 4, block_allocation_id: "blk")

    assert_equal 4, stock.quantity
    refute_predicate stock, :asset?
    assert_raises(ArgumentError) { inspection(stock_pool_id: "pool") }
    assert_raises(ArgumentError) { inspection(asset_id: nil, stock_pool_id: "pool") }
    assert_raises(Locentra::Domain::ValidationError) { inspection(reason: "") }
  end

  def test_maintenance_order_state_machine
    opened = order

    assert_predicate opened, :active?
    assert_equal "Aberta", opened.status_label
    assert_raises(Locentra::Domain::InvalidTransition) { opened.complete(cost: Money.zero, requires_inspection: false, now: now) }
    started = opened.start(now)

    assert_equal ["in_progress", now, 2], [started.status, started.started_at, started.version]
    assert_raises(Locentra::Domain::ValidationError) { started.complete(cost: Money.new(-1), requires_inspection: false, now: now) }
    done = started.complete(cost: Money.new(25_000), requires_inspection: "1", now: now, notes: "peça trocada")

    assert_equal [25_000, true, "peça trocada"], [done.cost.cents, done.requires_inspection, done.resolution_notes]
    refute_predicate done, :active?
    assert_raises(Locentra::Domain::InvalidTransition) { done.cancel("desistência", now) }
    assert_raises(Locentra::Domain::ValidationError) { opened.cancel("", now) }
    assert_equal "cancelled", opened.cancel("engano", now).status
    assert_equal "available", opened.status_after_cancel
    assert_equal "in_inspection", order(previous_status: "in_inspection").status_after_cancel
  end

  def test_maintenance_order_validation
    assert_raises(Locentra::Domain::ValidationError) { order(description: "ab") }
    assert_raises(ArgumentError) { order(asset_id: nil) }
    assert_raises(Locentra::Domain::ValidationError) { order(asset_id: nil, stock_pool_id: "pool", quantity: 0) }
    assert_equal 1, order(quantity: 9).quantity, "ordem de ativo sempre tem quantidade 1"
    assert_equal 3, order(asset_id: nil, stock_pool_id: "pool", quantity: 3, block_allocation_id: "b").quantity
  end

  def test_damage_report_revision_approval_and_dismissal
    open = report

    assert_predicate open, :open?
    assert_equal %w[Avaria Moderada], [open.kind_label, open.severity_label]
    assert_equal "Aguardando aprovação", open.status_label
    revised = open.revise(description: "Tela e carcaça", severity: "severe", estimated_cost: Money.new(30_000))

    assert_equal ["severe", 30_000, 2], [revised.severity, revised.estimated_cost.cents, revised.version]
    assert_raises(Locentra::Domain::ValidationError) { open.revise(description: "Tela", severity: "x", estimated_cost: Money.zero) }
    assert_raises(Locentra::Domain::ValidationError) { open.revise(description: "Tela", severity: "minor", estimated_cost: Money.new(-1)) }
    error = assert_raises(Locentra::Domain::ValidationError) { open.approve(amount: Money.new(100), evidence_count: 0, adjustment_id: "adj") }
    assert_includes error.errors.keys, "evidencias"
    assert_raises(Locentra::Domain::ValidationError) { open.approve(amount: Money.zero, evidence_count: 1, adjustment_id: "adj") }
    approved = open.approve(amount: Money.new(12_000), evidence_count: 2, adjustment_id: "adj", notes: "orçamento")

    assert_equal ["approved", 12_000, "adj"], [approved.status, approved.charged.cents, approved.adjustment_id]
    assert_raises(Locentra::Domain::InvalidTransition) { approved.dismiss("tarde") }
    assert_raises(Locentra::Domain::InvalidTransition) { approved.revise(description: "x" * 5, severity: "minor", estimated_cost: Money.zero) }
    assert_raises(Locentra::Domain::ValidationError) { open.dismiss("") }
    assert_equal "dismissed", open.dismiss("desgaste natural").status
    assert_raises(Locentra::Domain::ValidationError) { report(kind: "roubo") }
    assert_raises(ArgumentError) { report(asset_id: nil) }
    assert_equal "Falta", report(kind: "missing", severity: "total_loss").kind_label
  end
end
