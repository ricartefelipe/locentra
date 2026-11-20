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

end
