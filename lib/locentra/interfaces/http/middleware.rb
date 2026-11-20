# frozen_string_literal: true

require "ipaddr"
require "securerandom"

module Locentra
  module Interfaces
    module HTTP
      # Identificação da requisição, log estruturado e métricas por rota modelo.
      #
      # O identificador recebido em X-Request-Id (formato restrito) ou gerado aqui é devolvido na
      # resposta, gravado no ator (auditoria, eventos da outbox e tarefas como correlation_id) e
      # registrado no log. Métodos fora da lista viram "OTHER" no rótulo, para que um cliente não
      # crie séries novas com métodos arbitrários.
      class RequestLogger
        REQUEST_ID = /\A[A-Za-z0-9._-]{8,64}\z/
        METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

        def initialize(app, logger:, metrics:)
          @app = app
          @logger = logger
          @metrics = metrics
        end

        def call(env)
          incoming = env["HTTP_X_REQUEST_ID"].to_s
          request_id = incoming.match?(REQUEST_ID) ? incoming : SecureRandom.uuid
          env["locentra.request_id"] = request_id
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, headers, body = @app.call(env)
          headers["x-request-id"] = request_id
          [status, headers, body]
        rescue StandardError => e
          status = 500
          @logger.error(event: "http.unhandled", request_id: request_id, error: e.class.name, message: e.message)
          [500, { "content-type" => "text/plain; charset=utf-8", "x-request-id" => request_id }, ["Erro interno. Referência: #{request_id}"]]
        ensure
          record(env, request_id, status, started)
        end

        private

        def record(env, request_id, status, started)
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          route = env["locentra.route"] || (env["PATH_INFO"].to_s.start_with?("/css", "/js", "/img") ? "static" : "unmatched")
          method = METHODS.include?(env["REQUEST_METHOD"]) ? env["REQUEST_METHOD"] : "OTHER"
          @metrics.increment("http_requests_total", method: method, route: route, status: status.to_s)
          @metrics.observe("http_request_duration_seconds", duration, route: route)
          return if ["static", "/health/live"].include?(route)

          @logger.info(event: "http.request", request_id: request_id, method: env["REQUEST_METHOD"], route: route, status: status,
                       duration_ms: (duration * 1000).round(1), organization_id: env["locentra.organization_id"],
                       actor_id: env["locentra.actor_id"])
        end
      end

      # IP do cliente. Sem proxies confiáveis configurados (TRUSTED_PROXIES), é o par da conexão
      # (REMOTE_ADDR) e nenhum cabeçalho é considerado. Com proxies configurados, e somente quando a
      # conexão vem de um deles, X-Forwarded-For é percorrido da direita para a esquerda e o primeiro
      # endereço que não é proxy confiável é o cliente. O cabeçalho `Forwarded` nunca é usado (proxies
      # comuns não o removem nem o reescrevem). O resultado vai para sessões, auditoria, aceites e
      # limites de taxa por IP.
      class ClientAddress
        def initialize(app, trusted:)
          @app = app
          @trusted = trusted
        end

        def call(env)
          env["locentra.client_ip"] = resolve(env)
          @app.call(env)
        end

        def resolve(env)
          remote = env["REMOTE_ADDR"].to_s
          return remote unless trusted?(remote)

          client = remote
          env["HTTP_X_FORWARDED_FOR"].to_s.split(",").map(&:strip).reverse_each do |hop|
            address = parse(hop)
            break unless address

            client = address.to_s
            break unless trusted?(client)
          end
          client
        end

        private

        def trusted?(address)
          ip = parse(address)
          ip ? @trusted.any? { |range| range.family == ip.family && range.include?(ip) } : false
        end

        def parse(text)
          text.to_s.include?("/") ? nil : IPAddr.new(text.to_s)
        rescue IPAddr::Error
          nil
        end
      end

      # Cabeçalhos de segurança, inclusive Content Security Policy sem scripts inline.
      class SecurityHeaders
        CSP = [
          "default-src 'self'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:", "font-src 'self'",
          "connect-src 'self'", "object-src 'none'", "base-uri 'none'", "frame-ancestors 'none'", "form-action 'self'"
        ].join("; ")

        def initialize(app, hsts:)
          @app = app
          @hsts = hsts
        end

        def call(env)
          status, headers, body = @app.call(env)
          headers["content-security-policy"] ||= CSP
          headers["x-content-type-options"] = "nosniff"
          headers["x-frame-options"] = "DENY"
          headers["referrer-policy"] = "same-origin"
          headers["permissions-policy"] = "camera=(), microphone=(), geolocation=()"
          headers["cross-origin-opener-policy"] = "same-origin"
          headers["strict-transport-security"] = "max-age=31536000; includeSubDomains" if @hsts
          headers["cache-control"] ||= "no-store"
          [status, headers, body]
        end
      end

      # Limite de tamanho do corpo. Requisições com Content-Length acima do limite são recusadas
      # antes de qualquer leitura; rotas de upload declaram limite próprio.
      class BodyLimit
        def initialize(app, default:, uploads:, upload_prefixes:)
          @app = app
          @default = default
          @uploads = uploads
          @upload_prefixes = upload_prefixes
        end

        def call(env)
          limit = @upload_prefixes.any? { |prefix| env["PATH_INFO"].to_s.start_with?(prefix) } ? @uploads : @default
          length = env["CONTENT_LENGTH"].to_s
          if (!length.empty? && length.to_i > limit) || (length.empty? && env["HTTP_TRANSFER_ENCODING"].to_s.include?("chunked"))
            return [413, { "content-type" => "text/plain; charset=utf-8" }, ["Corpo da requisição acima do limite"]]
          end

          @app.call(env)
        end
      end
    end
  end
end
