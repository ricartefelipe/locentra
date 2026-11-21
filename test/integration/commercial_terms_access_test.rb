# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/commercial_terms_support"
require_relative "../support/portal_support"

# Permissões das condições comerciais por papel e por escopo de credencial, e isolamento entre
# organizações: o mesmo código existe de forma independente em cada uma.
class CommercialTermsAccessTest < DatabaseTest
  include CommercialTermsSupport
  include PortalHelpers

  MATRIX = {
    "coupons.read" => %w[owner admin manager attendant finance auditor],
    "coupons.write" => %w[owner admin manager],
    "price_agreements.read" => %w[owner admin manager attendant finance auditor],
    "price_agreements.write" => %w[owner admin manager],
    "fees.read" => %w[owner admin manager attendant stock_operator finance auditor],
    "fees.write" => %w[owner admin manager],
    "fees.override" => %w[owner admin manager]
  }.freeze

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-ACE", tracking: "bulk", pricing: { "daily_cents" => 10_000 })
    stock(@actor, @chairs, @branch, 20)
    @coupon = create_coupon("BEMVINDO10")
    @fee = create_fee("ENTREGA", "Entrega", 15_000)
    @agreement = create_agreement(@customer, 800)
  end

  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def member(role) = staff_member(@org, "#{role}@alfa.test", role)
  def allowed?(&) = yield.then { true }
  def denied?(&) = assert_raises(D::AccessDenied, &).then { true }

  def credential(scopes, by: @actor, name: "Integração")
    uc(:authenticate_credential).call(uc(:create_credential).call(by, name: name, scopes: scopes, expires_in_days: 30)["token"])
  end

  # Cada leitura e cada mutação do cadastro, com a permissão que exige.
  def operations(actor, suffix)
    {
      "coupons.read" => [-> { uc(:list_coupons).call(actor) }, -> { uc(:get_coupon).call(actor, @coupon.id) },
                         -> { uc(:list_coupon_redemptions).call(actor, "BEMVINDO10") }],
      "coupons.write" => [-> { create_coupon("NOVO#{suffix}", actor: actor) }, -> { uc(:update_coupon).call(actor, @coupon.id, {}) },
                          -> { uc(:set_coupon_active).call(actor, @coupon.id, active: true) }],
      "price_agreements.read" => [-> { uc(:list_price_agreements).call(actor, @customer.id) }],
      "price_agreements.write" => [-> { create_agreement(@customer, 500, actor: actor, product: @chairs.id, valid_until: @clock.now + 60) }],
      "fees.read" => [-> { uc(:list_fees).call(actor) }, -> { uc(:get_fee).call(actor, "ENTREGA") }],
      "fees.write" => [-> { create_fee("TAXA#{suffix}", "Taxa", 1_000, actor: actor) }, -> { uc(:update_fee).call(actor, @fee.id, {}) },
                       -> { uc(:set_fee_active).call(actor, @fee.id, active: true) }]
    }
  end

  def test_permission_matrix_matches_the_documented_roles
    MATRIX.each do |permission, roles|
      assert_equal roles.sort, D::Identity::PERMISSIONS.fetch(permission).sort, permission
      D::Identity::ROLES.each_key { |role| assert_equal roles.include?(role), D::Identity.permitted?(role, permission), "#{role} #{permission}" }
    end
  end

  def test_each_role_reads_and_writes_only_what_the_matrix_allows
    %w[admin manager attendant stock_operator finance auditor].each_with_index do |role, index|
      actor = member(role)
      operations(actor, index).each do |permission, calls|
        calls.each do |call|
          if MATRIX.fetch(permission).include?(role)
            assert allowed?(&call), "#{role} deveria ter #{permission}"
          else
            assert denied?(&call), "#{role} não deveria ter #{permission}"
          end
        end
        @clock.advance(120)
      end
    end
  end

  def test_attendant_and_stock_operator_boundaries
    attendant = member("attendant")
    stock_operator = member("stock_operator")

    assert_equal "permissão necessária: coupons.write", assert_raises(D::AccessDenied) { create_coupon("OUTRO", actor: attendant) }.message
    assert_raises(D::AccessDenied) { uc(:end_price_agreement).call(attendant, @agreement.id, reason: "Sem permissão") }
    assert_raises(D::AccessDenied) { uc(:delete_coupon).call(attendant, @coupon.id) }
    assert_equal 9_200 + 15_000 - 920, reserve(attendant, @customer, @branch, window, [line(@chairs, 1)], mode: "request", coupon_code: "BEMVINDO10",
                                                                                                          fees: [catalog_fee(@fee)]).total.cents
    assert_raises(D::AccessDenied) { uc(:list_coupons).call(stock_operator) }
    assert_raises(D::AccessDenied) { uc(:list_price_agreements).call(stock_operator, @customer.id) }
    assert_equal ["ENTREGA"], uc(:list_fees).call(stock_operator).items.map(&:code)
    use = uc(:list_coupon_redemptions).call(member("finance"), @coupon.id).items.first

    assert_equal ["active", "Cliente Teste"], use.values_at(:state, :customer_name)
    assert_equal 2, owner_query("SELECT count(*) AS n FROM audit_events WHERE action LIKE 'coupon.%' OR action LIKE 'price_agreement.%'").first["n"].to_i
  end

  def test_credential_scopes_are_the_same_permissions_and_follow_the_creator_role
    reader = credential(%w[coupons.read])

    assert_equal 1, uc(:list_coupons).call(reader).total
    assert_equal "permissão necessária: coupons.write", assert_raises(D::AccessDenied) { create_coupon("VIAAPI", actor: reader) }.message
    assert_raises(D::AccessDenied) { uc(:list_fees).call(reader) }
    assert_raises(D::AccessDenied) { uc(:list_price_agreements).call(credential(%w[customers.read], name: "Antiga"), @customer.id) }
    admin = member("admin")
    writer = credential(%w[coupons.read coupons.write fees.write price_agreements.write], by: admin, name: "ERP")
    created = create_coupon("VIAAPI", actor: writer)

    assert_equal ["api", writer.credential_id], audit_events("coupon.created").last.values_at("actor_type", "actor_id")
    assert_equal "ERP", coupon_data(created.id)[:created_by_name]
    membership = uc(:list_members).call(@actor)[:members].find { |m| m["user_id"] == admin.user_id }
    uc(:change_member_role).call(@actor, membership_id: membership["id"], role: "attendant")

    assert_equal 2, uc(:list_coupons).call(writer).total, "leitura continua permitida ao papel atual do criador"
    assert_raises(D::AccessDenied) { create_coupon("DEPOIS", actor: writer) }
    assert_raises(D::AccessDenied) { create_fee("TAXA", "Taxa", 1_000, actor: writer) }
    assert_raises(D::AccessDenied) { create_agreement(@customer, 500, actor: writer, product: @chairs.id) }
  end

  def test_redemption_listing_hides_what_the_credential_cannot_read
    reservation = reserve(@actor, @customer, @branch, window, [line(@chairs, 1)], mode: "request", coupon_code: "BEMVINDO10")
    bare = uc(:list_coupon_redemptions).call(credential(%w[coupons.read]), @coupon.id).items.first

    assert_equal [nil, nil, nil, nil, "active", 920], [bare[:reservation_id], bare[:reservation_code], bare[:reservation_status],
                                                       bare[:customer_name], bare[:state], bare[:discount].cents]
    full = uc(:list_coupon_redemptions).call(credential(%w[coupons.read reservations.read customers.read], name: "Completa"), "BEMVINDO10")

    assert_equal [reservation.id, reservation.code, "requested", "Cliente Teste"],
                 full.items.first.values_at(:reservation_id, :reservation_code, :reservation_status, :customer_name)
  end

  def test_organizations_have_independent_codes_and_never_use_each_others_terms
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    foreign_customer = create_customer(other[:actor])
    foreign_product = create_product(other[:actor], sku: "CAD-B", tracking: "bulk", pricing: { "daily_cents" => 10_000 })
    book = lambda do |**extra|
      reserve(other[:actor], foreign_customer, other[:branch], window, [line(foreign_product, 1)], mode: "request", **extra)
    end

    assert_equal ["cupom inexistente"], error_fields { book.call(coupon_code: "BEMVINDO10") }["cupom"]
    assert_equal "tarifa não encontrada", assert_raises(D::NotFound) { book.call(fees: [catalog_fee(@fee)]) }.message
    own = create_coupon("BEMVINDO10", actor: other[:actor], value: 2_000)
    create_fee("ENTREGA", "Entrega da Beta", 20_000, actor: other[:actor])

    assert_equal([8_000, own.id], summary_of(book.call(coupon_code: "bemvindo10"), actor: other[:actor]).then { |s| [s["total_cents"], s["coupon"]["id"]] })
    assert_equal ["0 (sem limite)", "1 (sem limite)"], [usage("BEMVINDO10"), usage("BEMVINDO10", actor: other[:actor])]
    assert_equal [1_000, 15_000], [coupon_data("BEMVINDO10")[:coupon].value, uc(:get_fee).call(@actor, "ENTREGA")[:fee].default_amount.cents]
    assert_raises(D::NotFound) { uc(:get_coupon).call(other[:actor], @coupon.id) }
    assert_raises(D::NotFound) { uc(:update_fee).call(other[:actor], @fee.id, { name: "Invasão" }) }
    assert_raises(D::NotFound) { uc(:list_price_agreements).call(other[:actor], @customer.id) }
    missing = assert_raises(D::NotFound) { uc(:end_price_agreement).call(other[:actor], @agreement.id, reason: "Tentativa indevida") }

    assert_equal "condição negociada não encontrada", missing.message
    assert_raises(D::NotFound) { create_agreement(@customer, 500, actor: other[:actor]) }
    assert_equal "active", uc(:list_price_agreements).call(@actor, @customer.id).items.first[:status]
  end
end
