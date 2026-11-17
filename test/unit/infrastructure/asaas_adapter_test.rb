# frozen_string_literal: true

require_relative "../unit_helper"
require "locentra/infrastructure/crypto"
require "locentra/infrastructure/payments/asaas_format"
require "locentra/infrastructure/payments/asaas"
require "socket"

# Adaptador do Asaas com cliente HTTP falso: verifica URL base, autenticação, corpo das requisições
# e tradução de respostas e erros. Nenhuma credencial real e nenhuma chamada de rede.
class AsaasAdapterTest < UnitTest
  I = Locentra::Infrastructure::Payments
  FN = Locentra::Application::Finance

  Request = Data.define(:verb, :url, :headers, :body)

  # Cliente HTTP falso: devolve respostas programadas por (verbo, caminho) e registra as requisições.
  class FakeHttp
    attr_reader :requests

    def initialize(routes)
      @routes = routes
      @requests = []
    end

    def request(verb, url, headers:, body: nil)
      @requests << Request.new(verb: verb, url: url, headers: headers, body: body)
      path = URI.parse(url).path.delete_prefix("/v3")
      response = @routes.fetch([verb, path.to_sym]) { raise "rota não programada: #{verb} #{path}" }
      response = response.shift if response.is_a?(Array)
      raise response if response.is_a?(Exception)

      I::HttpClient::Response.new(status: response.fetch(:status, 200), body: response.fetch(:body))
    end
  end

  def box = @box ||= Locentra::Infrastructure::SecretBox.new("chave-de-teste-com-tamanho-suficiente")

  def account(environment: "sandbox")
    { "id" => "acc", "organization_id" => "org", "provider" => "asaas", "environment" => environment,
      "api_key_ciphertext" => box.encrypt("$aact_hmlg_chave_de_teste") }
  end

  def adapter(routes) = I::Asaas.new(http: FakeHttp.new(routes), box: box)

  def charge_request
    FN::ChargeRequest.new(external_reference: "0190a1b2-0000-7000-8000-000000000001", amount: Domain::Money.new(15_050), payment_method: "pix",
                          due_on: Date.new(2026, 3, 5), description: "Cobrança da reserva R-000001",
                          customer: FN::CustomerRef.new(id: "cust-1", name: "Cliente Teste", document: "52998224725", email: "cliente@example.test"),
                          scenario: nil)
  end

  def payment_json(status: "PENDING", value: "150.50", deleted: false)
    %({"id":"pay_123","status":"#{status}","value":#{value},"externalReference":"0190a1b2-0000-7000-8000-000000000001",
       "invoiceUrl":"https://sandbox.asaas.com/i/pay_123","billingType":"PIX","deleted":#{deleted}})
  end

  def test_create_charge_creates_customer_and_sends_external_reference
    gateway = adapter({ %i[get /customers] => { body: '{"object":"list","hasMore":false,"data":[]}' },
                        %i[post /customers] => { body: '{"id":"cus_000005401844"}' },
                        %i[post /payments] => { body: payment_json } })
    charge = gateway.create_charge(account, charge_request)
    requests = gateway.instance_variable_get(:@http).requests

    assert_equal %w[pay_123 pending 15050 https://sandbox.asaas.com/i/pay_123],
                 [charge.provider_payment_id, charge.status, charge.amount.cents.to_s, charge.invoice_url]
    assert_equal "https://api-sandbox.asaas.com/v3/customers?externalReference=cust-1&limit=100&offset=0", requests[0].url
    customer = JSON.parse(requests[1].body)

    assert_equal ["Cliente Teste", "52998224725", "cust-1"], customer.values_at("name", "cpfCnpj", "externalReference")
    payment = requests[2]

    assert_equal "https://api-sandbox.asaas.com/v3/payments", payment.url
    assert_includes payment.body, %("value":150.50), "valor decimal exato, sem Float"
    assert_equal({ "customer" => "cus_000005401844", "billingType" => "PIX", "dueDate" => "2026-03-05",
                   "externalReference" => charge_request.external_reference },
                 JSON.parse(payment.body).slice("customer", "billingType", "dueDate", "externalReference"))
    assert_equal "$aact_hmlg_chave_de_teste", payment.headers["access_token"]
    assert_match(/\ALocentra/, payment.headers["User-Agent"])
    assert_equal "application/json", payment.headers["Content-Type"]
    assert_nil requests[0].body, "GET sem corpo"
  end

  def test_existing_customer_is_reused_and_production_url_is_used
    gateway = adapter({ %i[get /customers] => { body: '{"data":[{"id":"cus_removido","deleted":true},{"id":"cus_1","deleted":false}]}' },
                        %i[post /payments] => { body: payment_json } })
    gateway.create_charge(account(environment: "production"), charge_request.with(payment_method: "card"))
    requests = gateway.instance_variable_get(:@http).requests

    assert_equal 2, requests.size
    assert(requests.all? { |r| r.url.start_with?("https://api.asaas.com/v3/") })
    assert_equal %w[cus_1 CREDIT_CARD], JSON.parse(requests[1].body).values_at("customer", "billingType")
  end

  def test_lookup_by_external_reference_listing_and_refunds
    list = %({"object":"list","hasMore":false,"data":[#{payment_json(status: "RECEIVED")}]})
    done = '{"id":"pay_abc","refunds":[{"value":40.0,"description":"Locentra reembolso f1","status":"DONE","endToEndIdentifier":"E1"}]}'
    refunded = '{"id":"pay_abc","status":"REFUNDED","refunds":[{"value":40,"description":"Locentra reembolso f2","status":"PENDING"}]}'
    gateway = adapter({ %i[get /payments] => [{ body: list }, { body: %({"hasMore":true,"data":[#{payment_json}]}) }, { body: list }],
                        %i[get /payments/pay_abc] => { body: done }, %i[post /payments/pay_abc/refund] => { body: refunded } })
    found = gateway.find_by_external_reference(account, "0190a1b2-0000-7000-8000-000000000001")

    assert_equal([%w[pay_123 confirmed]], found.map { |c| [c.provider_payment_id, c.status] })
    listed = gateway.list_charges(account, since: Time.utc(2026, 2, 1, 12))

    assert_equal 2, listed.size, "paginação até hasMore=false"
    urls = gateway.instance_variable_get(:@http).requests.map(&:url)

    assert_includes urls[1], "dateCreated%5Bge%5D=2026-02-01"
    assert_includes urls[2], "offset=100"
    refunds = gateway.refunds(account, "pay_abc")

    assert_equal([["E1", 4_000, "Locentra reembolso f1"]], refunds.map { |r| [r.reference, r.amount.cents, r.description] })
    refund = gateway.refund(account, "pay_abc", amount: Domain::Money.new(4_000), description: "Locentra reembolso f2")

    assert_equal [4_000, "PENDING"], [refund.amount.cents, refund.status]
    assert_includes gateway.instance_variable_get(:@http).requests.last.body, %("value":40.00)
    assert_raises(FN::ProviderRejected) { gateway.refunds(account, "../../customers") }
  end

  def test_refund_response_without_matching_item
    gateway = adapter({ %i[post /payments/pay_9/refund] => { body: '{"id":"pay_9","status":"REFUND_REQUESTED"}' } })
    refund = gateway.refund(account, "pay_9", amount: Domain::Money.new(100), description: "Locentra reembolso f9")

    assert_equal %w[pay_9 REFUND_REQUESTED], [refund.reference, refund.status]
  end

  def test_http_errors_are_translated
    cases = {
      { status: 401, body: '{"errors":[{"code":"invalid_access_token"}]}' } => FN::ProviderRejected,
      { status: 400, body: '{"errors":[{"code":"invalid_value","description":"Valor inválido"}]}' } => FN::ProviderRejected,
      { status: 422, body: "<html>" } => FN::ProviderRejected,
      { status: 429, body: "" } => FN::ProviderUnavailable,
      { status: 503, body: "" } => FN::ProviderTimeout
    }
    cases.each do |response, error|
      gateway = adapter({ %i[get /customers] => { body: '{"data":[{"id":"cus_1"}]}' }, %i[post /payments] => response })

      assert_raises(error, response.inspect) { gateway.create_charge(account, charge_request) }
    end
    rejected = assert_raises(FN::ProviderRejected) do
      adapter({ %i[get /customers] => { body: '{"data":[{"id":"cus_1"}]}' },
                %i[post /payments] => { status: 400, body: '{"errors":[{"description":"Cliente inválido"}]}' } }).create_charge(account, charge_request)
    end
    assert_match(/Cliente inválido/, rejected.message)
    assert_raises(FN::ProviderUnavailable) { adapter({ %i[get /payments] => { status: 502, body: "" } }).list_charges(account, since: Time.now) }
    assert_raises(FN::ProviderTimeout) do
      adapter({ %i[get /payments] => FN::ProviderTimeout.new("sem resposta") }).find_by_external_reference(account, "x")
    end
  end

  def test_webhook_events_and_statuses
    gateway = adapter({})
    received = payment_json(status: "RECEIVED", value: "100.5")
    event = gateway.parse_webhook(%({"id":"evt_1","event":"PAYMENT_RECEIVED","dateCreated":"2024-06-12 16:45:03","payment":#{received}}))

    assert_equal %w[evt_1 PAYMENT_RECEIVED confirm pay_123 confirmed], [event.event_id, event.event_type, event.action, event.provider_payment_id, event.status]
    assert_equal 10_050, event.amount.cents
    assert_equal "cancel", gateway.parse_webhook(%({"id":"e2","event":"PAYMENT_DELETED","payment":{"id":"p","deleted":true}})).action
    overdue = gateway.parse_webhook(%({"id":"e3","event":"PAYMENT_OVERDUE","payment":{"id":"p","status":"OVERDUE"}}))

    assert_equal ["ignore", "pending", nil], [overdue.action, overdue.status, overdue.amount]
    invalid = ['{"event":"PAYMENT_RECEIVED","payment":{"id":"p"}}', '{"id":"e","event":"X"}', "[]", "nao-e-json"] +
              ["1.234", '"abc"', "null"].map { |value| %({"id":"e","event":"X","payment":{"id":"p","value":#{value}}}) }

    invalid.each do |body|
      assert_raises(Domain::ValidationError, body) { gateway.parse_webhook(body) }
    end
    statuses = %w[PENDING CONFIRMED RECEIVED_IN_CASH REFUNDED CHARGEBACK_REQUESTED DESCONHECIDO].map { |s| I::AsaasFormat.status(s) }

    assert_equal %w[pending confirmed confirmed refunded disputed pending], statuses
    assert_nil I::AsaasFormat.safe_url("javascript:alert(1)")
    assert_equal 1_000, I::AsaasFormat.cents(10).cents
  end

  def test_http_client_requires_https
    assert_raises(FN::ProviderRejected) { I::HttpClient.new.request(:get, "http://api.asaas.example/v3/payments", headers: {}) }
  end

  # Conexão recusada (porta local fechada): a requisição não saiu e pode ser repetida.
  def test_http_client_maps_refused_connection_to_unavailable
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    assert_raises(FN::ProviderUnavailable) do
      I::HttpClient.new(open_timeout: 1, read_timeout: 1).request(:post, "https://127.0.0.1:#{port}/v3/payments", headers: {}, body: "{}")
    end
  end
end
