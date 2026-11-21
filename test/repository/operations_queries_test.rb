# frozen_string_literal: true

require_relative "repository_helper"
require_relative "../support/operations_support"

# Consultas paginadas da API com o papel de aplicação: alertas (filtros, total, ordem e deslocamento),
# inspeções com produto, filial e total, e a versão do documento do contrato. A organização B não vê os
# registros da organização A.
class OperationsQueriesTest < DatabaseTest
  include OperationsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-QRY", tracking: "serialized")
    register_assets(@actor, @camera, @branch, 3)
    @chairs = create_product(@actor, sku: "CAD-QRY", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 10)
    @beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
  end

  def tenant_tx(org = @org, &) = @system.transactor.call(tenant_id: org[:organization_id], &)
  def alerts = @system.repos[:alerts]
  def inspections = @system.repos[:inspections]

  def insert_alert(tx, reservation_id, kind, minutes, related: nil)
    id = SecureRandom.uuid
    alerts.insert(tx, "id" => id, "reservation_id" => reservation_id, "kind" => kind, "related_reservation_id" => related, "asset_id" => nil,
                      "stock_pool_id" => nil, "dedup_key" => "teste:#{id}", "details" => { "origem" => "teste" },
                      "created_at" => @clock.now + (minutes * 60))
    id
  end

  def search(tx, status: "open", kind: nil, reservation_id: nil, limit: 25, offset: 0)
    alerts.search(tx, status: status, kind: kind, reservation_id: reservation_id, limit: limit, offset: offset)
  end

  def test_alert_search_filters_counts_orders_and_isolates_the_tenant
    first = confirmed([line(@camera, 1)])
    second = confirmed([line(@camera, 1)], after_rental)
    beta_customer = create_customer(@beta[:actor])
    beta_chairs = create_product(@beta[:actor], sku: "CAD-BETA", tracking: "bulk")
    stock(@beta[:actor], beta_chairs, @beta[:branch], 2)
    beta_reservation = reserve(@beta[:actor], beta_customer, @beta[:branch], rental_period, [line(beta_chairs, 1)], mode: "confirm")
    ids = tenant_tx do |tx|
      { overdue: insert_alert(tx, first.id, "overdue", 1), affected: insert_alert(tx, second.id, "affected_by_overdue", 2, related: first.id),
        unavailable: insert_alert(tx, second.id, "asset_unavailable", 3), resolved: insert_alert(tx, second.id, "overdue", 4) }
    end
    tenant_tx { |tx| alerts.resolve(tx, alerts.lock(tx, ids[:resolved]).resolve("Prazo estendido", @clock.now), @actor.user_id) }
    tenant_tx(@beta) { |tx| insert_alert(tx, beta_reservation.id, "overdue", 5) }

    tenant_tx do |tx|
      items, total = search(tx)

      assert_equal [ids[:unavailable], ids[:affected], ids[:overdue]], items.map(&:id), "mais recentes primeiro"
      assert_equal 3, total
      assert_kind_of D::Alerts::Alert, items.first
      assert_equal([[ids[:affected]], 1], search(tx, kind: "affected_by_overdue").then { |list, count| [list.map(&:id), count] })
      assert_equal [[ids[:affected], ids[:overdue]], 2], search(tx, reservation_id: first.id).then { |list, count| [list.map(&:id), count] },
                   "a reserva própria e a relacionada"
      assert_equal([[ids[:affected]], 3], search(tx, limit: 1, offset: 1).then { |list, count| [list.map(&:id), count] })
      assert_equal([[], 3], search(tx, offset: 3).then { |list, count| [list.map(&:id), count] })
      resolved, count = search(tx, status: "resolved", kind: "overdue", reservation_id: second.id)

      assert_equal [[ids[:resolved]], 1, "Prazo estendido"], [resolved.map(&:id), count, resolved.first.resolution]
    end
    tenant_tx(@beta) do |tx|
      items, total = search(tx)

      assert_equal [[beta_reservation.id], 1], [items.map(&:reservation_id), total]
      assert_equal 0, search(tx, reservation_id: first.id).last
    end
  end

  def test_inspection_list_pages_with_product_branch_and_count
    reservation = confirmed([line(@camera, 2), line(@chairs, 3)])
    pick_up(reservation)
    return_all(reservation, requires_inspection: true)
    pending = tenant_tx { |tx| inspections.list(tx, status: "pending") }
    uc(:approve_inspection).call(@actor, pending.first["id"], notes: "Sem avarias")
    beta_camera = create_product(@beta[:actor], sku: "CAM-BETA", tracking: "serialized")
    beta_asset = register_assets(@beta[:actor], beta_camera, @beta[:branch], 1).first
    tenant_tx(@beta) do |tx|
      inspections.insert(tx, D::Maintenance::Inspection.build(id: SecureRandom.uuid, organization_id: @beta[:organization_id], product_id: beta_camera.id,
                                                              branch_id: @beta[:branch].id, reason: "Conferência", created_at: @clock.now,
                                                              asset_id: beta_asset.id))
    end

    tenant_tx do |tx|
      all = inspections.list(tx, status: "pending")

      assert_equal [3, 2, 1], [pending.size, all.size, inspections.count(tx, status: "decided")]
      assert_equal 2, inspections.count(tx, status: "pending")
      assert_equal([all[1]["id"]], inspections.list(tx, status: "pending", limit: 1, offset: 1).map { |row| row["id"] })
      assert_empty inspections.list(tx, status: "pending", offset: 2)
      assert_equal [@branch.id], all.map { |row| row["branch_id"] }.uniq
      assert_equal [@camera.id, @chairs.id].sort, pending.map { |row| row["product_id"] }.uniq.sort
    end
    tenant_tx(@beta) { |tx| assert_equal [1, 0], [inspections.count(tx, status: "pending"), inspections.count(tx, status: "decided")] }
  end

  def test_find_document_returns_the_version_only_inside_the_tenant
    reservation = confirmed([line(@camera, 1)])
    contract = uc(:issue_contract).call(@actor, reservation.id)
    document = tenant_tx { |tx| @system.repos[:contracts].find_document(tx, contract.id, 1) }

    assert_equal %w[attachment_id generated_at id reason sha256 version], document.keys.sort
    assert_equal [1, "issue"], [document["version"], document["reason"]]
    assert_match(/\A\h{64}\z/, document["sha256"])
    assert_nil(tenant_tx { |tx| @system.repos[:contracts].find_document(tx, contract.id, 2) })
    assert_nil(tenant_tx(@beta) { |tx| @system.repos[:contracts].find_document(tx, contract.id, 1) })
  end

  def test_pickup_line_details_include_the_product
    reservation = confirmed([line(@camera, 1), line(@chairs, 2)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    lines = tenant_tx { |tx| @system.repos[:fulfillment].line_details(tx, pickup.id) }

    assert_equal [@camera.id, @chairs.id].sort, lines.map { |row| row["product_id"] }.sort
    assert_empty(tenant_tx(@beta) { |tx| @system.repos[:fulfillment].line_details(tx, pickup.id) })
  end
end
