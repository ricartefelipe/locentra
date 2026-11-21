# frozen_string_literal: true

require_relative "commercial_terms_api_helper"

# Condições negociadas na API v1: paginação, escopos, sobreposição e encerramento imediato e agendado.
class CommercialTermsApiAgreementsTest < CommercialTermsApiTestCase
  AGREEMENT_KEYS = %w[id customer_id scope product_id discount_bps valid_from valid_until notes ended_at end_reason status created_at].freeze

  def agreements_path(customer = @customer) = "/customers/#{customer.id}/price-agreements"

  def create_api_agreement(**body) = post!(201, agreements_path, body.transform_keys(&:to_s))

  def test_agreement_creation_listing_and_product_visibility
    general = create_api_agreement(discount_bps: 800, notes: "Contrato anual")

    assert_equal AGREEMENT_KEYS, general.keys
    assert_equal [@customer.id, "general", nil, 800, @clock.now.utc.iso8601, nil, "Contrato anual", nil, nil, "active"],
                 general.values_at("customer_id", "scope", "product_id", "discount_bps", "valid_from", "valid_until", "notes", "ended_at",
                                   "end_reason", "status")
    product = create_api_agreement(product_id: @camera.id, discount_bps: 1000, valid_from: "2026-04-01T03:00:00Z", valid_until: "2026-05-01T03:00:00Z")

    assert_equal ["product", @camera.id, "scheduled", "2026-04-01T03:00:00Z", "2026-05-01T03:00:00Z"],
                 product.values_at("scope", "product_id", "status", "valid_from", "valid_until")
    get!(200, agreements_path)
    rows = json_body["data"]

    assert_equal [[product["id"], general["id"]], { "limit" => 25, "offset" => 0, "total" => 2, "next_offset" => nil }],
                 [rows.map { |row| row["id"] }, json_body["pagination"]]
    assert_equal [{ "sku" => "CAM-API", "name" => "Câmera FX" }, false], [rows.first["product"], rows.last.key?("product")]
    get!(200, agreements_path, { "limit" => "1", "offset" => "1" }, token: token(%w[price_agreements.read]))

    assert_equal [[general["id"]], 2, nil], [json_body["data"].map { |row| row["id"] }, *json_body["pagination"].values_at("total", "next_offset")]
    get!(200, agreements_path, { "limit" => "1" }, token: token(%w[price_agreements.read]))

    assert_equal [AGREEMENT_KEYS, @camera.id, 1], [json_body["data"].first.keys, json_body["data"].first["product_id"],
                                                   json_body["pagination"]["next_offset"]], "sem catalog.read a chave product é omitida"
    created = audit_events("price_agreement.created")

    assert_equal [%w[api api], [general["id"], product["id"]]], [created.map { |row| row["actor_type"] }, created.map { |row| row["resource_id"] }]
  end

  def test_agreement_overlap_idempotency_and_validation
    post!(422, agreements_path, { "discount_bps" => 800 }, key: nil)
    post!(201, agreements_path, { "discount_bps" => 800 }, key: "condicao-chave-01")
    first = json_body

    post!(201, agreements_path, { "discount_bps" => 800 }, key: "condicao-chave-01")

    assert_equal ["true", first], [last_response.headers["idempotent-replayed"], json_body]
    post!(409, agreements_path, { "discount_bps" => 500 })

    assert_equal "price_agreement_overlap", error_code
    { "discount_bps" => %w[8 desconto], "valid_from" => %w[ontem valido_de], "valid_until" => [20_260_401, "valido_ate"],
      "notes" => [5, "observacoes"], "product_id" => %w[CAM-API produto] }.each do |key, (value, field)|
      post!(422, agreements_path, { "discount_bps" => 500, "product_id" => @camera.id }.merge(key => value))

      assert_equal [field], fields.keys, key
    end
    post!(422, agreements_path, { "discount_bps" => 9500, "product_id" => @camera.id, "valid_until" => "2026-03-01T00:00:00Z" })

    assert_equal %w[desconto valido_ate], fields.keys.sort
    post!(422, agreements_path, { "product_id" => @camera.id })

    assert_equal ["entre 0,01% e 90%"], fields["desconto"]
    post!(404, agreements_path, { "discount_bps" => 500, "product_id" => SecureRandom.uuid })

    assert_equal "produto não encontrado", error_message
    post!(404, "/customers/#{SecureRandom.uuid}/price-agreements", { "discount_bps" => 500 })
    get!(404, "/customers/#{SecureRandom.uuid}/price-agreements")
    post!(422, "/customers/abc/price-agreements", { "discount_bps" => 500 })
    get!(422, "/customers/abc/price-agreements")

    assert_equal 1, owner_query("SELECT count(*) AS n FROM customer_price_agreements").first["n"].to_i
  end

  def test_agreement_end_scheduled_then_refused_and_immediate
    general = create_api_agreement(discount_bps: 800)
    path = "/price-agreements/#{general["id"]}/end"

    post!(422, path, {})

    assert_equal %w[motivo], fields.keys
    post!(422, path, { "reason" => 5, "effective_at" => "depois" })

    assert_equal %w[encerrar_em motivo], fields.keys.sort
    post!(422, path, { "reason" => "Troca de tabela", "effective_at" => "2026-04-01T03:00:00Z" }, key: nil)
    post!(200, path, { "reason" => "Troca de tabela", "effective_at" => "2026-04-01T03:00:00Z" })

    assert_equal ["2026-04-01T03:00:00Z", "Troca de tabela", "active"], json_body.values_at("ended_at", "end_reason", "status")
    ended = audit_events("price_agreement.ended").first

    assert_equal ["api", true, "active"], [ended["actor_type"], ended["details"]["scheduled"], ended["details"]["previous_status"]]
    post!(409, path, { "reason" => "Encerrar de novo" })

    assert_equal "invalid_transition", error_code
    post!(201, agreements_path, { "discount_bps" => 600, "valid_from" => "2026-04-01T03:00:00Z" })

    assert_equal "scheduled", json_body["status"], "a nova condição começa no instante em que a anterior termina"
    product = create_api_agreement(product_id: @camera.id, discount_bps: 1000)

    post!(200, "/price-agreements/#{product["id"]}/end", { "reason" => "Fim da parceria" })

    assert_equal [@clock.now.utc.iso8601, "ended"], json_body.values_at("ended_at", "status")
    post!(404, "/price-agreements/#{SecureRandom.uuid}/end", { "reason" => "Inexistente" })

    assert_equal "condição negociada não encontrada", error_message
    post!(404, "/price-agreements/CODIGO/end", { "reason" => "Sem identificador" })
  end

  def test_agreement_scopes_and_tenant_isolation
    general = create_api_agreement(discount_bps: 800)
    reader = token(%w[price_agreements.read])

    get!(200, agreements_path, token: reader)
    post!(403, agreements_path, { "discount_bps" => 500, "product_id" => @camera.id }, token: reader)
    post!(403, "/price-agreements/#{general["id"]}/end", { "reason" => "Sem escopo" }, token: reader)
    get!(403, agreements_path, token: token(%w[coupons.read]))
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    foreign = token(SCOPES, actor: beta[:actor])

    get!(404, agreements_path, token: foreign)
    post!(404, agreements_path, { "discount_bps" => 500 }, token: foreign)
    post!(404, "/price-agreements/#{general["id"]}/end", { "reason" => "Outra organização" }, token: foreign)
    get!(200, agreements_path)

    assert_equal [nil, "active"], json_body["data"].first.values_at("ended_at", "status")
  end
end
