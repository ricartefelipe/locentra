# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/operations_support"
require_relative "../support/openapi_contract"

# Base dos testes da API v1 ampliada (orçamentos, contratos, operação e configurações): organização Alfa
# com cliente, câmera serializada (três ativos) e cadeiras em estoque, organização Beta para isolamento,
# credenciais por escopo e atalhos de requisição com Idempotency-Key automática. Toda resposta pode ser
# conferida contra o OpenAPI com `assert_conforms`.
class ApiV1TestCase < HttpTest
  include OperationsSupport
  include OpenApiContract

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Produtora Horizonte")
    @camera = create_product(@actor, sku: "CAM-API", name: "Câmera FX", tracking: "serialized", pricing: { "daily_cents" => 45_000 })
    @cameras = register_assets(@actor, @camera, @branch, 3)
    @chairs = create_product(@actor, sku: "CAD-API", name: "Cadeira", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 20)
    @beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    @sequence = 0
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
    assert_equal status, last_response.status, "#{context}: #{last_response.body[0, 800]}"
    return nil unless last_response.content_type.to_s.start_with?("application/json")

    json_body
  end

  def error_code = json_body["error"]["code"]
  def error_message = json_body["error"]["message"]
  def fields = json_body["error"]["details"]["fields"]
  def replayed? = last_response.headers["idempotent-replayed"] == "true"
  def location = last_response.headers["location"]

  # Erro conferido pelo código e pelo schema Error do OpenAPI.
  def assert_error(code)
    assert_equal code, error_code, last_response.body[0, 600]
    assert_conforms json_body, "Error"
  end

  def audit_count(action, org: @org)
    owner_query("SELECT count(*) AS n FROM audit_events WHERE action = $1", [action], tenant: org[:organization_id]).first["n"].to_i
  end

  def audit_details(action, org: @org)
    owner_query("SELECT details FROM audit_events WHERE action = $1 ORDER BY occurred_at, id", [action], tenant: org[:organization_id])
      .map { |row| JSON.parse(row["details"]) }
  end

  # Mutação repetida com a mesma chave: o replay devolve o mesmo corpo com `Idempotent-Replayed`; com
  # conteúdo diferente, 409 `idempotency_key_reused`; sem a chave, 422.
  def assert_idempotent(path, body, status, changed_body: { "outro" => "conteúdo" }, token: @token)
    key = next_key
    first = post!(status, path, body, token: token, key: key)
    @idempotent_location = location

    refute_predicate self, :replayed?
    assert_equal first, post!(status, path, body, token: token, key: key)
    assert_predicate self, :replayed?
    post!(409, path, changed_body, token: token, key: key)

    assert_error "idempotency_key_reused"
    post!(422, path, body, token: token, key: nil)

    assert_equal ["Idempotency-Key"], fields.keys
    first
  end

  def iso(text) = Time.iso8601(text).utc.iso8601

  # Recursos da Beta para conferir o isolamento: o mesmo identificador responde 404 na Alfa.
  def beta_customer = @beta_customer ||= create_customer(@beta[:actor], name: "Cliente Beta", document: "11144477735")

  def beta_reservation(window = rental_period)
    chairs = @beta_chairs ||= create_product(@beta[:actor], sku: "CAD-BETA", tracking: "bulk").tap { |p| stock(@beta[:actor], p, @beta[:branch], 10) }
    reserve(@beta[:actor], beta_customer, @beta[:branch], window, [line(chairs, 1)], mode: "confirm")
  end
end
