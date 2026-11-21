# frozen_string_literal: true

require_relative "integration_helper"

class CatalogCustomersTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
  end

  def test_customer_lifecycle_contacts_addresses_and_search
    customer = create_customer(@actor, name: "Joana Prado")
    create_customer(@actor, name: "Empresa 100% Eventos_", document: "11222333000181", kind: "company")
    contact = uc(:add_contact).call(@actor, customer.id, { name: "Pedro", document: "52998224725", authorized_pickup: true })
    uc(:add_address).call(@actor, customer.id, { street: "Rua A", number: "10", city: "São Paulo", state: "sp", postal_code: "01310-100" })
    data = uc(:get_customer).call(@actor, customer.id)

    assert contact.authorized_pickup
    assert_equal "SP", data[:addresses].first.state
    assert_equal 1, uc(:list_customers).call(@actor, search: "100%").total, "curingas do LIKE são escapados"
    assert_equal 1, uc(:list_customers).call(@actor, search: "529.982").total
    assert_equal 2, uc(:list_customers).call(@actor, sort: "-created_at").total
    assert_raises(D::ValidationError) { uc(:list_customers).call(@actor, sort: "name; DROP TABLE x") }
    assert_raises(D::ValidationError) { uc(:list_customers).call(@actor, status: "qualquer") }
    assert_raises(D::Conflict) { create_customer(@actor, name: "Duplicado") }
    updated = uc(:update_customer).call(@actor, customer.id, { name: "Joana P.", status: "inactive" })

    assert_equal "inactive", updated.status
    assert_equal 1, uc(:list_customers).call(@actor, status: "inactive").total
    assert_raises(D::ValidationError) { uc(:update_customer).call(@actor, customer.id, { status: "zumbi" }) }
    assert_raises(D::NotFound) { uc(:update_customer).call(@actor, SecureRandom.uuid, { name: "X" }) }
    assert_raises(D::NotFound) { uc(:add_contact).call(@actor, SecureRandom.uuid, { name: "X" }) }
  end

  def test_catalog_validations_and_listing
    camera = create_product(@actor, sku: "CAM-V", tracking: "serialized")
    chairs = create_product(@actor, sku: "CAD-V", tracking: "bulk", pricing: {})
    kit = create_product(@actor, sku: "KIT-V", tracking: "kit")

    assert_raises(D::Conflict) { create_product(@actor, sku: "CAM-V", tracking: "serialized") }
    assert_raises(D::ValidationError) { uc(:set_kit_components).call(@actor, camera.id, [{ product_id: chairs.id, quantity: 1 }]) }
    assert_raises(D::ValidationError) { uc(:set_kit_components).call(@actor, kit.id, [{ product_id: chairs.id, quantity: "x" }]) }
    assert_raises(D::ValidationError) { uc(:set_kit_components).call(@actor, kit.id, [{ product_id: kit.id, quantity: 1 }]) }
    uc(:set_kit_components).call(@actor, kit.id, [{ product_id: camera.id, quantity: 1 }, { product_id: chairs.id, quantity: 4 }])

    assert_equal 2, uc(:get_product).call(@actor, kit.id)[:components].size
    assert_raises(D::ValidationError) { uc(:register_asset).call(@actor, { product_id: chairs.id, branch_id: @branch.id, tag: "X1" }) }
    assert_raises(D::NotFound) { uc(:register_asset).call(@actor, { product_id: camera.id, branch_id: SecureRandom.uuid, tag: "X1" }) }
    register_assets(@actor, camera, @branch, 1, prefix: "DUP")
    assert_raises(D::Conflict) { register_assets(@actor, camera, @branch, 1, prefix: "DUP") }
    assert_raises(D::ValidationError) { uc(:adjust_stock).call(@actor, product_id: camera.id, branch_id: @branch.id, quantity: 1, kind: "acquisition") }
    assert_raises(D::ValidationError) { uc(:adjust_stock).call(@actor, product_id: chairs.id, branch_id: @branch.id, quantity: 1, kind: "magia") }
    assert_raises(D::ValidationError) { uc(:adjust_stock).call(@actor, product_id: chairs.id, branch_id: @branch.id, quantity: "0", kind: "acquisition") }
    assert_raises(D::ValidationError) { uc(:adjust_stock).call(@actor, product_id: chairs.id, branch_id: @branch.id, quantity: "dez", kind: "acquisition") }
    assert_raises(D::NotFound) { uc(:adjust_stock).call(@actor, product_id: chairs.id, branch_id: SecureRandom.uuid, quantity: 1, kind: "acquisition") }

    assert_equal 3, uc(:list_products).call(@actor).total
    assert_equal 1, uc(:list_products).call(@actor, tracking: "kit").total
    assert_equal 1, uc(:list_products).call(@actor, search: "cad").total
    assert_raises(D::ValidationError) { uc(:list_products).call(@actor, tracking: "x") }
  end

  def test_manual_blocks_and_asset_history
    camera = create_product(@actor, sku: "CAM-B", tracking: "serialized")
    chairs = create_product(@actor, sku: "CAD-B", tracking: "bulk")
    asset = register_assets(@actor, camera, @branch, 1).first
    pool = stock(@actor, chairs, @branch, 10)
    window = period("2026-03-10T08:00:00Z", "2026-03-10T18:00:00Z")
    uc(:block_availability).call(@actor, asset_id: asset.id, period: window, reason: "Calibração")

    assert_raises(D::Unavailable) { uc(:block_availability).call(@actor, asset_id: asset.id, period: window, reason: "De novo") }
    uc(:block_availability).call(@actor, stock_pool_id: pool.id, quantity: "6", period: window, reason: "Limpeza")

    assert_raises(D::Unavailable) { uc(:block_availability).call(@actor, stock_pool_id: pool.id, quantity: "5", period: window, reason: "Excesso") }
    assert_raises(D::ValidationError) { uc(:block_availability).call(@actor, stock_pool_id: pool.id, quantity: "x", period: window, reason: "Erro") }
    rows = uc(:check_availability).call(@actor, branch_id: @branch.id, period: window, product_ids: [camera.id, chairs.id])

    assert_equal([0, 4], rows.map { |r| r["available"] })
    uc(:change_asset_status).call(@actor, asset.id, status: "in_maintenance", reason: "Revisão", unavailable_until: t("2026-03-05T00:00:00Z"))
    uc(:change_asset_status).call(@actor, asset.id, status: "available")
    history = uc(:get_asset).call(@actor, asset.id)

    assert_equal(%w[status_changed status_changed registered], history[:events].map { |e| e["kind"] })
    assert_equal 1, history[:allocations].size
    assert_raises(D::ValidationError) { uc(:change_asset_status).call(@actor, asset.id, status: "teletransportado") }
    uc(:change_asset_status).call(@actor, asset.id, status: "retired")

    assert_raises(D::InvalidTransition) { uc(:change_asset_status).call(@actor, asset.id, status: "available") }
  end

  def test_calendar_and_reservation_input_errors
    camera = create_product(@actor, sku: "CAM-C", tracking: "serialized")
    register_assets(@actor, camera, @branch, 1)
    customer = create_customer(@actor)
    calendar = uc(:calendar).call(@actor, branch_id: @branch.id, start_date: Date.new(2026, 3, 10), days: "3")

    assert_equal 3, calendar[:columns].size
    assert_raises(D::ValidationError) { uc(:calendar).call(@actor, branch_id: @branch.id, start_date: Date.new(2026, 3, 10), days: "90") }
    assert_raises(D::ValidationError) { uc(:calendar).call(@actor, branch_id: @branch.id, start_date: Date.new(2026, 3, 10), days: "x") }
    window = period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z")

    assert_raises(D::NotFound) { reserve(@actor, customer, D::Organizations::Branch.new(id: SecureRandom.uuid, organization_id: nil, name: "", code: "", address: nil, active: true), window, [line(camera, 1)]) }
    assert_raises(D::ValidationError) { reserve(@actor, customer, @branch, window, [line(camera, 1)], mode: "talvez") }
    missing = assert_raises(D::ValidationError) { reserve(@actor, customer, @branch, window, [line(camera, 1)], coupon_code: "NAOEXISTE") }

    assert_equal({ "cupom" => ["cupom inexistente"] }, missing.errors)
    fake = D::Reservations::Line.new(product_id: SecureRandom.uuid, quantity: 1)

    assert_raises(D::NotFound) { reserve(@actor, customer, @branch, window, [fake]) }
    assert_raises(D::ValidationError) { uc(:list_reservations).call(@actor, sort: "drop") }
    assert_raises(D::ValidationError) { uc(:list_reservations).call(@actor, status: "x") }
  end

  def test_coupons_and_negotiated_conditions_apply_and_respect_limits
    camera = create_product(@actor, sku: "CAM-CP", tracking: "serialized", pricing: { "daily_cents" => 10_000 })
    register_assets(@actor, camera, @branch, 3)
    customer = create_customer(@actor)
    @system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      @system.repos[:pricing].insert_coupon(tx, "id" => SecureRandom.uuid, "code" => "PRIMEIRA", "kind" => "percent", "value" => 1000,
                                                "max_redemptions" => 1, "min_subtotal_cents" => 0, "created_at" => @clock.now)
      @system.repos[:pricing].insert_agreement(tx, "id" => SecureRandom.uuid, "customer_id" => customer.id, "discount_bps" => 500,
                                                   "created_at" => @clock.now, "valid_from" => @clock.now - 3_600)
      @system.repos[:pricing].insert_agreement(tx, "id" => SecureRandom.uuid, "customer_id" => customer.id, "product_id" => camera.id,
                                                   "discount_bps" => 9_000, "created_at" => @clock.now, "valid_from" => @clock.now + 3_600)
    end
    window = period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z")
    reservation = reserve(@actor, customer, @branch, window, [line(camera, 1)], coupon_code: "primeira")
    summary = uc(:get_reservation).call(@actor, reservation.id)[:pricing][:summary]

    assert_equal 9_500, summary["subtotal_cents"], "condição negociada de 5% (a do produto ainda não começou)"
    assert_equal 950, summary["coupon_discount_cents"]
    assert_equal 8_550, reservation.total.cents
    exhausted = assert_raises(D::ValidationError) { reserve(@actor, customer, @branch, window, [line(camera, 1)], coupon_code: "PRIMEIRA") }

    assert_equal({ "cupom" => ["cupom esgotado"] }, exhausted.errors)
    assert_equal 1, owner_query("SELECT count(*) AS n FROM coupon_redemptions").first["n"].to_i
    assert_equal 0, owner_query("SELECT redemptions FROM coupons").first["redemptions"].to_i, "o contador da versão 1.0.0 não é mais gravado"
    owner_query("UPDATE memberships SET role = 'attendant' WHERE user_id = $1", [@org[:user_id]])

    assert_raises(D::AccessDenied) { reserve(@actor, customer, @branch, window, [line(camera, 1)], manual_discount_bps: 1000) }
  end
end
