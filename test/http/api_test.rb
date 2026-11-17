# frozen_string_literal: true

require_relative "http_helper"

class ApiTest < HttpTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-API", tracking: "serialized")
    register_assets(@actor, @camera, @org[:branch], 1)
    @token = uc(:create_credential).call(@actor, name: "ERP", scopes: %w[reservations.read reservations.write availability.read customers.read],
                                                 expires_in_days: 30)["token"]
  end

  def auth(token = @token) = { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "application/json" }

  def reservation_payload(starts = "2026-03-10T08:00:00Z", ends = "2026-03-10T12:00:00Z")
    { "customer_id" => @customer.id, "branch_id" => @org[:branch].id, "starts_at" => starts, "ends_at" => ends,
      "items" => [{ "product_id" => @camera.id, "quantity" => 1 }], "mode" => "confirm" }
  end

  def test_requires_valid_bearer_credential
    get "/api/v1/customers", {}, { "HTTP_AUTHORIZATION" => "Bearer lcn_invalido" }

    assert_equal 401, last_response.status
    assert_equal "unauthenticated", json_body["error"]["code"]
    assert json_body["error"]["request_id"]
  end

  def test_availability_and_listing
    get "/api/v1/availability", { "branch_id" => @org[:branch].id, "starts_at" => "2026-03-10T08:00:00Z", "ends_at" => "2026-03-10T10:00:00Z" }, auth

    assert_equal 200, last_response.status
    assert_equal 1, json_body["data"].find { |r| r["sku"] == "CAM-API" }["available"]
    get "/api/v1/customers", { "limit" => "500" }, auth

    assert_equal 422, last_response.status
  end

  def test_idempotent_reservation_creation_replays_and_detects_reuse
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth.merge("HTTP_IDEMPOTENCY_KEY" => "pedido-0001")

    assert_equal 201, last_response.status, last_response.body
    first = json_body
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth.merge("HTTP_IDEMPOTENCY_KEY" => "pedido-0001")

    assert_equal 201, last_response.status
    assert_equal "true", last_response.headers["idempotent-replayed"]
    assert_equal first["id"], json_body["id"]
    post "/api/v1/reservations", JSON.generate(reservation_payload("2026-03-11T08:00:00Z", "2026-03-11T10:00:00Z")),
         auth.merge("HTTP_IDEMPOTENCY_KEY" => "pedido-0001")

    assert_equal 409, last_response.status
    assert_equal "idempotency_key_reused", json_body["error"]["code"]
    assert_equal 1, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i
  end

  def test_missing_idempotency_key_and_unavailable_conflict
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth

    assert_equal 422, last_response.status
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth.merge("HTTP_IDEMPOTENCY_KEY" => "pedido-a-1")
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth.merge("HTTP_IDEMPOTENCY_KEY" => "pedido-b-2")

    assert_equal 409, last_response.status
    assert_equal "unavailable", json_body["error"]["code"]
    assert_equal "CAM-API", json_body["error"]["details"]["shortages"].first["sku"]
  end

  def test_scopes_limit_operations
    limited = uc(:create_credential).call(@actor, name: "Somente leitura", scopes: %w[customers.read], expires_in_days: 1)["token"]
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth(limited).merge("HTTP_IDEMPOTENCY_KEY" => "pedido-c-3")

    assert_equal 403, last_response.status
  end

  def test_revoked_credential_stops_working
    credential = uc(:list_credentials).call(@actor).first
    uc(:revoke_credential).call(@actor, credential["id"])
    get "/api/v1/customers", {}, auth

    assert_equal 401, last_response.status
  end

  def test_malformed_json_and_depth_limit
    post "/api/v1/customers", "{invalido", auth

    assert_equal 400, last_response.status
    deep = "#{'{"a":' * 20}1#{"}" * 20}"
    post "/api/v1/customers", deep, auth

    assert_equal 400, last_response.status
  end

  def test_openapi_documents_every_api_route
    get "/api/v1/openapi.yaml"

    assert_equal 200, last_response.status
    spec = YAML.safe_load(last_response.body)
    routes = Locentra::Interfaces::HTTP::App.new(@system).router.routes.select { |r| r.pattern.start_with?("/api/v1/") && r.pattern != "/api/v1/openapi.yaml" }
    routes.each do |route|
      path = route.pattern.sub("/api/v1", "").gsub(/:([a-z_]+)/, '{\1}')

      assert spec["paths"].key?(path), "rota não documentada: #{path}"
      assert spec["paths"][path].key?(route.verb.downcase), "verbo não documentado: #{route.verb} #{path}"
    end
  end
end
