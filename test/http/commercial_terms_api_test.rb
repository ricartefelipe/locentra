# frozen_string_literal: true

require_relative "commercial_terms_api_helper"

# Cupons e tarifas adicionais na API v1: cadastro, consulta por identificador ou código, alteração
# parcial com controle otimista, idempotência, inteiros estritos, escopos e isolamento.
class CommercialTermsApiTest < CommercialTermsApiTestCase
  COUPON_KEYS = %w[id code description kind discount_bps discount valid_from valid_until max_redemptions redemptions total_redemptions
                   remaining min_subtotal active status lock_version created_at updated_at].freeze
  FEE_KEYS = %w[id code name description default_amount active status lock_version created_at updated_at].freeze

  def coupon_payload(**extra)
    { "code" => "bemvindo10", "kind" => "percent", "discount_bps" => 1000, "description" => "Boas-vindas",
      "valid_until" => "2026-12-01T03:00:00Z", "max_redemptions" => 100, "min_subtotal_cents" => 30_000 }.merge(extra.transform_keys(&:to_s))
  end

  def create_api_coupon(**extra) = post!(201, "/coupons", coupon_payload(**extra))

  def test_coupon_creation_lookup_and_listing
    coupon = create_api_coupon

    assert_equal COUPON_KEYS, coupon.keys
    assert_equal "/api/v1/coupons/#{coupon["id"]}", last_response.headers["location"]
    assert_equal ["BEMVINDO10", "percent", 1000, nil, "2026-12-01T03:00:00Z", 100, 0, 0, 100, 30_000, true, "active", 1],
                 [*coupon.values_at("code", "kind", "discount_bps", "discount", "valid_until", "max_redemptions", "redemptions",
                                    "total_redemptions", "remaining"), coupon["min_subtotal"]["amount_cents"],
                  *coupon.values_at("active", "status", "lock_version")]
    post!(201, "/coupons", { "code" => "FIXO50", "kind" => "fixed", "discount_cents" => 5000 })
    fixed = json_body

    assert_equal [nil, D::Money.new(5000).to_h, nil, nil, 0], [*fixed.values_at("discount_bps", "discount", "max_redemptions", "remaining"),
                                                               fixed["min_subtotal"]["amount_cents"]]
    [coupon["id"], "bemvindo10", "BEMVINDO10"].each do |reference|
      get!(200, "/coupons/#{reference}")

      assert_equal coupon["id"], json_body["id"]
    end
    get!(200, "/coupons", { "status" => "active", "q" => "bem", "sort" => "-created_at" })

    assert_equal [["BEMVINDO10"], { "limit" => 25, "offset" => 0, "total" => 1, "next_offset" => nil }],
                 [codes, json_body["pagination"]]
    assert_equal COUPON_KEYS, json_body["data"].first.keys
    get!(200, "/coupons", { "limit" => "1" })

    assert_equal [%w[BEMVINDO10], 1], [codes, json_body["pagination"]["next_offset"]]
    { "status" => "apagado", "sort" => "valor", "limit" => "500", "q" => "x" * 41 }.each do |name, value|
      get!(422, "/coupons", { name => value })
    end
    get!(404, "/coupons/INEXISTENTE")
    created = audit_events("coupon.created").first

    assert_equal ["api", "coupon", coupon["id"]], created.values_at("actor_type", "resource_type", "resource_id")
    assert created["request_id"]
  end

  def test_coupon_idempotency_and_code_conflict
    post!(422, "/coupons", coupon_payload, key: nil)

    assert fields.key?("Idempotency-Key")
    post!(201, "/coupons", coupon_payload, key: "cupom-chave-0001")
    first = json_body

    assert_nil last_response.headers["idempotent-replayed"]
    post!(201, "/coupons", coupon_payload, key: "cupom-chave-0001")

    assert_equal ["true", first, "/api/v1/coupons/#{first["id"]}"],
                 [last_response.headers["idempotent-replayed"], json_body, last_response.headers["location"]]
    post!(409, "/coupons", coupon_payload(description: "Outro texto"), key: "cupom-chave-0001")

    assert_equal "idempotency_key_reused", error_code
    post!(409, "/coupons", coupon_payload(code: "BemVindo10"))

    assert_equal "coupon_code_taken", error_code
    assert_equal [1, 1], [owner_query("SELECT count(*) AS n FROM coupons").first["n"].to_i, audit_count("coupon.created")]
  end

  def test_coupon_patch_clears_with_null_and_detects_stale_version
    coupon = create_api_coupon
    path = "/coupons/#{coupon["id"]}"

    patch!(200, path, { "description" => nil, "valid_until" => nil, "max_redemptions" => nil, "min_subtotal_cents" => nil })
    cleared = json_body

    assert_equal [nil, nil, nil, nil, 0, 2], [*cleared.values_at("description", "valid_until", "max_redemptions", "remaining"),
                                              cleared["min_subtotal"]["amount_cents"], cleared["lock_version"]]
    assert_equal %w[description max_redemptions min_subtotal_cents valid_until], audit_events("coupon.updated").first["details"]["changes"].keys.sort
    patch!(200, path, {})
    patch!(200, path, { "description" => nil, "min_subtotal_cents" => 0 })

    assert_equal [2, 1], [json_body["lock_version"], audit_count("coupon.updated")], "alteração sem mudança não gera auditoria"
    patch!(409, path, { "description" => "Nova descrição", "lock_version" => 1 })

    assert_equal "stale_coupon", error_code
    patch!(200, path, { "description" => "Nova descrição", "valid_from" => "2026-04-01T03:00:00Z", "lock_version" => 2 })

    assert_equal ["Nova descrição", "2026-04-01T03:00:00Z", "scheduled", 3], json_body.values_at("description", "valid_from", "status", "lock_version")
    patch!(200, path, { "description" => "Repetida" }, key: "patch-chave-0001")
    patch!(200, path, { "description" => "Repetida" }, key: "patch-chave-0001")

    assert_equal ["true", 4], [last_response.headers["idempotent-replayed"], json_body["lock_version"]]
    patch!(409, path, { "description" => "Outra" }, key: "patch-chave-0001")

    assert_equal "idempotency_key_reused", error_code
  end

  def test_coupon_mutations_require_the_identifier_and_keep_immutable_fields
    coupon = create_api_coupon
    path = "/coupons/#{coupon["id"]}"
    { "code" => %w[OUTRO codigo], "kind" => %w[fixed tipo], "discount_bps" => [500, "valor"],
      "discount_cents" => [500, "valor"] }.each do |key, (value, field)|
      patch!(422, path, { key => value })

      assert_equal ["#{key} não pode ser alterado"], fields[field]
    end
    patch!(422, "/coupons/BEMVINDO10", { "description" => "Pelo código" })

    assert fields.key?("id")
    %w[deactivate reactivate].each do |action|
      post!(422, "/coupons/BEMVINDO10/#{action}")

      assert fields.key?("id")
    end
    missing = SecureRandom.uuid

    patch!(404, "/coupons/#{missing}", { "description" => "x" })
    post!(404, "/coupons/#{missing}/deactivate")
    patch!(422, path, { "description" => "x" }, key: nil)
    post!(422, "#{path}/deactivate", {}, key: nil)
    get!(200, path)

    assert_equal ["Boas-vindas", 1, true], json_body.values_at("description", "lock_version", "active")
  end

  def test_coupon_deactivation_and_reactivation_are_idempotent_by_state
    coupon = create_api_coupon
    path = "/coupons/#{coupon["id"]}"

    post!(200, "#{path}/deactivate")

    assert_equal [false, "inactive", 2], json_body.values_at("active", "status", "lock_version")
    post!(200, "#{path}/deactivate")

    assert_equal [2, 1], [json_body["lock_version"], audit_count("coupon.deactivated")], "desativar de novo é operação nula"
    get!(200, "/coupons", { "status" => "inactive" })

    assert_equal ["BEMVINDO10"], codes
    post!(200, "#{path}/reactivate")

    assert_equal [true, "active", 3], json_body.values_at("active", "status", "lock_version")
    assert_equal "api", audit_events("coupon.reactivated").first["actor_type"]
    post!(405, path) # exclusão e outras ações não existem na API
  end

  def test_coupon_values_are_strict_json_integers_and_instants
    [12.5, "12", "12.5", "abc", true].each do |value|
      post!(422, "/coupons", coupon_payload(discount_bps: value))

      assert_equal ["informe um número inteiro"], fields["valor"], value.inspect
    end
    post!(422, "/coupons", coupon_payload(max_redemptions: "10", min_subtotal_cents: 1.5, valid_until: "amanhã", valid_from: 5,
                                          code: 77, description: ["x"]))

    assert_equal %w[codigo descricao maximo_usos subtotal_minimo valido_ate valido_de], fields.keys.sort
    assert_equal ["informe um número inteiro"], fields["maximo_usos"]
    post!(422, "/coupons", { "code" => "FIXO", "kind" => "fixed", "discount_bps" => 1000 })

    assert_equal ["o tipo fixed exige discount_cents (e não aceita discount_bps)"], fields["valor"]
    post!(422, "/coupons", coupon_payload(discount_cents: 100))

    assert fields.key?("valor")
    post!(422, "/coupons", coupon_payload(kind: "outro"))

    assert_equal ["use percent ou fixed"], fields["tipo"]
    post!(422, "/coupons", coupon_payload(discount_bps: 10_001, max_redemptions: 0, min_subtotal_cents: -1,
                                          valid_until: "2026-03-01T00:00:00Z", code: "a"))

    assert_equal %w[codigo maximo_usos subtotal_minimo valido_ate valor], fields.keys.sort
    coupon = create_api_coupon

    patch!(422, "/coupons/#{coupon["id"]}", { "max_redemptions" => "5", "lock_version" => "1" })

    assert_equal %w[lock_version maximo_usos], fields.keys.sort
    patch!(422, "/coupons/#{coupon["id"]}", { "max_redemptions" => 2.0 })

    assert_equal 1, owner_query("SELECT count(*) AS n FROM coupons").first["n"].to_i
  end

  def test_coupon_scopes_and_tenant_isolation
    coupon = create_api_coupon
    reader = token(%w[coupons.read])

    get!(200, "/coupons/#{coupon["id"]}", token: reader)
    post!(403, "/coupons", coupon_payload(code: "OUTRO10"), token: reader)

    assert_equal "forbidden", error_code
    patch!(403, "/coupons/#{coupon["id"]}", { "description" => "x" }, token: reader)
    post!(403, "/coupons/#{coupon["id"]}/deactivate", {}, token: reader)
    without = token(%w[fees.read])
    ["/coupons", "/coupons/#{coupon["id"]}", "/coupons/#{coupon["id"]}/redemptions"].each do |path|
      get!(403, path, token: without)
    end
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    foreign = token(SCOPES, actor: beta[:actor])
    ["/coupons/#{coupon["id"]}", "/coupons/BEMVINDO10", "/coupons/#{coupon["id"]}/redemptions"].each do |path|
      get!(404, path, token: foreign)
    end
    patch!(404, "/coupons/#{coupon["id"]}", { "description" => "x" }, token: foreign)
    post!(404, "/coupons/#{coupon["id"]}/deactivate", {}, token: foreign)
    get!(200, "/coupons", token: foreign)

    assert_empty json_body["data"]
    post!(201, "/coupons", coupon_payload, token: foreign)

    refute_equal coupon["id"], json_body["id"], "o mesmo código é independente em outra organização"
    get!(200, "/coupons/#{coupon["id"]}")

    assert_equal ["Boas-vindas", true], json_body.values_at("description", "active")
  end

  def test_coupon_redemptions_follow_the_credential_scopes
    coupon = create_api_coupon
    2.times do |index|
      post!(201, "/reservations", reservation_payload(day: 10 + (index * 3), coupon_code: "bemvindo10"))
    end
    reservation = json_body

    get!(200, "/coupons/bemvindo10/redemptions")
    row = json_body["data"].find { |item| item["reservation_id"] == reservation["id"] }

    assert_equal %w[id reservation_id reservation_code customer_name subtotal discount redeemed_at state released_at], row.keys
    assert_equal [reservation["code"], "Produtora Horizonte", 90_000, 9000, @clock.now.utc.iso8601, "active", nil],
                 [*row.values_at("reservation_code", "customer_name"), row["subtotal"]["amount_cents"], row["discount"]["amount_cents"],
                  *row.values_at("redeemed_at", "state", "released_at")]
    assert_equal 2, json_body["pagination"]["total"]
    get!(200, "/coupons/#{coupon["id"]}/redemptions", { "limit" => "1" }, token: token(%w[coupons.read]))

    assert_equal [%w[id subtotal discount redeemed_at state released_at], 1], [json_body["data"].first.keys, json_body["pagination"]["next_offset"]]
    get!(200, "/coupons/#{coupon["id"]}/redemptions", token: token(%w[coupons.read reservations.read]))

    assert_equal %w[id reservation_id reservation_code subtotal discount redeemed_at state released_at], json_body["data"].first.keys
    patch!(422, "/coupons/#{coupon["id"]}", { "max_redemptions" => 1 })

    assert_equal ["não pode ser menor que os usos ativos (2)"], fields["maximo_usos"]
    post!(200, "/reservations/#{reservation["id"]}/cancel", { "reason" => "desistência" })
    get!(200, "/coupons/#{coupon["id"]}/redemptions")
    released = json_body["data"].find { |row| row["reservation_id"] == reservation["id"] }

    assert_equal ["released_cancelled", @clock.now.utc.iso8601], released.values_at("state", "released_at")
    get!(200, "/coupons/#{coupon["id"]}")

    assert_equal [1, 2, 99], json_body.values_at("redemptions", "total_redemptions", "remaining")
  end

  def fee_payload(**extra)
    { "code" => "entrega", "name" => "Entrega e retirada no local", "description" => "Até 30 km", "default_amount_cents" => 15_000 }
      .merge(extra.transform_keys(&:to_s))
  end

  def create_api_fee(**extra) = post!(201, "/fees", fee_payload(**extra))

  def test_fee_creation_lookup_listing_and_conflicts
    fee = create_api_fee

    assert_equal FEE_KEYS, fee.keys
    assert_equal "/api/v1/fees/#{fee["id"]}", last_response.headers["location"]
    assert_equal ["ENTREGA", "Entrega e retirada no local", "Até 30 km", D::Money.new(15_000).to_h, true, "active", 1],
                 fee.values_at("code", "name", "description", "default_amount", "active", "status", "lock_version")
    create_api_fee(code: "MONTAGEM", name: "Montagem", default_amount_cents: 25_000)
    [fee["id"], "entrega"].each do |reference|
      get!(200, "/fees/#{reference}")

      assert_equal fee["id"], json_body["id"]
    end
    get!(200, "/fees", { "sort" => "code" })

    assert_equal [%w[ENTREGA MONTAGEM], 2], [codes, json_body["pagination"]["total"]]
    assert_equal FEE_KEYS, json_body["data"].first.keys
    get!(200, "/fees", { "q" => "mont", "status" => "active" })

    assert_equal %w[MONTAGEM], codes
    get!(422, "/fees", { "status" => "apagada" })
    get!(422, "/fees", { "sort" => "valor" })
    get!(404, "/fees/INEXISTENTE")

    assert_equal "tarifa não encontrada", error_message
    post!(409, "/fees", fee_payload)

    assert_equal "fee_code_taken", error_code
    post!(422, "/fees", fee_payload(code: "LIMPEZA"), key: nil)
    post!(201, "/fees", fee_payload(code: "LIMPEZA"), key: "tarifa-chave-0001")
    post!(201, "/fees", fee_payload(code: "LIMPEZA"), key: "tarifa-chave-0001")

    assert_equal "true", last_response.headers["idempotent-replayed"]
    assert_equal ["api", 3], [audit_events("fee.created").first["actor_type"], audit_count("fee.created")]
  end

  def test_fee_patch_deactivation_and_strict_values
    fee = create_api_fee
    path = "/fees/#{fee["id"]}"

    patch!(200, path, { "default_amount_cents" => 18_000, "description" => nil })

    assert_equal [18_000, nil, 2], [json_body["default_amount"]["amount_cents"], json_body["description"], json_body["lock_version"]]
    assert_equal({ "default_amount_cents" => [15_000, 18_000], "description" => ["Até 30 km", nil] }, audit_events("fee.updated").first["details"]["changes"])
    patch!(200, path, { "name" => "Entrega e retirada no local" })

    assert_equal [2, 1], [json_body["lock_version"], audit_count("fee.updated")]
    patch!(409, path, { "name" => "Entrega", "lock_version" => 1 })

    assert_equal "stale_fee", error_code
    patch!(422, path, { "code" => "OUTRA" })

    assert_equal ["code não pode ser alterado"], fields["codigo"]
    ["150", 150.5, true, 0, -5, nil].each do |value|
      patch!(422, path, { "default_amount_cents" => value })

      assert_includes fields.keys, "valor_padrao", value.inspect
    end
    post!(422, "/fees", { "code" => "X1", "name" => 5, "default_amount_cents" => "100" })

    assert_equal %w[nome valor_padrao], fields.keys.sort
    post!(422, "/fees", { "code" => "X1" })

    assert_equal %w[nome valor_padrao], fields.keys.sort
    patch!(422, "/fees/ENTREGA", { "name" => "Pelo código" })
    post!(200, "#{path}/deactivate")

    assert_equal [false, "inactive", 3], json_body.values_at("active", "status", "lock_version")
    post!(200, "#{path}/deactivate")

    assert_equal [3, 1], [json_body["lock_version"], audit_count("fee.deactivated")]
    get!(200, "/fees", { "status" => "inactive" })

    assert_equal %w[ENTREGA], codes
    post!(200, "#{path}/reactivate")

    assert_equal [true, "active"], json_body.values_at("active", "status")
  end

  def test_fee_scopes_and_tenant_isolation
    fee = create_api_fee
    reader = token(%w[fees.read])

    get!(200, "/fees", token: reader)
    post!(403, "/fees", fee_payload(code: "OUTRA"), token: reader)
    patch!(403, "/fees/#{fee["id"]}", { "name" => "Outro nome" }, token: reader)
    post!(403, "/fees/#{fee["id"]}/deactivate", {}, token: reader)
    get!(403, "/fees", token: token(%w[coupons.read]))
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    foreign = token(SCOPES, actor: beta[:actor])

    get!(404, "/fees/#{fee["id"]}", token: foreign)
    get!(404, "/fees/ENTREGA", token: foreign)
    patch!(404, "/fees/#{fee["id"]}", { "name" => "Invasão" }, token: foreign)
    post!(404, "/fees/#{fee["id"]}/deactivate", {}, token: foreign)
    post!(201, "/fees", fee_payload, token: foreign)
    get!(200, "/fees/#{fee["id"]}")

    assert_equal ["Entrega e retirada no local", true], json_body.values_at("name", "active")
  end
end
