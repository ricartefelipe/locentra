# frozen_string_literal: true

require_relative "http_helper"

# Entradas fora do formato esperado respondem 4xx no campo certo (nunca 500), limites de corpo e de
# upload, e atributos do cookie de sessão e HSTS quando a aplicação usa HTTPS.
class InputValidationTest < HttpTest
  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @customer = create_customer(@org[:actor])
    @camera = create_product(@org[:actor], sku: "CAM-IN", tracking: "serialized")
    register_assets(@org[:actor], @camera, @org[:branch], 1)
  end

  def reservation_form(extra)
    { "cliente_id" => @customer.id, "filial_id" => @org[:branch].id, "inicio" => "2026-03-10T09:00", "fim" => "2026-03-11T09:00",
      "produto" => [@camera.id], "quantidade" => ["1"], "modo" => "hold" }.merge(extra)
  end

  def product_form(extra)
    { "sku" => "NOVO-#{extra.hash.abs}", "nome" => "Produto", "rastreamento" => "bulk", "preco_diaria" => "10,00",
      "modalidade_diaria" => "rolling_24h" }.merge(extra)
  end

  def test_percentages_accept_two_decimals_and_refuse_infinity_nan_and_extra_digits
    login("dona@alfa.test")
    %w[Infinity NaN -Infinity 1e2 12.345 abc].each do |value|
      get "/reservas/nova"
      post_form "/reservas", reservation_form("desconto" => value)

      assert_equal 422, last_response.status, value
      assert_includes last_response.body, "percentual inválido", value
    end
    get "/reservas/nova"
    post_form "/reservas", reservation_form("desconto" => "2,5")

    assert_equal 303, last_response.status
    id = last_response.location[%r{/reservas/(.+)}, 1]

    assert_equal 250, owner_query("SELECT pricing->>'manual_discount_bps' AS bps FROM reservations WHERE id = $1", [id]).first["bps"].to_i
    get "/produtos/novo"
    post_form "/produtos", product_form("faixa_minimo" => ["5"], "faixa_desconto" => ["NaN"])

    assert_equal 422, last_response.status
    assert_includes last_response.body, "percentual inválido"
  end

  def test_invalid_money_is_reported_on_the_field_that_sent_it
    login("dona@alfa.test")
    get "/produtos/novo"
    post_form "/produtos", product_form("custo_reposicao" => "12,34,5")

    assert_equal 422, last_response.status
    assert_match(/id="custo_reposicao"[^>]*aria-invalid="true" aria-describedby="erro-custo_reposicao"/, last_response.body)
    assert_includes last_response.body, %(<p class="field-error" id="erro-custo_reposicao" role="alert">formato monetário inválido</p>)
    refute_includes last_response.body, %(id="erro-valor")
    get "/produtos/novo"
    post_form "/produtos", product_form("preco_diaria" => "abc")

    assert_match(/id="preco_diaria"[^>]*aria-invalid="true"/, last_response.body)
    view = Locentra::Interfaces::HTTP::ViewContext.new(nil, nil, {})

    assert_equal ' aria-invalid="true" aria-describedby="ajuda-validade erro-validade"',
                 view.invalid({ "validade" => ["anterior ao início"] }, "validade", describedby: "ajuda-validade").to_s
    assert_equal ' aria-describedby="ajuda-validade"', view.invalid({}, "validade", describedby: "ajuda-validade").to_s
  end

  def test_api_reservation_items_must_be_objects
    token = uc(:create_credential).call(@org[:actor], name: "ERP", scopes: %w[reservations.write], expires_in_days: 1)["token"]
    base = { "customer_id" => @customer.id, "branch_id" => @org[:branch].id, "starts_at" => "2026-03-10T08:00:00Z",
             "ends_at" => "2026-03-10T12:00:00Z" }
    [["x"], 5, "x", [5], { "product_id" => @camera.id, "quantity" => 1 }].each_with_index do |items, i|
      post "/api/v1/reservations", JSON.generate(base.merge("items" => items)),
           { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "application/json", "HTTP_IDEMPOTENCY_KEY" => "itens-invalidos-#{i}" }

      assert_equal 422, last_response.status, items.inspect
      assert_equal ["items"], json_body["error"]["details"]["fields"].keys
    end
  end

  def test_pagination_offset_beyond_the_limit_is_a_validation_error
    token = uc(:create_credential).call(@org[:actor], name: "ERP", scopes: %w[customers.read], expires_in_days: 1)["token"]
    get "/api/v1/customers", { "offset" => "99999999999999999999" }, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

    assert_equal 422, last_response.status
    assert_equal ["deslocamento"], json_body["error"]["details"]["fields"].keys
    login("dona@alfa.test")
    get "/clientes", { "inicio" => "99999999999999999999" }

    assert_equal 422, last_response.status
  end

  # O banco não armazena U+0000 e o Ruby recusa operar texto com UTF-8 inválido: os dois casos são erro
  # do cliente, no campo, e não falha interna.
  def test_null_characters_and_invalid_encoding_are_client_errors
    token = uc(:create_credential).call(@org[:actor], name: "ERP", scopes: %w[coupons.read coupons.write customers.read], expires_in_days: 1)["token"]
    headers = { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "application/json", "HTTP_IDEMPOTENCY_KEY" => "texto-nulo-01" }
    post "/api/v1/coupons", JSON.generate("code" => "NULO10", "kind" => "percent", "discount_bps" => 1000, "description" => "a\u0000b"), headers

    assert_equal [422, { "description" => ["texto com codificação inválida ou caractere nulo"] }],
                 [last_response.status, json_body.dig("error", "details", "fields")]
    post "/api/v1/coupons", JSON.generate("code" => "NULO10", "kind" => "percent", "discount_bps" => 1000, "a\u0000" => 1),
         headers.merge("HTTP_IDEMPOTENCY_KEY" => "texto-nulo-02")

    assert_equal [422, ["corpo"]], [last_response.status, json_body.dig("error", "details", "fields").keys]
    %w[/api/v1/coupons?q=%FF /api/v1/customers?q=%00].each do |path|
      get path, {}, headers

      assert_equal [422, ["q"]], [last_response.status, json_body.dig("error", "details", "fields").keys], path
    end
    login("dona@alfa.test")
    get "/clientes?busca=%FF"

    assert_equal 422, last_response.status
    post_form "/clientes", { "tipo" => "individual", "nome" => "Cliente\u0000Nulo", "documento" => "52998224725" }

    assert_equal 400, last_response.status
  end

  def test_body_size_limits
    big = "a" * (1_048_576 + 1)
    post "/entrar", { "email" => big }

    assert_equal 413, last_response.status
    post "/api/v1/reservations", big, { "CONTENT_TYPE" => "application/json" }

    assert_equal 413, last_response.status
    env = Rack::MockRequest.env_for("/entrar", method: "POST", input: "email=x", "HTTP_TRANSFER_ENCODING" => "chunked")
    env.delete("CONTENT_LENGTH")

    assert_equal 413, Locentra::Interfaces::HTTP::App.build(@system).call(env).first, "corpo sem tamanho declarado"
    env = Rack::MockRequest.env_for("/api/v1/reservations", method: "POST", input: big, "CONTENT_TYPE" => "application/json")
    env.delete("CONTENT_LENGTH")

    assert_raises(Locentra::Interfaces::HTTP::PayloadTooLarge) { Locentra::Interfaces::HTTP::RequestContext.new(env, {}, "r").json }
  end

  def test_upload_above_the_configured_size_is_refused_and_nothing_is_stored
    small = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env("MAX_UPLOAD_BYTES" => "1048576")), clock: @clock, logger: @system.logger)
    @app = Rack::Lint.new(Locentra::Interfaces::HTTP::App.build(small))
    login("dona@alfa.test")
    get "/clientes/#{@customer.id}"
    pdf = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4\n#{"x" * 1_048_576}"), "application/pdf", original_filename: "grande.pdf")
    post "/anexos", { "_csrf" => csrf, "dono_tipo" => "customer", "dono_id" => @customer.id, "arquivo" => pdf }

    follow_redirect! while last_response.redirect?

    assert_includes last_response.body, "acima de 1 MB"
    assert_equal 0, owner_query("SELECT count(*) AS n FROM attachments").first["n"].to_i
    stored = Dir.glob(File.join(small.config.storage_root, @org[:organization_id], "*"))

    assert_empty stored
    post "/anexos", "x" * (1_048_576 + 65_537), { "CONTENT_TYPE" => "multipart/form-data; boundary=x" }

    assert_equal 413, last_response.status, "acima do limite de upload mais a margem do formulário"
  ensure
    small&.shutdown
  end

  def test_session_cookie_attributes_and_hsts_with_https
    secure = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env("APP_BASE_URL" => "https://locentra.example")), clock: @clock,
                                                                                                                             logger: @system.logger)
    response = Rack::MockRequest.new(Locentra::Interfaces::HTTP::App.build(secure))
                                .post("/entrar", params: { "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1" })
    cookie = response.headers["set-cookie"].to_s.split("\n").find { |c| c.start_with?("__Host-locentra=") }

    refute_nil cookie, response.headers["set-cookie"].inspect
    attributes = cookie.split(";").map { |part| part.strip.downcase }

    assert_includes attributes, "secure"
    assert_includes attributes, "httponly"
    assert_includes attributes, "samesite=lax"
    assert_includes attributes, "path=/"
    assert(attributes.none? { |a| a.start_with?("domain=") })
    production = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env("APP_ENV" => "production", "APP_BASE_URL" => "https://locentra.example")),
                                      clock: @clock, logger: @system.logger)

    assert_match(/max-age=31536000/, Rack::MockRequest.new(Locentra::Interfaces::HTTP::App.build(production)).get("/entrar")
                                                                                                          .headers["strict-transport-security"])
    error = assert_raises(Locentra::ConfigError) { Locentra::Config.from_env(TestDatabase.env("APP_ENV" => "production")) }
    assert_match(/https/, error.message)
  ensure
    secure&.shutdown
    production&.shutdown
  end
end
