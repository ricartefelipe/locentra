# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Locentra
  module Infrastructure
    module Payments
      # Cliente HTTPS mínimo para o provedor. Distingue requisição não enviada (pode repetir) de
      # resultado desconhecido (tempo esgotado depois do envio).
      class HttpClient
        Response = Data.define(:status, :body)
        FN = Application::Finance
        MAX_BODY = 2_097_152
        VERBS = { get: Net::HTTP::Get, post: Net::HTTP::Post }.freeze

        def initialize(open_timeout: 5, read_timeout: 20)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        def request(verb, url, headers:, body: nil)
          uri = URI.parse(url)
          raise FN::ProviderRejected, "o provedor exige HTTPS" unless uri.is_a?(URI::HTTPS)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.write_timeout = @read_timeout
          request = VERBS.fetch(verb).new(uri.request_uri, headers)
          request.body = body if body
          response = http.request(request)
          Response.new(status: response.code.to_i, body: response.body.to_s.byteslice(0, MAX_BODY))
        rescue Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError => e
          raise FN::ProviderUnavailable, "conexão com o provedor não estabelecida (#{e.class.name})"
        rescue Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
          raise FN::ProviderTimeout, "sem resposta conclusiva do provedor (#{e.class.name})"
        end
      end

      # Adaptador do Asaas (API v3), conforme a documentação oficial (docs.asaas.com):
      # - URL base: sandbox https://api-sandbox.asaas.com/v3, produção https://api.asaas.com/v3;
      # - autenticação pelo cabeçalho `access_token` e `User-Agent` obrigatório;
      # - POST /customers (cliente por externalReference), POST /payments com externalReference;
      # - GET /payments?externalReference= para localizar uma cobrança após tempo esgotado;
      # - GET /payments?dateCreated[ge]= paginado (limit/offset/hasMore) para a conciliação;
      # - POST /payments/{id}/refund para estorno (total ou parcial, `value` e `description`) e
      #   GET /payments/{id}/refunds para a situação dos estornos (PENDING, AWAITING_*, CANCELLED, DONE);
      # - webhooks com o token no cabeçalho `asaas-access-token` e `id` do evento para deduplicação.
      # A integração real não foi exercitada: os testes usam cliente HTTP falso.
      class Asaas
        FN = Application::Finance
        PRODUCTION_URL = "https://api.asaas.com/v3"
        SANDBOX_URL = "https://api-sandbox.asaas.com/v3"
        PAGE = 100
        MAX_PAGES = 10

        def initialize(http:, box:, sandbox_url: SANDBOX_URL, user_agent: "Locentra/#{VERSION}")
          @http = http
          @box = box
          @sandbox_url = sandbox_url
          @user_agent = user_agent
        end

        def create_charge(account, request)
          customer = ensure_customer(account, request.customer)
          data = call(account, :post, "/payments", body: {
                        "customer" => customer, "billingType" => AsaasFormat::BILLING_TYPES.fetch(request.payment_method),
                        "value" => AsaasFormat.decimal(request.amount), "dueDate" => request.due_on.iso8601,
                        "description" => request.description.to_s[0, 500], "externalReference" => request.external_reference
                      })
          AsaasFormat.charge(data)
        end

        def find_by_external_reference(account, reference)
          page(account, "/payments", "externalReference" => reference.to_s).map { |data| AsaasFormat.charge(data) }
        end

        # `dateCreated` do Asaas é a data local do provedor: a consulta começa um dia antes de `since`
        # para que a listagem cubra toda a janela local. Depois de MAX_PAGES páginas com `hasMore`, a
        # listagem é marcada como incompleta (nunca usada como prova de ausência).
        def list_charges(account, since:)
          results = []
          from = (since - 86_400).utc.strftime("%Y-%m-%d")
          MAX_PAGES.times do |index|
            body = call(account, :get, "/payments", query: { "dateCreated[ge]" => from, "limit" => PAGE, "offset" => index * PAGE })
            results.concat(Array(body["data"]).map { |data| AsaasFormat.charge(data) })
            return FN::ChargeListing.new(charges: results, complete: true) unless body["hasMore"] == true
          end
          FN::ChargeListing.new(charges: results, complete: false)
        end

        def refunds(account, provider_payment_id)
          page(account, "/payments/#{segment(provider_payment_id)}/refunds", {}).map { |item| refund_of(item) }
        end

        # A resposta é a cobrança com a lista `refunds`; sem o item do pedido, a situação fica em
        # andamento e é confirmada por consulta posterior.
        def refund(account, provider_payment_id, amount:, description:)
          data = call(account, :post, "/payments/#{segment(provider_payment_id)}/refund",
                      body: { "value" => AsaasFormat.decimal(amount), "description" => description })
          item = Array(data["refunds"]).rfind { |r| r.is_a?(Hash) && r["description"].to_s.include?(description) }
          item ? refund_of(item) : FN::ProviderRefund.new(reference: data["id"].to_s, description: description, amount: amount, status: "pending")
        end

        def parse_webhook(text) = AsaasFormat.parse_event(text)

        private

        def ensure_customer(account, customer)
          found = page(account, "/customers", "externalReference" => customer.id).find { |c| c["deleted"] != true }
          return found.fetch("id") if found

          body = { "name" => customer.name, "cpfCnpj" => customer.document, "externalReference" => customer.id, "notificationDisabled" => true }
          body["email"] = customer.email if customer.email
          call(account, :post, "/customers", body: body).fetch("id")
        end

        def page(account, path, query)
          Array(call(account, :get, path, query: query.merge("limit" => PAGE, "offset" => 0))["data"])
        end

        def call(account, verb, path, query: nil, body: nil)
          url = "#{base_url(account)}#{path}#{"?#{URI.encode_www_form(query)}" if query}"
          headers = { "access_token" => @box.decrypt(account.fetch("api_key_ciphertext")), "User-Agent" => @user_agent, "Accept" => "application/json" }
          headers["Content-Type"] = "application/json" if body
          handle(verb, @http.request(verb, url, headers: headers, body: body && JSON.generate(body)))
        end

        def handle(verb, response)
          case response.status
          when 200..299 then object!(AsaasFormat.parse_json(response.body))
          when 401, 403 then raise FN::ProviderRejected, "credencial recusada pelo Asaas (HTTP #{response.status})"
          when 400, 404, 409, 422 then raise FN::ProviderRejected, error_message(response)
          when 429 then raise FN::ProviderUnavailable, "limite de requisições do Asaas atingido"
          else
            # Erro do servidor após um POST: a cobrança pode ter sido criada; nunca repetir às cegas.
            raise FN::ProviderTimeout, "resposta HTTP #{response.status} do Asaas; resultado desconhecido" if verb == :post

            raise FN::ProviderUnavailable, "Asaas indisponível (HTTP #{response.status})"
          end
        end

        def object!(data)
          raise Domain::ValidationError.field("corpo", "resposta inesperada do provedor") unless data.is_a?(Hash)

          data
        end

        def error_message(response)
          errors = AsaasFormat.parse_json(response.body)["errors"]
          descriptions = Array(errors).filter_map { |e| e["description"] if e.is_a?(Hash) }
          "Asaas recusou a requisição (HTTP #{response.status}): #{descriptions.join("; ")[0, 300]}"
        rescue Domain::ValidationError
          "Asaas recusou a requisição (HTTP #{response.status})"
        end

        def base_url(account) = account["environment"] == "production" ? PRODUCTION_URL : @sandbox_url

        def segment(id)
          text = id.to_s
          raise FN::ProviderRejected, "identificador de cobrança inválido" unless text.match?(/\A[A-Za-z0-9_-]{1,100}\z/)

          text
        end

        def refund_of(item)
          FN::ProviderRefund.new(reference: (item["endToEndIdentifier"] || item["transactionReceiptUrl"] || item["dateCreated"]).to_s,
                                 description: item["description"].to_s, amount: AsaasFormat.cents(item["value"]),
                                 status: AsaasFormat.refund_status(item["status"]))
        end
      end
    end
  end
end
