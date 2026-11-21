# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/commercial_terms_support"

# Base dos testes da API v1 de condições comerciais: organização com cliente e câmera (três ativos),
# credencial com todos os escopos usados e atalhos de requisição com Idempotency-Key.
class CommercialTermsApiTestCase < HttpTest
  include CommercialTermsSupport

  SCOPES = %w[coupons.read coupons.write fees.read fees.write fees.override price_agreements.read price_agreements.write
              reservations.read reservations.write reservations.cancel customers.read catalog.read].freeze

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Produtora Horizonte")
    @camera = create_product(@actor, sku: "CAM-API", name: "Câmera FX", tracking: "serialized", pricing: { "daily_cents" => 45_000 })
    register_assets(@actor, @camera, @branch, 3)
    @sequence = 0
    @token = token(SCOPES)
  end

  def token(scopes, actor: @actor)
    uc(:create_credential).call(actor, name: "Integração #{@sequence += 1}", scopes: scopes, expires_in_days: 30)["token"]
  end

  def next_key = "chave-teste-#{@sequence += 1}"

  def headers(token, key = nil)
    base = { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "application/json" }
    key ? base.merge("HTTP_IDEMPOTENCY_KEY" => key) : base
  end

  # Requisições que conferem o status esperado e devolvem o corpo JSON. `key: nil` envia a mutação sem
  # Idempotency-Key.
  def get!(status, path, params = {}, token: @token)
    get "/api/v1#{path}", params, headers(token)
    checked(status, "GET #{path}")
  end

  def post!(status, path, body = {}, token: @token, key: next_key)
    post "/api/v1#{path}", JSON.generate(body), headers(token, key)
    checked(status, "POST #{path} #{body.inspect}")
  end

  def patch!(status, path, body = {}, token: @token, key: next_key)
    patch "/api/v1#{path}", JSON.generate(body), headers(token, key)
    checked(status, "PATCH #{path} #{body.inspect}")
  end

  def checked(status, context)
    assert_equal status, last_response.status, "#{context}: #{last_response.body[0, 600]}"
    json_body
  end

  def error_code = json_body["error"]["code"]
  def error_message = json_body["error"]["message"]
  def fields = json_body["error"]["details"]["fields"]
  def codes = json_body["data"].map { |row| row["code"] }

  def audit_count(action) = audit_events(action).size

  def reservation_payload(day: 10, **extra)
    { "customer_id" => @customer.id, "branch_id" => @branch.id, "starts_at" => format("2026-03-%02dT12:00:00Z", day),
      "ends_at" => format("2026-03-%02dT12:00:00Z", day + 2), "items" => [{ "product_id" => @camera.id, "quantity" => 1 }],
      "mode" => "confirm" }.merge(extra.transform_keys(&:to_s))
  end
end
