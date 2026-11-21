# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/organization_settings_support"

# Leitura da organização pela API v1 (Rack::Lint): formato completo com configurações efetivas e filiais
# (inclusive inativas), escopo `organization.read`, tenant determinado pelo token e a política congelada
# no detalhe da reserva.
class OrganizationApiTest < HttpTest
  include OrganizationSettingsSupport

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @token = token(%w[organization.read reservations.read])
  end

  def token(scopes) = uc(:create_credential).call(@actor, name: "ERP #{scopes.size}", scopes: scopes, expires_in_days: 30)["token"]
  def auth(value = @token) = { "HTTP_AUTHORIZATION" => "Bearer #{value}" }

  def test_organization_with_settings_and_branches
    north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE", address: "Av. Norte, 100")
    uc(:set_branch_active).call(@actor, north.id, active: false)
    change_settings(hold_minutes: "45", cancellation_rows: [%w[48 0], ["0", "12,5"]])
    get "/api/v1/organization", {}, auth

    assert_equal 200, last_response.status
    body = json_body

    assert_equal({ "id" => @org[:organization_id], "name" => "Locadora Alfa", "slug" => "locadora-alfa", "time_zone" => "America/Sao_Paulo",
                   "time_zone_label" => "Brasília (SP, RJ, MG, ES, PR, SC, RS, GO, DF)", "status" => "active", "lock_version" => 2 },
                 body.except("settings", "branches"))
    assert_equal({ "hold_minutes" => 45, "hold_minutes_default" => false, "hold_minutes_limits" => { "min" => 5, "max" => 1440 },
                   "cancellation_policy" => { "tiers" => [{ "min_hours_before" => 48, "fee_bps" => 0 }, { "min_hours_before" => 0, "fee_bps" => 1250 }] },
                   "cancellation_policy_default" => false,
                   "cancellation_terms" => ["48 h ou mais antes do início: multa de 0% do valor contratado",
                                            "menos de 48 h antes do início (ou após o início): multa de 12,5% do valor contratado"] }, body["settings"])
    branches = body["branches"].sort_by { |b| b["code"] }.map { |b| [b["code"], b["active"], b["deactivated_at"]] }

    assert_equal [["MATRIZ", true, nil], ["NORTE", false, "2026-03-02T12:00:00Z"]], branches
    assert_equal %w[active address code deactivated_at id name], body["branches"].first.keys.sort
  end

  def test_defaults_are_reported_by_value
    change_settings(hold_minutes: "30", name: "Locadora Alfa Eventos")
    get "/api/v1/organization", {}, auth

    assert_equal [true, true, "Locadora Alfa Eventos"],
                 [json_body.dig("settings", "hold_minutes_default"), json_body.dig("settings", "cancellation_policy_default"), json_body["name"]]
  end

  def test_scope_is_required_and_the_tenant_comes_from_the_token
    get "/api/v1/organization", {}, auth(token(%w[reservations.read]))

    assert_equal 403, last_response.status
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    beta_token = uc(:create_credential).call(beta[:actor], name: "ERP Beta", scopes: %w[organization.read], expires_in_days: 30)["token"]
    get "/api/v1/organization", { "organization_id" => @org[:organization_id] }, auth(beta_token)

    assert_equal 200, last_response.status
    assert_equal [beta[:organization_id], "Locadora Beta"], [json_body["id"], json_body["name"]]
    get "/api/v1/organization"

    assert_equal 401, last_response.status
  end

  def test_reservation_detail_includes_the_registered_policy
    customer = create_customer(@actor)
    chairs = create_product(@actor, sku: "CAD-API", tracking: "bulk")
    stock(@actor, chairs, @org[:branch], 5)
    change_settings(cancellation_rows: [%w[0 40]])
    reservation = reserve(@actor, customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(chairs, 1)])
    change_settings(cancellation_rows: [%w[0 80]])
    get "/api/v1/reservations/#{reservation.id}", {}, auth

    assert_equal 200, last_response.status
    assert_equal({ "tiers" => [{ "min_hours_before" => 0, "fee_bps" => 4000 }] }, json_body["cancellation_policy"])
  end
end
