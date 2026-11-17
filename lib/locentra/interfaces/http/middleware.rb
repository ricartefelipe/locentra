# frozen_string_literal: true

require "securerandom"

module Locentra
  module Interfaces
    module HTTP
      # Identificação da requisição, log estruturado e métricas por rota modelo.
      class RequestLogger
        REQUEST_ID = /\A[A-Za-z0-9._-]{8,64}\z/

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
          @metrics.increment("http_requests_total", method: env["REQUEST_METHOD"], route: route, status: status.to_s)
          @metrics.observe("http_request_duration_seconds", duration, route: route)
          return if ["static", "/health/live"].include?(route)

          @logger.info(event: "http.request", request_id: request_id, method: env["REQUEST_METHOD"], route: route, status: status,
                       duration_ms: (duration * 1000).round(1), organization_id: env["locentra.organization_id"],
                       actor_id: env["locentra.actor_id"])
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
