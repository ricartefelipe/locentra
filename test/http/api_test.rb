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

  def test_cli_credential_is_refused_by_the_api
    cli = uc(:create_credential).call(@actor, name: "Rotina", scopes: %w[customers.read], kind: "cli", expires_in_days: 1)
    get "/api/v1/customers", {}, auth(cli["token"])

    assert_equal 401, last_response.status
    assert_nil owner_query("SELECT last_used_at FROM api_credentials WHERE id = $1", [cli["id"]], tenant: @org[:organization_id]).first["last_used_at"]
    get "/api/v1/customers", {}, auth

    assert_equal 200, last_response.status
  end

  def test_availability_and_listing
    get "/api/v1/availability", { "branch_id" => @org[:branch].id, "starts_at" => "2026-03-10T08:00:00Z", "ends_at" => "2026-03-10T10:00:00Z" }, auth

    assert_equal 200, last_response.status
    assert_equal 1, json_body["data"].find { |r| r["sku"] == "CAM-API" }["available"]
    get "/api/v1/customers", { "limit" => "500" }, auth

    assert_equal 422, last_response.status
  end

  def test_reservation_detail_includes_items_allocations_and_frozen_pricing
    post "/api/v1/reservations", JSON.generate(reservation_payload), auth.merge("HTTP_IDEMPOTENCY_KEY" => "pedido-detalhe-1")
    id = json_body["id"]
    get "/api/v1/reservations/#{id}", {}, auth

    assert_equal 200, last_response.status, last_response.body
    body = json_body

    assert_equal id, body["id"]
    assert_equal([@camera.id], body["items"].map { |i| i["product_id"] })
    assert_equal 1, body["allocations"]["assets"].size
    assert body["pricing"].key?("total_cents")
    assert_kind_of Array, body["adjustments"]
    other = create_organization(name: "Outra Locadora", email: "outra@example.test")
    chairs = create_product(other[:actor], sku: "CAD-OUT", tracking: "bulk")
    stock(other[:actor], chairs, other[:branch], 2)
    foreign = reserve(other[:actor], create_customer(other[:actor]), other[:branch],
                      period("2026-03-12T08:00:00Z", "2026-03-12T10:00:00Z"), [line(chairs, 1)])
    get "/api/v1/reservations/#{foreign.id}", {}, auth

    assert_equal 404, last_response.status, "reserva de outra organização não é revelada"
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

  # A composição com a transação de idempotência não dispensa as verificações de vínculo: reserva com
  # contrato em aberto só é cancelada pelo contrato, que aplica a política de cancelamento.
  def test_cancel_refuses_reservation_with_open_contract
    token = uc(:create_credential).call(@actor, name: "Cancelamentos", scopes: %w[reservations.cancel], expires_in_days: 30)["token"]
    free = reserve(@actor, @customer, @org[:branch], period("2026-03-20T08:00:00Z", "2026-03-21T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)],
                          mode: "confirm")
    contract = uc(:issue_contract).call(@actor, reservation.id)
    @clock.travel_to(t("2026-03-09T20:00:00Z"))
    post "/api/v1/reservations/#{reservation.id}/cancel", JSON.generate("reason" => "desistência"),
         auth(token).merge("HTTP_IDEMPOTENCY_KEY" => "cancelamento-0001")

    assert_equal 409, last_response.status, last_response.body
    assert_equal "contract_amendment_required", json_body["error"]["code"]
    assert_includes json_body["error"]["message"], contract.code
    assert_equal "confirmed", uc(:get_reservation).call(@actor, reservation.id)[:reservation].status
    assert_equal "issued", uc(:get_contract).call(@actor, contract.id)[:contract].status
    assert_empty owner_query("SELECT id FROM reservation_adjustments")
    post "/api/v1/reservations/#{free.id}/cancel", JSON.generate("reason" => "desistência"),
         auth(token).merge("HTTP_IDEMPOTENCY_KEY" => "cancelamento-0002")

    assert_equal 200, last_response.status, last_response.body
    assert_equal "cancelled", json_body["status"]
  end

  # O bloqueio temporário de um orçamento é confirmado somente pela conversão do orçamento aprovado.
  def test_confirm_refuses_the_hold_of_a_quote
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @org[:branch].id, lines: [line(@camera, 1)],
                                             period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), valid_until: t("2026-03-06T00:00:00Z"),
                                             hold_policy: "hold_on_send", hold_minutes: 600 })
    hold_id = uc(:send_quote).call(@actor, quote.id).hold_reservation_id
    post "/api/v1/reservations/#{hold_id}/confirm", "{}", auth.merge("HTTP_IDEMPOTENCY_KEY" => "confirmacao-0001")

    assert_equal 409, last_response.status, last_response.body
    assert_equal "quote_hold", json_body["error"]["code"]
    assert_equal "held", uc(:get_reservation).call(@actor, hold_id)[:reservation].status
  end

  def test_revoked_credential_stops_working
    credential = uc(:list_credentials).call(@actor).first
    uc(:revoke_credential).call(@actor, credential["id"])
    get "/api/v1/customers", {}, auth

    assert_equal 401, last_response.status
  end

  def test_credentials_of_a_suspended_organization_stop_working
    owner_query("UPDATE organizations SET status = 'suspended' WHERE id = $1", [@org[:organization_id]], tenant: @org[:organization_id])
    get "/api/v1/customers", {}, auth

    assert_equal 401, last_response.status
    owner_query("UPDATE organizations SET status = 'active' WHERE id = $1", [@org[:organization_id]], tenant: @org[:organization_id])
    get "/api/v1/customers", {}, auth

    assert_equal 200, last_response.status
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

  def test_confirming_an_expired_hold_records_the_expiration
    hold = reserve(@actor, @customer, @org[:branch], period("2026-03-25T08:00:00Z", "2026-03-25T12:00:00Z"), [line(@camera, 1)], hold_minutes: 5)
    @clock.advance(6 * 60)
    post "/api/v1/reservations/#{hold.id}/confirm", "{}", auth.merge("HTTP_IDEMPOTENCY_KEY" => "confirmar-vencido-1")

    assert_equal 409, last_response.status
    assert_equal "hold_expired", json_body["error"]["code"]
    assert_equal "expired", uc(:get_reservation).call(@actor, hold.id)[:reservation].status
    assert_equal 1, owner_query("SELECT count(*) AS n FROM outbox_events WHERE aggregate_id = $1 AND event_type = 'reservation.expired'",
                                [hold.id]).first["n"].to_i
  end
end
