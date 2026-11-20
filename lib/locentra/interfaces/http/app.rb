# frozen_string_literal: true

require "rack"
require_relative "router"
require_relative "views"
require_relative "request_context"
require_relative "middleware"
require_relative "controller"
require_relative "authenticator"
require_relative "routes"

module Locentra
  module Interfaces
    module HTTP
      # Aplicação Rack: roteamento, autenticação, CSRF, chamada do controlador e erros centralizados.
      class App
        ROOT = File.expand_path("../../../..", __dir__)

        ERRORS = [
          [Domain::Unavailable, 409, "unavailable"],
          [Domain::HoldExpired, 409, "hold_expired"],
          [Domain::Conflict, 409, nil],
          [Domain::InvalidTransition, 409, "invalid_transition"],
          [Domain::ValidationError, 422, "validation_error"],
          [Domain::NotFound, 404, "not_found"],
          [Domain::PlanLimitExceeded, 403, "plan_limit"],
          [Domain::AccessDenied, 403, "forbidden"],
          [Application::Identity::TooManyRequests, 429, "too_many_requests"],
          [Application::Identity::AuthenticationFailed, 401, "authentication_failed"],
          [Unauthenticated, 401, "unauthenticated"],
          [CsrfFailure, 403, "csrf"],
          [WrongArea, 403, "wrong_area"],
          [BadRequest, 400, "bad_request"],
          [PayloadTooLarge, 413, "payload_too_large"],
          [Infrastructure::Database::PoolTimeout, 503, "unavailable_capacity"]
        ].freeze
        API_WINDOW = 60

        # Monta a pilha de middlewares de forma explícita.
        def self.build(system, reload_templates: false)
          app = new(system, reload_templates: reload_templates)
          stack = SecurityHeaders.new(app, hsts: system.config.production?)
          stack = BodyLimit.new(stack, default: 1_048_576, uploads: system.config.max_upload_bytes + 65_536, upload_prefixes: ["/anexos"])
          stack = Rack::Static.new(stack, urls: ["/css", "/js", "/img"], root: File.join(ROOT, "public"),
                                          header_rules: [[:all, { "cache-control" => "public, max-age=300" }]])
          stack = RequestLogger.new(stack, logger: system.logger, metrics: system.metrics)
          ClientAddress.new(stack, trusted: system.config.trusted_proxies)
        end

        attr_reader :system, :router, :templates

        def initialize(system, reload_templates: false)
          @system = system
          @origins = [self.class.origin_of(system.config.base_url)].compact
          @templates = Templates.new(root: File.join(ROOT, "views"), reload: reload_templates)
          @authenticator = Authenticator.new(system)
          @flash = Flash.new(system.config.secret_key_base)
          @router = Router.new
          Routes.draw(@router, Controller::Dependencies.new(system: system, templates: @templates, flash: @flash))
        end

        def call(env)
          route, params = @router.recognize(env["REQUEST_METHOD"], env["PATH_INFO"].to_s)
          return not_found(env, params) unless route

          env["locentra.route"] = route.pattern
          ctx = RequestContext.new(env, params, env["locentra.request_id"] || SecureRandom.uuid)
          dispatch(route, ctx)
        rescue StandardError => e
          handle_error(ctx || RequestContext.new(env, {}, env["locentra.request_id"].to_s), e)
        end

        def self.origin_of(url)
          uri = URI.parse(url.to_s)
          return nil unless uri.host

          "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
        rescue URI::InvalidURIError
          nil
        end

        private

        # Limite de requisições por IP das rotas públicas que fazem trabalho caro (bcrypt, e-mail,
        # cadastro), declarado na rota como [nome, limite, janela em segundos]. A API tem limite por
        # credencial (API_RATE_LIMIT por minuto, API_WINDOW) e o portal, por usuário nas solicitações
        # de reserva.
        def dispatch(route, ctx)
          throttle!(route.options[:throttle], ctx.ip)
          ctx.verify_origin!(@origins) if route.options[:csrf] == :origin
          @authenticator.authenticate!(ctx, route.auth)
          throttle_actor!(route, ctx)
          ctx.env["locentra.organization_id"] = ctx.actor&.organization_id
          ctx.env["locentra.actor_id"] = ctx.actor&.audit_actor_id
          ctx.verify_csrf! if csrf_required?(route, ctx)
          route.controller.public_send(route.action, ctx)
        end

        def throttle_actor!(route, ctx)
          if ctx.env["locentra.auth_method"] == "bearer"
            throttle!(["api:credential", @system.config.api_rate_limit, API_WINDOW], ctx.actor.credential_id)
          elsif route.options[:throttle_actor] && ctx.actor
            throttle!(route.options[:throttle_actor], ctx.actor.user_id)
          end
        end

        def throttle!(spec, subject)
          return unless spec

          name, limit, window = spec
          result = @system.services[:rate_limiter].hit("#{name}:#{subject}", limit: limit, window_seconds: window)
          raise Application::Identity::TooManyRequests, result.retry_after unless result.allowed
        end

        def csrf_required?(route, ctx)
          return false if [false, :origin].include?(route.options[:csrf])
          return false if ctx.env["locentra.auth_method"] == "bearer"

          !ctx.get?
        end

        def not_found(env, allowed)
          ctx = RequestContext.new(env, {}, env["locentra.request_id"].to_s)
          return error_response(ctx, 405, "method_not_allowed", "Método não permitido", {}) if allowed.any?

          error_response(ctx, 404, "not_found", "Página não encontrada", {})
        end

        def handle_error(ctx, error)
          redirect = navigation_redirect(ctx, error)
          return redirect if redirect

          _, status, code = ERRORS.find { |klass, _, _| error.is_a?(klass) }
          unless status
            @system.logger.error(event: "http.error", request_id: ctx.request_id, error: error.class.name, message: error.message,
                                 backtrace: error.backtrace&.first(8))
            return error_response(ctx, 500, "internal_error", "Erro interno. Informe a referência #{ctx.request_id}.", {})
          end

          # Conflitos de negócio são contados pela unidade de trabalho (domain_conflicts_total), inclusive
          # os tratados pelos formulários; a resposta 409 aparece em http_requests_total.
          details = details_for(error)
          response = error_response(ctx, status, code || error.code, error.message, details)
          response[1]["retry-after"] = error.retry_after.to_s if error.respond_to?(:retry_after)
          response
        end

        def details_for(error)
          case error
          when Domain::ValidationError then { "fields" => error.errors }
          when Domain::Unavailable then { "shortages" => error.shortages }
          else {}
          end
        end

        def error_response(ctx, status, code, message, details)
          if ctx.wants_json?
            body = { "error" => { "code" => code, "message" => message, "details" => details, "request_id" => ctx.request_id } }
            [status, { "content-type" => "application/json; charset=utf-8" }, [JSON.generate(body)]]
          else
            html = ViewContext.new(@templates, ctx, status: status, message: message, details: details, flash: nil, content: nil)
            page = html.render("errors/show")
            layout_name = ctx.actor&.customer? ? "layouts/portal" : "layouts/application"
            layout = ViewContext.new(@templates, ctx, content: Html.safe(page), title: "Erro #{status}", flash: nil).render(layout_name)
            [status, { "content-type" => "text/html; charset=utf-8" }, [layout]]
          end
        end

        # Interface web: sem sessão, vai para a entrada; sessão de outra área (portal x equipe) em uma
        # página, para o início da própria área.
        def navigation_redirect(ctx, error)
          return nil if ctx.wants_json?
          return login_redirect(ctx) if error.is_a?(Unauthenticated)

          area_redirect(error) if error.is_a?(WrongArea) && ctx.get?
        end

        def area_redirect(error)
          [303, { "location" => error.home, "content-type" => "text/html; charset=utf-8" }, [""]]
        end

        def login_redirect(ctx)
          target = ctx.get? && Controller.local_path?(ctx.path) ? ctx.path : "/"
          location = target == "/" ? "/entrar" : "/entrar?#{URI.encode_www_form(voltar: target)}"
          [303, { "location" => location, "content-type" => "text/html; charset=utf-8" }, [""]]
        end
      end
    end
  end
end
