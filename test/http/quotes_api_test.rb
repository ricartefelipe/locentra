# frozen_string_literal: true

require_relative "api_v1_helper"

# Orçamentos na API v1 (Rack::Lint): criação com tarifas, lista paginada, detalhe com versões, nova versão,
# envio com e sem bloqueio, aprovação em nome do cliente (inclusive vencida), rejeição, conversão 201/200,
# idempotência, escopos, isolamento entre organizações e conformidade com o OpenAPI.
class QuotesApiTest < ApiV1TestCase
  SCOPES = %w[quotes.read quotes.write reservations.read reservations.write fees.override customers.read].freeze

  def setup
    super
    @token = token(SCOPES)
    @fee = uc(:create_fee).call(@actor, { code: "FRETE", name: "Frete", default_amount: D::Money.new(8_000) })
  end

  def payload(**extra)
    { "customer_id" => @customer.id, "branch_id" => @branch.id, "starts_at" => "2026-03-10T08:00:00Z", "ends_at" => "2026-03-12T08:00:00Z",
      "valid_until" => "2026-03-05T12:00:00Z", "items" => [{ "product_id" => @camera.id, "quantity" => 1 }],
      "terms" => "Entrega no local do evento." }.merge(extra.transform_keys(&:to_s))
  end

  def revision(**extra) = payload(**extra).except("customer_id")

  def quote_input(**extra)
    { customer_id: @customer.id, branch_id: @branch.id, period: period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z"), lines: [line(@camera, 1)],
      valid_until: t("2026-03-05T12:00:00Z") }.merge(extra)
  end

  def draft(actor: @actor, **extra) = uc(:create_quote).call(actor, quote_input(**extra))

  def sent(**extra)
    quote = draft(**extra)
    uc(:send_quote).call(@actor, quote.id)
  end

  def approved(**extra)
    quote = sent(**extra)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria Compradora")
  end

  def beta_quote
    camera = create_product(@beta[:actor], sku: "CAM-BETA", tracking: "serialized")
    register_assets(@beta[:actor], camera, @beta[:branch], 1)
    uc(:create_quote).call(@beta[:actor], { customer_id: beta_customer.id, branch_id: @beta[:branch].id, lines: [line(camera, 1)],
                                            period: period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z"), valid_until: t("2026-03-05T12:00:00Z") })
  end

  def test_create_with_catalog_and_custom_fees_returns_the_detail_and_location
    body = post!(201, "/quotes", payload(fees: [{ "fee_id" => @fee.id }, { "description" => "Montagem", "amount_cents" => 15_000 }]))

    assert_conforms body, "Quote"
    assert_equal "/api/v1/quotes/#{body["id"]}", location
    assert_equal ["draft", 1, @customer.id], [body["status"], body["current_version"], body["customer_id"]]
    version = body["versions"].first

    assert_equal [90_000 + 8_000 + 15_000, 23_000], [version["total"]["amount_cents"], version["pricing"]["fees_cents"]]
    assert_equal([%w[catalog 8000], %w[custom 15000]], version["pricing"]["fees"].map { |fee| [fee["source"], fee["amount_cents"].to_s] })
    assert_equal [@camera.id, "CAM-API", 1], version["items"].first.values_at("product_id", "sku", "quantity")
    assert_equal 90_000, version["items"].first["pricing"]["total_cents"]
    assert_equal({ "tiers" => D::Organizations::CancellationPolicy::DEFAULT["tiers"] }, version["cancellation_policy"])
    assert_equal 1, audit_count("quote.created")
  end

  def test_create_refuses_missing_scopes_custom_fees_and_manual_discount_by_credential
    post!(403, "/quotes", payload, token: token(%w[quotes.read]))

    assert_error "forbidden"
    post!(403, "/quotes", payload(fees: [{ "description" => "Montagem", "amount_cents" => 15_000 }]), token: token(%w[quotes.write quotes.read]))

    assert_error "forbidden"
    assert_includes error_message, "tarifa avulsa exige a permissão de ajustar tarifas"
    post!(403, "/quotes", payload("manual_discount_bps" => 500))

    assert_includes error_message, "desconto manual acima do limite"
    assert_equal 0, count("SELECT count(*) FROM quotes")
  end

  # O detalhe devolvido pela mutação é lido na transação dela, sem exigir `quotes.read` da credencial.
  def test_mutations_require_only_the_write_scope
    write = token(%w[quotes.write])
    body = post!(201, "/quotes", payload, token: write)

    assert_conforms body, "Quote"
    id = body["id"]

    assert_equal 2, post!(201, "/quotes/#{id}/versions", revision(terms: "Retirada na loja."), token: write)["current_version"]
    assert_equal "sent", post!(200, "/quotes/#{id}/send", {}, token: write)["status"]
    assert_equal "approved", post!(200, "/quotes/#{id}/approve", { "version" => 2, "approver_name" => "Maria Compradora" }, token: write)["status"]
    converted = post!(201, "/quotes/#{id}/convert", {}, token: token(%w[quotes.write reservations.write]))

    assert_equal ["converted", "confirmed"], [converted["quote"]["status"], converted["reservation"]["status"]]
    assert_equal "rejected", post!(200, "/quotes/#{sent.id}/reject", { "reason" => "Preço acima do orçamento" }, token: write)["status"]
  end

  def test_create_validation_errors_are_reported_by_field
    post!(422, "/quotes", payload("valid_until" => 20_260_305, "manual_discount_bps" => "5", "fees" => [{ "fee_id" => @fee.id, "amount_cents" => "100" }],
                                  "terms" => 12, "hold_minutes" => 60.5))

    assert_error "validation_error"

    assert_equal %w[condicoes desconto tarifas validade validade_bloqueio], fields.keys.sort
    post!(422, "/quotes", payload("items" => []))

    assert_equal ["itens"], fields.keys
    post!(422, "/quotes", payload("items" => "CAM-API"))

    assert_equal ["items"], fields.keys
    post!(422, "/quotes", payload.except("valid_until"))

    assert_equal({ "validade" => ["obrigatória"] }, fields)
    post!(422, "/quotes", payload("hold_policy" => "sempre"))

    assert_equal({ "politica_bloqueio" => ["use none ou hold_on_send"] }, fields)
    post!(422, "/quotes", payload("manual_discount_bps" => 10_001))

    assert_equal({ "desconto" => ["máximo 10000"] }, fields)
    post!(422, "/quotes", payload("customer_id" => "abc"))

    assert_equal ["cliente"], fields.keys
  end

  def test_create_is_idempotent
    body = assert_idempotent("/quotes", payload, 201, changed_body: payload(terms: "Outra condição"))

    assert_equal [1, body["id"]], [count("SELECT count(*) FROM quotes"), owner_query("SELECT id FROM quotes").first["id"]]
  end

  def test_list_filters_sorts_and_paginates
    other = create_customer(@actor, name: "Agência Norte", document: "11144477735")
    first = sent
    @clock.advance(60)
    second = draft
    @clock.advance(60)
    third = draft(customer_id: other.id)
    page = get!(200, "/quotes", { "limit" => "2" })

    assert_conforms page, "QuotePage"
    assert_equal [[third.code, second.code], 3, 2], [page["data"].map { |row| row["code"] }, page["pagination"]["total"], page["pagination"]["next_offset"]]
    assert_equal([first.code], get!(200, "/quotes", { "status" => "sent" })["data"].map { |row| row["code"] })
    assert_equal([third.code], get!(200, "/quotes", { "customer_id" => other.id })["data"].map { |row| row["code"] })
    assert_equal([second.code], get!(200, "/quotes", { "q" => second.code.downcase })["data"].map { |row| row["code"] })
    assert_equal([first.code, second.code, third.code], get!(200, "/quotes", { "sort" => "code" })["data"].map { |row| row["code"] })
    listed = get!(200, "/quotes", { "sort" => "created_at", "limit" => "1", "offset" => "1" })

    assert_equal [[second.code], 2], [listed["data"].map { |row| row["code"] }, listed["pagination"]["next_offset"]]
    assert_equal({ "amount_cents" => 90_000, "currency" => "BRL", "formatted" => "R$ 900,00" }, listed["data"].first["total"])
    [[{ "limit" => "0" }, "limite"], [{ "limit" => "101" }, "limite"], [{ "sort" => "valor" }, "ordenacao"], [{ "status" => "aberto" }, "situacao"],
     [{ "customer_id" => "x" }, "cliente"]].each do |params, field|
      get!(422, "/quotes", params)

      assert_equal [field], fields.keys, params.inspect
    end
    get!(403, "/quotes", {}, token: token(%w[reservations.read]))
  end

  def test_detail_lists_every_version_and_requires_the_read_scope
    quote = draft(fees: [D::Pricing::FeeRequest.catalog(fee_id: @fee.id, amount: nil)])
    uc(:revise_quote).call(@actor, quote.id, quote_input(terms: "Retirada na loja."))
    body = get!(200, "/quotes/#{quote.id}")

    assert_conforms body, "Quote"
    assert_equal [[2, 1], 2, nil], [body["versions"].map { |v| v["number"] }, body["current_version"], body["hold_reservation"]]
    assert_equal ["Retirada na loja.", nil], [body["versions"].first["terms"], body["versions"].first["sent_at"]]
    assert_equal 8_000, body["versions"].last["pricing"]["fees_cents"]
    refute body.key?("customer"), "o detalhe não traz nome nem documento do cliente"
    get!(403, "/quotes/#{quote.id}", {}, token: token(%w[quotes.write]))
    get!(200, "/quotes/#{quote.id}", {}, token: token(%w[quotes.read]))
  end

  def test_new_version_requires_a_change_and_keeps_the_customer
    quote = sent
    body = post!(201, "/quotes/#{quote.id}/versions", revision(terms: "Retirada na loja.", items: [{ "product_id" => @camera.id, "quantity" => 2 }]))

    assert_conforms body, "Quote"
    assert_equal ["draft", 2, 180_000, "/api/v1/quotes/#{quote.id}"],
                 [body["status"], body["current_version"], body["versions"].first["total"]["amount_cents"], location]
    post!(422, "/quotes/#{quote.id}/versions", revision(terms: "Retirada na loja.", items: [{ "product_id" => @camera.id, "quantity" => 2 }]))

    assert_equal({ "base" => ["nenhuma alteração em relação à versão 2"] }, fields)
    post!(422, "/quotes/#{quote.id}/versions", payload(terms: "Outra"))

    assert_equal({ "cliente" => ["o cliente não muda na nova versão"] }, fields)
    assert_idempotent("/quotes/#{quote.id}/versions", revision(terms: "Terceira"), 201, changed_body: revision(terms: "Quarta"))
  end

  def test_send_without_hold_and_with_hold_on_send
    plain = draft
    body = post!(200, "/quotes/#{plain.id}/send")

    assert_conforms body, "Quote"
    assert_equal ["sent", nil], [body["status"], body["hold_reservation"]]
    refute_nil body["versions"].first["sent_at"]
    held = draft(hold_policy: "hold_on_send", hold_minutes: 120)
    body = post!(200, "/quotes/#{held.id}/send")

    assert_conforms body, "Quote"
    assert_equal ["held", iso("2026-03-02T14:00:00Z")], body["hold_reservation"].values_at("status", "hold_expires_at")
    post!(409, "/quotes/#{plain.id}/send")

    assert_error "invalid_transition"
  end

  def test_hold_on_send_without_availability_is_a_conflict_with_shortages
    confirmed([line(@camera, 3)], period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z"))
    quote = draft(hold_policy: "hold_on_send", hold_minutes: 60)
    post!(409, "/quotes/#{quote.id}/send")

    assert_error "unavailable"
    assert_equal [@camera.id, 1, 0], json_body["error"]["details"]["shortages"].first.values_at("product_id", "requested", "available")
    assert_equal "draft", uc(:get_quote).call(@actor, quote.id)[:quote].status
    assert_idempotent("/quotes/#{draft.id}/send", {}, 200)
  end

  def test_approval_on_behalf_of_the_customer
    quote = sent
    post!(422, "/quotes/#{quote.id}/approve", { "approver_name" => "Maria" })

    assert_equal({ "versao" => ["informe um número inteiro"] }, fields)
    post!(422, "/quotes/#{quote.id}/approve", { "version" => "1", "approver_name" => 7 })

    assert_equal %w[aprovado_por versao], fields.keys.sort
    body = post!(200, "/quotes/#{quote.id}/approve", { "version" => 1, "approver_name" => "Maria Compradora" })

    assert_conforms body, "Quote"
    assert_equal ["approved", 1, "staff", "Maria Compradora"], body.values_at("status", "approved_version", "approved_by_type", "approved_by_name")
    assert_equal [{ "code" => quote.code, "version" => 1, "approved_by_type" => "staff", "approved_by_name" => "Maria Compradora", "ip" => "127.0.0.1" }],
                 audit_details("quote.approved")
  end

  def test_stale_version_is_refused
    quote = sent
    uc(:revise_quote).call(@actor, quote.id, quote_input(terms: "Nova"))
    uc(:send_quote).call(@actor, quote.id)
    post!(409, "/quotes/#{quote.id}/approve", { "version" => 1, "approver_name" => "Maria" })

    assert_error "stale_quote_version"
    post!(409, "/quotes/#{quote.id}/reject", { "reason" => "Caro", "version" => 1 })

    assert_error "stale_quote_version"
    assert_idempotent("/quotes/#{quote.id}/approve", { "version" => 2, "approver_name" => "Maria" }, 200,
                      changed_body: { "version" => 2, "approver_name" => "João" })
  end

  # A expiração é gravada à parte, sem aprovar; repetir a mesma chave não aprova (a chave não foi gravada).
  def test_expired_approval_records_the_expiration_without_approving
    quote = sent(valid_until: t("2026-03-03T12:00:00Z"))
    @clock.travel_to(t("2026-03-03T13:00:00Z"))
    key = next_key
    2.times do
      post!(409, "/quotes/#{quote.id}/approve", { "version" => 1, "approver_name" => "Maria" }, key: key)

      assert_error "quote_expired"
      refute_predicate self, :replayed?
    end
    data = uc(:get_quote).call(@actor, quote.id)[:quote]

    assert_equal ["expired", nil, nil], [data.status, data.approved_at, data.approved_version]
    assert_equal [1, 0], [audit_count("quote.expired"), audit_count("quote.approved")]
  end

  def test_rejection
    quote = sent
    post!(422, "/quotes/#{quote.id}/reject", { "version" => 1 })

    assert_equal ["motivo"], fields.keys
    post!(422, "/quotes/#{quote.id}/reject", { "reason" => "Caro", "version" => 1.5 })

    assert_equal ["versao"], fields.keys
    body = assert_idempotent("/quotes/#{quote.id}/reject", { "reason" => "Preço acima do orçamento" }, 200,
                             changed_body: { "reason" => "Outro motivo" })

    assert_conforms body, "Quote"
    assert_equal ["rejected", "Preço acima do orçamento"], body.values_at("status", "rejection_reason")
    refute_nil body["rejected_at"]
  end

  def test_conversion_creates_then_returns_the_same_reservation
    quote = approved
    post!(403, "/quotes/#{quote.id}/convert", {}, token: token(%w[quotes.read quotes.write]))

    assert_error "forbidden"
    first = assert_idempotent("/quotes/#{quote.id}/convert", {}, 201)

    assert_conforms first, "QuoteConversion"
    reservation = first["reservation"]

    assert_equal %w[confirmed quote converted], [reservation["status"], reservation["source"], first["quote"]["status"]]
    assert_equal "/api/v1/reservations/#{reservation["id"]}", @idempotent_location
    again = post!(200, "/quotes/#{quote.id}/convert")

    assert_conforms again, "QuoteConversion"
    assert_equal [reservation["id"], "/api/v1/reservations/#{reservation["id"]}"], [again["reservation"]["id"], location]
    assert_equal 1, count("SELECT count(*) FROM reservations")
    assert_equal reservation["id"], first["quote"]["reservation"]["id"]
  end

  def test_other_organization_ids_are_not_found_and_invalid_ids_are_refused
    foreign = beta_quote.id
    get!(404, "/quotes/#{foreign}")

    assert_error "not_found"
    post!(404, "/quotes/#{foreign}/versions", revision)
    post!(404, "/quotes/#{foreign}/send")
    post!(404, "/quotes/#{foreign}/approve", { "version" => 1, "approver_name" => "Maria" })
    post!(404, "/quotes/#{foreign}/reject", { "reason" => "Caro" })
    post!(404, "/quotes/#{foreign}/convert")

    assert_error "not_found"
    assert_empty get!(200, "/quotes")["data"]
    get!(422, "/quotes/abc")

    assert_equal({ "id" => ["identificador inválido"] }, fields)
    post!(422, "/quotes/abc/send")

    assert_error "validation_error"
    assert_equal "draft", uc(:get_quote).call(@beta[:actor], foreign)[:quote].status
  end
end
