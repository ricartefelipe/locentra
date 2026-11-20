# frozen_string_literal: true

require_relative "../unit_helper"

class EntitiesTest < UnitTest
  R = Locentra::Domain::Reservations
  K = Locentra::Domain::Catalog
  C = Locentra::Domain::Customers
  I = Locentra::Domain::Identity
  O = Locentra::Domain::Organizations
  Money = Locentra::Domain::Money

  def reservation(status: "requested", hold: nil)
    R::Reservation.new(id: "r1", organization_id: "o1", branch_id: "b1", customer_id: "c1", code: "R-000001", status: status, source: "staff",
                       period: period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z"), hold_expires_at: hold, quote_id: nil, notes: nil,
                       total: Money.zero, deposit: Money.zero, version: 1)
  end

  def test_reservation_state_machine
    held = reservation.hold(t("2026-03-02T12:10:00Z"))

    assert held.hold_valid?(t("2026-03-02T12:09:59Z"))
    refute held.hold_valid?(t("2026-03-02T12:10:00Z")), "o instante de expiração pertence ao período expirado"
    assert_equal "confirmed", held.confirm(t("2026-03-02T12:00:00Z")).status
    assert_raises(Locentra::Domain::HoldExpired) { held.confirm(t("2026-03-02T12:10:00Z")) }
    assert_equal "expired", held.expire(t("2026-03-02T12:10:00Z")).status
    assert_raises(Locentra::Domain::InvariantViolation) { held.expire(t("2026-03-02T12:00:00Z")) }
    confirmed = held.confirm(t("2026-03-02T12:00:00Z"))

    assert_equal "in_progress", confirmed.start.status
    assert_equal "completed", confirmed.start.complete.status
    assert_raises(Locentra::Domain::InvalidTransition) { confirmed.start.cancel }
    assert_raises(Locentra::Domain::InvalidTransition) { reservation(status: "cancelled").transition("confirmed") }
    assert_equal 2, held.version
    assert_equal "Bloqueio temporário", held.status_label
  end

  def test_reschedule_and_extension_rules
    now = t("2026-03-02T12:00:00Z")
    confirmed = reservation(status: "confirmed")
    moved = confirmed.reschedule(period("2026-03-11T08:00:00Z", "2026-03-11T12:00:00Z"), now)

    assert_equal t("2026-03-11T08:00:00Z"), moved.period.starts_at
    assert_raises(Locentra::Domain::ValidationError) { confirmed.reschedule(period("2026-03-01T08:00:00Z", "2026-03-01T12:00:00Z"), now) }
    assert_raises(Locentra::Domain::InvalidTransition) { reservation(status: "in_progress").reschedule(moved.period, now) }
    assert_equal t("2026-03-10T14:00:00Z"), confirmed.extend_to(t("2026-03-10T14:00:00Z"), now).period.ends_at
    assert_raises(Locentra::Domain::ValidationError) { confirmed.extend_to(t("2026-03-10T11:00:00Z"), now) }
    assert_raises(Locentra::Domain::InvalidTransition) { reservation(status: "requested").extend_to(t("2026-03-10T14:00:00Z"), now) }
  end

  def test_reservation_rules
    lines = [R::Line.build(product_id: "00000000-0000-7000-8000-000000000001", quantity: "2"),
             R::Line.build(product_id: "00000000-0000-7000-8000-000000000001", quantity: 3)]

    assert_equal [5], R::Rules.normalize_lines(lines).map(&:quantity)
    assert_raises(Locentra::Domain::ValidationError) { R::Rules.normalize_lines([]) }
    assert_raises(Locentra::Domain::ValidationError) { R::Line.build(product_id: "x", quantity: 1) }
    assert_raises(Locentra::Domain::ValidationError) { R::Line.build(product_id: "00000000-0000-7000-8000-000000000001", quantity: "dois") }
    assert_raises(Locentra::Domain::ValidationError) { R::Line.build(product_id: "00000000-0000-7000-8000-000000000001", quantity: 0) }
    assert_equal 30, R::Rules.hold_minutes!("30")
    assert_raises(Locentra::Domain::ValidationError) { R::Rules.hold_minutes!("2") }
    assert_raises(Locentra::Domain::ValidationError) { R::Rules.hold_minutes!("abc") }
  end

  def test_asset_state_machine_preserves_history_semantics
    asset = K::Asset.build(id: "a1", organization_id: "o1", product_id: "p1", branch_id: "b1", tag: "cam-01")

    assert_equal "CAM-01", asset.tag
    maintenance = asset.transition_to("in_maintenance", unavailable_until: t("2026-03-05T00:00:00Z"))

    assert_predicate maintenance, :operationally_blocked?
    assert_equal t("2026-03-05T00:00:00Z"), maintenance.unavailable_until
    assert_nil maintenance.transition_to("available").unavailable_until
    retired = asset.transition_to("retired")

    refute_predicate retired, :allocatable?
    assert_raises(Locentra::Domain::InvalidTransition) { retired.transition_to("available") }
    assert_raises(Locentra::Domain::ValidationError) { K::Asset.build(id: "a", organization_id: "o", product_id: "p", branch_id: "b", tag: "não válido") }
    assert_raises(Locentra::Domain::ValidationError) { K::Asset.build(id: "a", organization_id: "o", product_id: "p", branch_id: "b", tag: "X1", condition: "ótimo") }
    assert_equal "Disponível", asset.status_label
    assert_equal "Bom", asset.condition_label
  end

  def test_product_validation_and_blocked_period
    product = K::Product.build(id: "p", organization_id: "o", sku: "cam-1", name: "Câmera", tracking: "serialized", buffer_before_minutes: "30",
                               buffer_after_minutes: 60)

    assert_equal period("2026-03-10T07:30:00Z", "2026-03-10T13:00:00Z"), product.blocked_period(period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z"))
    assert_predicate product, :serialized?
    assert_equal "Ativo individual", product.tracking_label
    assert_raises(Locentra::Domain::ValidationError) { K::Product.build(id: "p", organization_id: "o", sku: "x", name: "Item", tracking: "outro") }
    assert_raises(Locentra::Domain::ValidationError) { K::Product.build(id: "p", organization_id: "o", sku: "x", name: "Item", tracking: "bulk", buffer_after_minutes: "-5") }
    assert_raises(Locentra::Domain::ValidationError) { K::Product.build(id: "p", organization_id: "o", sku: "x", name: "Item", tracking: "bulk", deposit: Money.new(-1)) }
    pool = K::StockPool.new(id: "s", organization_id: "o", product_id: "p", branch_id: "b", total_quantity: 3)

    assert_equal 5, pool.adjust(2).total_quantity
    assert_raises(Locentra::Domain::ValidationError) { pool.adjust(-4) }
  end

  def test_brazilian_documents
    assert C::Document.valid_cpf?("529.982.247-25")
    refute C::Document.valid_cpf?("111.111.111-11")
    refute C::Document.valid_cpf?("529.982.247-24")
    assert C::Document.valid_cnpj?("11.222.333/0001-81")
    refute C::Document.valid_cnpj?("11.222.333/0001-80")
    assert_equal "529.982.247-25", C::Document.format("52998224725")
    assert_equal "11.222.333/0001-81", C::Document.format("11222333000181")
    customer = C::Customer.build(id: "c", organization_id: "o", kind: "company", name: "  Produtora   X ", document: "11222333000181", email: " A@B.COM ")

    assert_equal "Produtora X", customer.name
    assert_equal "a@b.com", customer.email
    assert_raises(Locentra::Domain::ValidationError) { C::Customer.build(id: "c", organization_id: "o", kind: "individual", name: "Ana", document: "11222333000181") }
    assert_raises(Locentra::Domain::ValidationError) { C::Customer.build(id: "c", organization_id: "o", kind: "alien", name: "Ana", document: "1") }
    assert_raises(Locentra::Domain::ValidationError) do
      C::Contact.build(id: "x", organization_id: "o", customer_id: "c", name: "Retirante", authorized_pickup: true, document: "123")
    end
    assert_raises(Locentra::Domain::ValidationError) { C::Address.build(id: "x", organization_id: "o", customer_id: "c", street: "Rua", city: "SP", state: "São") }
  end

  def test_permissions_matrix_and_password_policy
    assert I.permitted?("owner", "members.manage")
    refute I.permitted?("manager", "members.manage")
    refute I.permitted?("auditor", "reservations.write")
    assert I.permitted?("auditor", "audit.read")
    refute I.permitted?("attendant", "finance.refund")
    assert_raises(ArgumentError) { I.permitted?("owner", "inexistente") }
    assert_includes I.assignable_roles("owner"), "admin"
    refute_includes I.assignable_roles("admin"), "admin"
    assert_empty I.assignable_roles("manager")
    assert_equal 500, I.discount_limit_bps("attendant")
    assert_equal 0, I.discount_limit_bps("auditor")
    assert_raises(Locentra::Domain::ValidationError) { I.validate_permissions!(["root.all"]) }
    assert_equal "senha-muito-segura", I::PasswordPolicy.validate!("senha-muito-segura")
    assert_raises(Locentra::Domain::ValidationError) { I::PasswordPolicy.validate!("curta") }
    error = assert_raises(Locentra::Domain::ValidationError) { I::PasswordPolicy.validate!("ç" * 40) }

    assert_match(/72 bytes/, error.message, "senha acima do limite do bcrypt é rejeitada, não truncada")
    assert_equal "a@b.co", I::Email.normalize(" A@B.CO ")
    assert_raises(Locentra::Domain::ValidationError) { I::Email.normalize("sem-arroba") }
  end

  def test_organization_and_cancellation_policy
    org = O::Organization.build(id: "o", name: "Áudio & Vídeo Ltda.")

    assert_equal "audio-video-ltda", org.slug
    assert_equal 30, org.hold_minutes
    assert_raises(Locentra::Domain::ValidationError) { O::Organization.build(id: "o", name: "Org", timezone: "Lua/Base") }
    assert_raises(Locentra::Domain::ValidationError) { O::Branch.build(id: "b", organization_id: "o", name: "Filial", code: "código inválido") }
    policy = O::CancellationPolicy::DEFAULT
    start = t("2026-03-10T12:00:00Z")

    assert_equal 0, O::CancellationPolicy.fee_bps(policy, starts_at: start, now: start - (80 * 3600))
    assert_equal 3000, O::CancellationPolicy.fee_bps(policy, starts_at: start, now: start - (30 * 3600))
    assert_equal 10_000, O::CancellationPolicy.fee_bps(policy, starts_at: start, now: start - 3600)
    assert_equal 10_000, O::CancellationPolicy.fee_bps(policy, starts_at: start, now: start + 3600)
  end
end
