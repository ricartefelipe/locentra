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
        INVALID_TEXT = "texto com codificação inválida ou caractere nulo"
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
            merged.each do |key, value|
              raise BadRequest, "parâmetro aninhado não suportado" if value.is_a?(Hash) && value.size > 200
              raise BadRequest, "parâmetros com #{INVALID_TEXT}" unless clean_text?(key) && clean_param?(value)
            end
            merged
          end
        rescue Rack::QueryParser::ParamsTooDeepError, Rack::QueryParser::QueryLimitError, Rack::Multipart::MultipartPartLimitError,
               Rack::Multipart::MultipartTotalPartLimitError
          raise BadRequest, "parâmetros acima do limite"
        rescue Rack::QueryParser::InvalidParameterError, Rack::QueryParser::ParameterTypeError, Rack::Multipart::EmptyContentError,
               Rack::Multipart::Error, EOFError
          raise BadRequest, "parâmetros inválidos"
        end

        def query(name)
          value = rack.GET[name.to_s]
          raise Domain::ValidationError.field(name.to_s, INVALID_TEXT) unless clean_text?(value)

          value
        end

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

          check_json_text!(parsed, nil)
          parsed
        rescue JSON::NestingError
          raise BadRequest, "JSON com profundidade acima do limite"
        rescue JSON::ParserError
          raise BadRequest, "JSON inválido"
        end

        # Textos recebidos precisam ser UTF-8 válido e sem caractere nulo, que o banco não armazena: o
        # erro sai como erro do cliente (no campo, quando há um) e não como falha interna. Uma parte
        # multipart text/plain com outro charset chega nessa codificação (ASCII-8BIT é sempre "válida"):
        # só é aceita quando o texto é ASCII puro, compatível com UTF-8.
        def clean_text?(value)
          return true unless value.is_a?(String)

          value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?) && !value.include?("\u0000")
        end

        # Parâmetro de formulário em qualquer nível (nome[chave], nome[], nome[chave][]): chaves e valores.
        # O Hash de arquivo do multipart (com :tempfile) não é texto e fica de fora.
        def clean_param?(value)
          case value
          when Hash then value.key?(:tempfile) || value.all? { |key, item| clean_text?(key) && clean_param?(item) }
          when Array then value.all? { |item| clean_param?(item) }
          else clean_text?(value)
          end
        end

        # No JSON, o erro aponta a chave de primeiro nível que contém o texto.
        def check_json_text!(node, field)
          case node
          when String then raise Domain::ValidationError.field(field || "corpo", INVALID_TEXT) unless clean_text?(node)
          when Array then node.each { |item| check_json_text!(item, field) }
          when Hash
            node.each do |key, value|
              check_json_text!(key, field)
              check_json_text!(value, field || key)
            end
          end
        end

        public

        def csrf_token = session && session["csrf_token"]

        def verify_csrf!
          return if get?

          sent = env["HTTP_X_CSRF_TOKEN"] || form["_csrf"]
          expected = csrf_token
          raise CsrfFailure unless sent && expected && Rack::Utils.secure_compare(sent.to_s, expected.to_s)
        end

        # Formulários públicos (sem sessão, portanto sem token CSRF): recusa envios de outro site,
        # identificados por Sec-Fetch-Site ou por Origin diferente da própria aplicação. Evita que uma
        # página de terceiros conecte a vítima à conta de quem atacou (CSRF de login). Clientes que não
        # enviam nenhum dos cabeçalhos (fora de navegadores) não são afetados.
        def verify_origin!(allowed = [])
          return if get?
          raise CsrfFailure if env["HTTP_SEC_FETCH_SITE"] == "cross-site"

          origin = env["HTTP_ORIGIN"].to_s
          return if origin.empty?
          raise CsrfFailure unless (allowed + [rack.base_url]).include?(origin)
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
