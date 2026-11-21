# frozen_string_literal: true

require_relative "commercial_terms_api_helper"

# Condições negociadas e tarifas na criação de reserva pela API v1: paginação, escopos, sobreposição,
# encerramento imediato e agendado, autorização de ajustes de tarifa e snapshot de preços.
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
    post!(422, agreements_path, { "discount_bps" => 500, "product_id" => false })

    assert_equal %w[produto], fields.keys
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

  def test_reservation_fees_by_default_amount_and_authorized_adjustments
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    attendant = token(%w[reservations.read reservations.write])

    post!(201, "/reservations", reservation_payload(fees: [{ "fee_id" => fee.id }]), token: attendant)

    assert_equal 105_000, json_body["total"]["amount_cents"]
    get!(200, "/reservations/#{json_body["id"]}", token: attendant)

    assert_equal [{ "fee_id" => fee.id, "code" => "ENTREGA", "description" => "Entrega e retirada no local", "amount_cents" => 15_000,
                    "default_amount_cents" => 15_000, "source" => "catalog" }], json_body["pricing"]["fees"]
    [{ "fee_id" => fee.id, "amount_cents" => 20_000 }, { "description" => "Taxa de estacionamento", "amount_cents" => 3000 }].each do |entry|
      post!(403, "/reservations", reservation_payload(day: 13, fees: [entry]), token: attendant)

      assert_equal "forbidden", error_code
      assert_includes error_message, "exige a permissão de ajustar tarifas"
    end
    post!(201, "/reservations", reservation_payload(day: 13, fees: [{ "fee_id" => fee.id, "amount_cents" => 20_000 },
                                                                    { "description" => "Taxa de estacionamento", "amount_cents" => 3000 }]))

    assert_equal 113_000, json_body["total"]["amount_cents"]
    assert_equal([{ "fee_id" => fee.id, "code" => "ENTREGA", "description" => "Entrega e retirada no local", "default_amount_cents" => 15_000,
                    "amount_cents" => 20_000, "source" => "catalog" },
                  { "fee_id" => nil, "code" => nil, "description" => "Taxa de estacionamento", "default_amount_cents" => nil,
                    "amount_cents" => 3000, "source" => "custom" }].map { |entry| entry.sort.to_h },
                 audit_events("reservation.created").last["details"]["fee_overrides"].map { |entry| entry.sort.to_h })
    post!(403, "/reservations", reservation_payload(day: 16, fees: [{ "fee_id" => fee.id, "amount_cents" => 14_999 }]))

    assert_includes error_message, "redução da tarifa ENTREGA acima do limite", "credenciais não reduzem tarifas"
    assert_equal 2, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i
  end

  # Chave nula vale como ausente, como em amount_cents, e chaves fora do formato são ignoradas. Das
  # entradas devolvidas em pricing.fees, a avulsa é aceita como está; a do catálogo traz `description`
  # (nome da tarifa) junto com `fee_id` e é recusada, como o OpenAPI descreve, até ficar só com fee_id e valor.
  def test_reservation_fees_resent_from_pricing_fees
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    post!(201, "/reservations", reservation_payload(fees: [{ "fee_id" => fee.id },
                                                           { "description" => "Taxa de estacionamento", "amount_cents" => 3000 }]))
    returned = get!(200, "/reservations/#{json_body["id"]}")["pricing"]["fees"]
    catalog, custom = returned.partition { |entry| entry["source"] == "catalog" }.map(&:first)

    assert_equal [fee.id, "Entrega e retirada no local", nil], [catalog["fee_id"], catalog["description"], custom["fee_id"]]
    post!(201, "/reservations", reservation_payload(day: 14, fees: [custom]))

    assert_equal 93_000, json_body["total"]["amount_cents"]
    [[catalog], returned].each do |fees|
      post!(422, "/reservations", reservation_payload(day: 16, fees: fees))

      assert_equal ["deve ser uma lista de objetos com fee_id ou description e amount_cents"], fields["fees"], fees.inspect
    end
    post!(201, "/reservations", reservation_payload(day: 18, fees: [catalog.slice("fee_id", "amount_cents"), custom]))

    assert_equal 108_000, json_body["total"]["amount_cents"]
    post!(201, "/reservations", reservation_payload(day: 20, fees: [{ "fee_id" => fee.id, "description" => nil, "amount_cents" => nil }]))
    post!(422, "/reservations", reservation_payload(fees: [{ "fee_id" => nil, "description" => nil, "amount_cents" => 100 }]))

    assert_equal ["deve ser uma lista de objetos com fee_id ou description e amount_cents"], fields["fees"]
    description = YAML.safe_load_file(File.expand_path("../../docs/openapi.yaml", __dir__)).dig("components", "schemas", "ReservationFee", "description")

    assert_includes description, "somente a entrada avulsa pode ser reenviada como está", "o contrato descreve o reenvio de pricing.fees"
  end

  def test_reservation_fees_format_and_lookup_errors
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    ["ENTREGA", [fee.id], [{}], [{ "fee_id" => fee.id, "description" => "Duas formas" }], [{ "amount_cents" => 100 }]].each do |fees|
      post!(422, "/reservations", reservation_payload(fees: fees))

      assert_equal ["deve ser uma lista de objetos com fee_id ou description e amount_cents"], fields["fees"], fees.inspect
    end
    [[{ "fee_id" => fee.id, "amount_cents" => "150" }], [{ "fee_id" => fee.id, "amount_cents" => 150.5 }], [{ "fee_id" => fee.id, "amount_cents" => 0 }],
     [{ "description" => "Sem valor" }], [{ "description" => 5, "amount_cents" => 100 }], [{ "fee_id" => "abc" }],
     [{ "fee_id" => fee.id }, { "fee_id" => fee.id }], Array.new(11) { |index| { "description" => "Avulsa #{index}", "amount_cents" => 100 } }].each do |fees|
      post!(422, "/reservations", reservation_payload(fees: fees))

      assert_equal %w[tarifas], fields.keys, fees.inspect
    end
    post!(404, "/reservations", reservation_payload(fees: [{ "fee_id" => SecureRandom.uuid }]))

    assert_equal "tarifa não encontrada", error_message
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    foreign_fee = create_fee("ENTREGA", "Entrega da outra organização", 9000, actor: beta[:actor])

    post!(404, "/reservations", reservation_payload(fees: [{ "fee_id" => foreign_fee.id }]))
    uc(:set_fee_active).call(@actor, fee.id, active: false)

    post!(422, "/reservations", reservation_payload(fees: [{ "fee_id" => fee.id }]))

    assert_equal ["a tarifa ENTREGA está inativa"], fields["tarifas"]
    assert_empty owner_query("SELECT id FROM reservations")
  end

  def openapi_schemas = YAML.safe_load_file(File.expand_path("../../docs/openapi.yaml", __dir__)).dig("components", "schemas")

  # As chaves do detalhe da reserva (primeiro nível, itens, alocações e preços) estão no OpenAPI.
  def assert_documented_keys(detail)
    schemas = openapi_schemas
    reservation = schemas.dig("Reservation", "properties")
    allocations = reservation.dig("allocations", "properties")

    assert_empty detail.keys - reservation.keys
    assert_empty detail["items"].first.keys - reservation.dig("items", "items", "properties").keys
    assert_empty detail["allocations"].keys - allocations.keys
    assert_empty detail["allocations"]["assets"].first.keys - allocations.dig("assets", "items", "properties").keys
    assert_empty detail["pricing"].keys - schemas.dig("ReservationPricing", "properties").keys
    assert_empty detail["items"].first["pricing"].keys - schemas.dig("ReservationItemPricing", "properties").keys
    units = schemas.dig("ReservationItemPricing", "properties", "units", "description")

    detail["items"].first["pricing"]["units"].each_key { |unit| assert_includes units, "`#{unit}`" }
  end

  def test_reservation_detail_brings_coupon_agreements_and_fees
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    coupon = create_coupon("BEMVINDO10", description: "Boas-vindas")
    agreement = create_agreement(@customer, 800)

    post!(201, "/reservations", reservation_payload(coupon_code: "bemvindo10", fees: [{ "fee_id" => fee.id }]))

    assert_equal 89_520, json_body["total"]["amount_cents"]
    get!(200, "/reservations/#{json_body["id"]}")
    pricing = json_body["pricing"]

    assert_equal [82_800, 8280, 15_000, 89_520], pricing.values_at("subtotal_cents", "coupon_discount_cents", "fees_cents", "total_cents")
    assert_equal({ "id" => coupon.id, "code" => "BEMVINDO10", "kind" => "percent", "value" => 1000, "description" => "Boas-vindas",
                   "valid_from" => nil, "valid_until" => nil }, pricing["coupon"])
    assert_equal([[agreement.id, "general", nil, 800]], pricing["agreements"].map { |row| row.values_at("id", "scope", "product_id", "discount_bps") })
    assert_equal([[fee.id, "ENTREGA", 15_000, "catalog"]], pricing["fees"].map { |row| row.values_at("fee_id", "code", "amount_cents", "source") })
    assert_equal [agreement.id, 800, 7200], json_body["items"].first["pricing"].values_at("negotiated_agreement_id", "negotiated_discount_bps",
                                                                                          "negotiated_discount_cents")
    assert_documented_keys(json_body)
    reservation_id = json_body["id"]
    get!(200, "/coupons/BEMVINDO10")

    assert_equal [1, 1], json_body.values_at("redemptions", "total_redemptions")
    uc(:extend_reservation).call(@actor, reservation_id, ends_at: t("2026-03-13T12:00:00Z"))
    adjustment = get!(200, "/reservations/#{reservation_id}")["adjustments"].first

    assert_equal "extension", adjustment["kind"]
    assert_empty adjustment.keys - openapi_schemas.dig("ReservationAdjustment", "properties").keys
  end
end
