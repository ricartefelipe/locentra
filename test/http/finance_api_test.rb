# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/finance_support"

# API v1 de pagamentos e reembolsos com Idempotency-Key.
class FinanceApiTest < HttpTest
  include FinanceHelpers

  def setup
    super
    finance_setup
    @reservation = booking
    sync(@reservation)
    @rental = rental_of(@reservation)
    @token = uc(:create_credential).call(@actor, name: "ERP financeiro", scopes: %w[finance.read finance.write finance.refund deposits.manage],
                                                 expires_in_days: 30)["token"]
  end

  def auth(key = nil, token: @token)
    headers = { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "application/json" }
    key ? headers.merge("HTTP_IDEMPOTENCY_KEY" => key) : headers
  end

  def create_payment(payload, key) = post("/api/v1/payments", JSON.generate(payload), auth(key))

  def test_manual_payment_is_idempotent
    payload = { "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 4_000, "notes" => "Pix recebido no balcão" }
    create_payment(payload, "pagamento-0001")

    assert_equal 201, last_response.status, last_response.body
    first = json_body

    assert_equal %w[confirmed manual], first.values_at("status", "provider")
    assert_equal 4_000, first["amount"]["amount_cents"]
    create_payment(payload, "pagamento-0001")

    assert_equal 201, last_response.status
    assert_equal "true", last_response.headers["idempotent-replayed"]
    assert_equal first["id"], json_body["id"]
    create_payment(payload.merge("amount_cents" => 4_001), "pagamento-0001")

    assert_equal 409, last_response.status
    assert_equal "idempotency_key_reused", json_body["error"]["code"]
    assert_equal 1, count("payments")
    assert_equal 6_000, balance_of(@rental).outstanding.cents
  end

  def test_payment_validation_and_errors
    create_payment({ "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 100 }, nil)

    assert_equal 422, last_response.status
    create_payment({ "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 10.5 }, "pagamento-float")

    assert_equal 422, last_response.status
    assert_equal ["amount_cents"], json_body["error"]["details"]["fields"].keys
    create_payment({ "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 10_001 }, "pagamento-acima")

    assert_equal 409, last_response.status
    create_payment({ "receivable_id" => SecureRandom.uuid, "method" => "pix", "amount_cents" => 100 }, "pagamento-inexistente")

    assert_equal 404, last_response.status
    create_payment({ "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 100, "paid_at" => "ontem" }, "pagamento-data")

    assert_equal 422, last_response.status
    assert_equal 0, count("idempotency_keys", "response_status > 0"), "falhas não gravam a chave"
  end

  def test_deposit_payment_and_payment_details
    deposit = uc(:open_deposit).call(@actor, @reservation.id, kind: "paid_deposit")
    create_payment({ "deposit_id" => deposit.id, "method" => "cash", "amount_cents" => 30_000 }, "caucao-0001")

    assert_equal 201, last_response.status
    assert_equal "deposit", json_body["purpose"]
    get "/api/v1/payments/#{json_body["id"]}", {}, auth

    assert_equal 200, last_response.status
    assert_equal [], json_body["refunds"]
    assert_equal 0, json_body["refundable"]["amount_cents"], "caução não é reembolsada como pagamento de cobrança"
  end

  def test_refunds_are_idempotent_and_limited
    payment = pay(@rental, 10_000)
    post "/api/v1/payments/#{payment.id}/refunds", JSON.generate("amount_cents" => 6_000, "reason" => "Devolução antecipada"), auth("reembolso-0001")

    assert_equal 201, last_response.status, last_response.body
    refund_id = json_body["id"]

    assert_equal "confirmed", json_body["status"]
    post "/api/v1/payments/#{payment.id}/refunds", JSON.generate("amount_cents" => 6_000, "reason" => "Devolução antecipada"), auth("reembolso-0001")

    assert_equal refund_id, json_body["id"]
    assert_equal "true", last_response.headers["idempotent-replayed"]
    post "/api/v1/payments/#{payment.id}/refunds", JSON.generate("amount_cents" => 6_000, "reason" => "Segunda devolução"), auth("reembolso-0002")

    assert_equal 409, last_response.status
    assert_equal "refund_exceeds_eligible", json_body["error"]["code"]
    get "/api/v1/payments/#{payment.id}", {}, auth

    assert_equal 4_000, json_body["refundable"]["amount_cents"]
    assert_equal 1, json_body["refunds"].size
  end

  def test_scopes_and_tenant_isolation
    limited = uc(:create_credential).call(@actor, name: "Somente leitura", scopes: %w[finance.read], expires_in_days: 1)["token"]
    create_payment({ "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 100 }, "pagamento-escopo")
    post "/api/v1/payments", JSON.generate("receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 100),
         auth("pagamento-escopo-2", token: limited)

    assert_equal 403, last_response.status
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    foreign = uc(:create_credential).call(other[:actor], name: "Beta", scopes: %w[finance.read finance.write], expires_in_days: 1)["token"]
    payment_id = owner_query("SELECT id FROM payments").first["id"]
    get "/api/v1/payments/#{payment_id}", {}, auth(token: foreign)

    assert_equal 404, last_response.status
    post "/api/v1/payments", JSON.generate("receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 100), auth("pagamento-beta", token: foreign)

    assert_equal 404, last_response.status
  end
end
