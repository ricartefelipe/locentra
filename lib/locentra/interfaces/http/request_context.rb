# frozen_string_literal: true

require "rack"
require "json"
require "openssl"

module Locentra
  module Interfaces
    module HTTP
      class BadRequest < StandardError; end
      class PayloadTooLarge < StandardError; end

      class Unauthenticated < StandardError
        def initialize(message = "Autenticação necessária") = super
      end

      class CsrfFailure < StandardError
        def initialize(message = "O formulário expirou ou a sessão mudou. Recarregue a página e tente novamente.") = super
      end

      # Sessão válida usada na área de outro tipo de acesso (portal do cliente x equipe). `home` é o
      # início da área da sessão; páginas redirecionam para ele e as demais requisições recebem 403.
      class WrongArea < StandardError
        attr_reader :home

        def initialize(home)
          @home = home
          super("Esta área não está disponível para a sessão atual")
        end
      end

      # Contexto de uma requisição: parâmetros (via parsers do Rack), sessão, ator e CSRF.
      class RequestContext
        JSON_MAX_NESTING = 10
        MAX_JSON_BYTES = 1_048_576
        # Parser de formulários por requisição: profundidade, quantidade e tamanho limitados.
        QUERY_PARSER = Rack::QueryParser.new(Rack::QueryParser::Params, 4, bytesize_limit: 1_048_576, params_limit: 500)

        attr_reader :env, :rack, :route_params, :request_id
        attr_accessor :session, :actor, :organization, :response_headers

        def initialize(env, route_params, request_id)
          @env = env
          @rack = Rack::Request.new(env)
          @rack.query_parser = QUERY_PARSER
          @route_params = route_params
          @request_id = request_id
          @response_headers = {}
        end

        def verb = rack.request_method
        def path = rack.path_info
        # Definido pelo middleware ClientAddress; sem ele (aplicação montada sem a pilha), o par da conexão.
        def ip = env["locentra.client_ip"] || env["REMOTE_ADDR"]
        def user_agent = env["HTTP_USER_AGENT"].to_s
        def get? = %w[GET HEAD].include?(verb)

        def param(name)
          return route_params[name.to_s] if route_params.key?(name.to_s)

          form[name.to_s]
        end

        # Parâmetros de formulário e query string. O parser do Rack aplica limites de quantidade e
        # profundidade (configurados no boot); valores aninhados além do esperado são rejeitados.
        def form
          @form ||= begin
            merged = rack.GET.merge(rack.POST)
            merged.each_value { |value| raise BadRequest, "parâmetro aninhado não suportado" if value.is_a?(Hash) && value.size > 200 }
            merged
          end
        rescue Rack::QueryParser::ParamsTooDeepError, Rack::QueryParser::QueryLimitError, Rack::Multipart::MultipartPartLimitError,
               Rack::Multipart::MultipartTotalPartLimitError
          raise BadRequest, "parâmetros acima do limite"
        rescue Rack::QueryParser::InvalidParameterError, Rack::QueryParser::ParameterTypeError, Rack::Multipart::EmptyContentError,
               Rack::Multipart::Error, EOFError
          raise BadRequest, "parâmetros inválidos"
        end

        def query(name) = rack.GET[name.to_s]

        def json
          @json ||= parse_json
        end

        def body_bytes
          @body_bytes ||= begin
            input = rack.body
            input ? (input.read(MAX_JSON_BYTES + 1) || "").b.force_encoding(Encoding::UTF_8) : +""
          ensure
            input&.rewind if input.respond_to?(:rewind)
          end
        end

        def cookie(name) = rack.cookies[name]

        private

        def parse_json
          unless rack.media_type == "application/json"
            raise BadRequest, "Content-Type deve ser application/json" unless rack.body.nil? || body_bytes.empty?

            return {}
          end
          text = body_bytes
          raise PayloadTooLarge, "corpo JSON acima do limite" if text.bytesize > MAX_JSON_BYTES

          parsed = text.empty? ? {} : JSON.parse(text, max_nesting: JSON_MAX_NESTING, create_additions: false)
          raise BadRequest, "o corpo deve ser um objeto JSON" unless parsed.is_a?(Hash)

          parsed
        rescue JSON::NestingError
          raise BadRequest, "JSON com profundidade acima do limite"
        rescue JSON::ParserError
          raise BadRequest, "JSON inválido"
        end

        public

        def csrf_token = session && session["csrf_token"]

        def verify_csrf!
          return if get?

          sent = env["HTTP_X_CSRF_TOKEN"] || form["_csrf"]
          expected = csrf_token
          raise CsrfFailure unless sent && expected && Rack::Utils.secure_compare(sent.to_s, expected.to_s)
        end

        def can?(permission)
          actor && Application::Authorizer.allowed?(actor, permission)
        end

        def time_zone
          @time_zone ||= organization ? organization.time_zone : Domain::TimeZone.new("America/Sao_Paulo")
        end

        def wants_json?
          path.start_with?("/api/") || rack.media_type == "application/json" || env["HTTP_ACCEPT"].to_s.start_with?("application/json")
        end
      end

      # Mensagem de retorno entre redirecionamentos, em cookie assinado com HMAC.
      class Flash
        COOKIE = "locentra_flash"

        def initialize(secret)
          @secret = secret
        end

        def read(request)
          raw = request.cookie(COOKIE)
          return nil if raw.to_s.empty?

          payload, signature = raw.split("--", 2)
          return nil unless signature && Rack::Utils.secure_compare(sign(payload), signature)

          JSON.parse(payload.unpack1("m0"))
        rescue ArgumentError, JSON::ParserError
          nil
        end

        def write(response, type, text, secure:)
          payload = [JSON.generate({ "type" => type, "text" => text.to_s[0, 300] })].pack("m0")
          response.set_cookie(COOKIE, value: "#{payload}--#{sign(payload)}", path: "/", httponly: true, secure: secure, same_site: :lax,
                                      max_age: 60)
        end

        def clear(response, secure:)
          response.delete_cookie(COOKIE, path: "/", httponly: true, secure: secure, same_site: :lax)
        end

        private

        def sign(payload) = OpenSSL::HMAC.hexdigest("SHA256", @secret, "flash:#{payload}")
      end
    end
  end
end
