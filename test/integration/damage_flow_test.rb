# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/operations_support"

# Avarias e faltas: evidências, aprovação da cobrança, baixa de itens faltantes e alertas para
# reservas futuras que perdem o item.
class DamageFlowTest < DatabaseTest
  include OperationsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-OP", tracking: "serialized", replacement_cost: D::Money.new(500_000), buffer_after_minutes: 60)
    @cameras = register_assets(@actor, @camera, @branch, 3)
    @chairs = create_product(@actor, sku: "CAD-OP", tracking: "bulk", pricing: { "daily_cents" => 500 }, replacement_cost: D::Money.new(8_000))
    stock(@actor, @chairs, @branch, 10)
  end

  def test_damage_charge_requires_evidence_and_permission
    reservation = confirmed([line(@camera, 1)])
    pick_up(reservation)
    return_all(reservation, outcome: "damaged", notes: "carcaça amassada")
    report = uc(:list_damage_reports).call(@actor).first
    revised = uc(:revise_damage_report).call(@actor, report["id"], description: "carcaça amassada e lente riscada", severity: "severe",
                                                                   estimated_cost: D::Money.new(35_000))

    assert_equal ["severe", 35_000], [revised.severity, revised.estimated_cost.cents]
    error = assert_raises(D::ValidationError) { uc(:approve_damage_charge).call(@actor, report["id"]) }
    assert_includes error.errors.keys, "evidencias"
    attendant = member("atendente@alfa.test", "attendant")
    uc(:upload_attachment).call(@actor, owner_type: "damage_report", owner_id: report["id"], filename: "foto.png",
                                        bytes: "\x89PNG\r\n\x1A\nimagem".b)

    assert_raises(D::AccessDenied) { uc(:approve_damage_charge).call(attendant, report["id"]) }
    approved = uc(:approve_damage_charge).call(@actor, report["id"], notes: "orçamento da assistência")

    assert_equal "approved", approved.status
    charge = owner_query("SELECT kind, amount_cents, reservation_item_id FROM reservation_adjustments WHERE kind = 'damage'").first

    assert_equal 35_000, charge["amount_cents"].to_i
    refute_nil charge["reservation_item_id"]
    assert_raises(D::InvalidTransition) { uc(:approve_damage_charge).call(@actor, report["id"]) }
    assert_raises(D::InvalidTransition) do
      uc(:revise_damage_report).call(@actor, report["id"], description: "nova", severity: "minor", estimated_cost: D::Money.zero)
    end
    data = uc(:get_damage_report).call(@actor, report["id"])

    assert_equal 1, data[:attachments].size
    assert_equal reservation.code, data[:labels]["reservation_code"]
  end

  def test_missing_items_write_off_and_alert_uncovered_future_reservations
    single = create_product(@actor, sku: "GER-OP", tracking: "serialized", replacement_cost: D::Money.new(200_000))
    generator = register_assets(@actor, single, @branch, 1).first
    reservation = confirmed([line(single, 1), line(@chairs, 6)])
    other = create_customer(@actor, name: "Outro Cliente", document: "11144477735")
    future = confirmed([line(single, 1), line(@chairs, 6)], after_rental, customer: other)
    pick_up(reservation)
    return_all(reservation, outcome: "missing", notes: "cliente não devolveu")

    assert_equal "lost", asset_status(generator.id)
    assert_equal 4, count("SELECT total_quantity FROM stock_pools WHERE product_id = $1", [@chairs.id])
    assert_equal(-6, count("SELECT quantity_delta FROM stock_movements WHERE kind = 'loss'"))
    alerts = owner_query("SELECT kind, reservation_id, related_reservation_id, asset_id, stock_pool_id FROM reservation_alerts")

    assert_equal 2, alerts.size, "um alerta para o ativo extraviado e outro para o estoque reduzido"
    assert(alerts.all? { |a| a["kind"] == "asset_unavailable" && a["reservation_id"] == future.id && a["related_reservation_id"] == reservation.id })
    assert_equal([generator.id], alerts.filter_map { |a| a["asset_id"] })
    reports = uc(:list_damage_reports).call(@actor)

    assert_equal(%w[missing missing], reports.map { |r| r["kind"] })
    assert_equal [48_000, 200_000], reports.map { |r| r["estimated_cost_cents"].to_i }.sort
    assert_equal "completed", reservation_status(reservation)
    assert_equal "confirmed", reservation_status(future), "nenhuma reserva é cancelada automaticamente"
  end

  def test_missing_asset_relocates_future_reservation_to_free_unit
    reservation = confirmed([line(@camera, 1)])
    lost_id = owner_query("SELECT asset_id FROM asset_allocations WHERE reservation_id = $1", [reservation.id]).first["asset_id"]
    future = confirmed([line(@camera, 1)], after_rental)
    owner_query("UPDATE asset_allocations SET asset_id = $1 WHERE reservation_id = $2", [lost_id, future.id])
    pick_up(reservation)
    return_all(reservation, outcome: "missing", notes: "extraviado")

    moved = owner_query("SELECT asset_id FROM asset_allocations WHERE reservation_id = $1 AND active", [future.id]).first["asset_id"]

    refute_equal lost_id, moved
    assert_equal 0, count("SELECT count(*) FROM reservation_alerts")
  end

  def test_manual_damage_report_from_inspection
    reservation = confirmed([line(@chairs, 2)])
    pick_up(reservation)
    return_all(reservation, requires_inspection: true)
    return_line = owner_query("SELECT id FROM return_lines").first["id"]
    report = uc(:create_damage_report).call(@actor, return_line_id: return_line, description: "estofado rasgado", severity: "minor",
                                                    estimated_cost: D::Money.new(4_000))

    assert_equal "AV-000001", report.code
    assert_raises(D::Conflict) do
      uc(:create_damage_report).call(@actor, return_line_id: return_line, description: "outro registro", severity: "minor", estimated_cost: D::Money.zero)
    end
    dismissed = uc(:dismiss_damage_report).call(@actor, report.id, reason: "desgaste natural")

    assert_equal "dismissed", dismissed.status
    assert_equal 1, uc(:list_damage_reports).call(@actor, filter: "decided").size
    assert_raises(D::ValidationError) { uc(:list_damage_reports).call(@actor, filter: "x") }
  end

  private

  def member(email, role)
    invite = uc(:invite_member).call(@actor, email: email, role: role)
    token = "#{@org[:organization_id]}.convite-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    joined = uc(:accept_invitation).call(token: token, name: "Membro #{role}", password: "senha-muito-segura-7")
    A::Actor.user(user_id: joined[:user_id], organization_id: @org[:organization_id], role: role)
  end
end
