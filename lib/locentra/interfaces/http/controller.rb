# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      # Base dos controladores: renderização, redirecionamento seguro, JSON e conversão de entrada.
      class Controller
        Dependencies = Data.define(:system, :templates, :flash)

        # Caminho local seguro para redirecionamento: começa com uma única "/" e não tem barra
        # invertida, espaço nem caractere de controle. Navegadores removem TAB e quebras de linha antes
        # de resolver o endereço ("/\t/evil.example" vira "//evil.example"), por isso qualquer
        # caractere de controle é recusado.
        UNSAFE_PATH = /[\x00-\x20\x7F\\]/

        # Percentual com até duas casas decimais ("12", "12,5", "12.34") em pontos-base, com aritmética
        # inteira. Infinity, NaN, notação científica e casas além da segunda são recusados (não
        # arredondados nem truncados em silêncio).
        PERCENT = /\A(\d{1,3})(?:[.,](\d{1,2}))?\z/

        def self.local_path?(value)
          text = value.to_s
          text.start_with?("/") && !text.start_with?("//") && !text.match?(UNSAFE_PATH)
        end

        def initialize(deps)
          @system = deps.system
          @templates = deps.templates
          @flash = deps.flash
        end

        private

        def uc(name) = @system.use_cases[name]

        def secure_cookies? = @system.config.secure_cookies?

        def render(ctx, template, title:, status: 200, layout: nil, **assigns)
          flash = @flash.read(ctx)
          body = ViewContext.new(@templates, ctx, **assigns, flash: flash).render(template)
          layout ||= ctx.actor&.customer? ? "layouts/portal" : "layouts/application"
          page = ViewContext.new(@templates, ctx, content: Html.safe(body), title: title, flash: flash).render(layout)
          response = Rack::Response.new(page, status, "content-type" => "text/html; charset=utf-8")
          @flash.clear(response, secure: secure_cookies?) if flash
          yield response if block_given?
          response.finish
        end

        # Redireciona apenas para caminhos locais: impede redirecionamento aberto.
        def redirect(ctx, location, notice: nil, alert: nil)
          response = Rack::Response.new("", 303, "location" => local_path(location))
          @flash.write(response, notice ? "notice" : "alert", notice || alert, secure: secure_cookies?) if notice || alert
          yield response if block_given?
          ctx.response_headers.each { |k, v| response.set_header(k, v) }
          response.finish
        end

        def local_path(location)
          self.class.local_path?(location) ? location.to_s : "/"
        end

        def json(status, body, headers = {})
          [status, { "content-type" => "application/json; charset=utf-8" }.merge(headers), [JSON.generate(body)]]
        end

        def percent_bps(value, field)
          text = value.to_s.strip
          return 0 if text.empty?

          match = PERCENT.match(text) || raise(Domain::ValidationError.field(field, "percentual inválido (até duas casas decimais)"))
          (match[1].to_i * 100) + match[2].to_s.ljust(2, "0").to_i
        end

        # Conversões de entrada de formulário. O erro de formato vai para o campo do formulário que
        # enviou o valor (o domínio usa a chave genérica "valor").
        def money_param(value, field = "valor")
          text = value.to_s.strip
          text.empty? ? Domain::Money.zero : money!(text, field)
        end

        def money!(text, field)
          Domain::Money.parse(text)
        rescue Domain::ValidationError => e
          raise Domain::ValidationError.field(field, e.errors.values.flatten.first || "formato monetário inválido")
        end

        def local_time(ctx, value, field)
          ctx.time_zone.parse_local(value)
        rescue Domain::ValidationError
          raise Domain::ValidationError.field(field, "data e hora inválidas ou inexistentes no fuso da organização")
        end

        def period_from(ctx, starts, ends)
          Domain::Period.new(local_time(ctx, starts, "inicio"), local_time(ctx, ends, "fim"))
        end

        # Período via API: ISO 8601 com offset.
        def api_period(data)
          Domain::Period.parse(data["starts_at"], data["ends_at"])
        end

        def lines_from(products, quantities)
          Array(products).zip(Array(quantities)).filter_map do |product_id, quantity|
            next if product_id.to_s.empty? || quantity.to_s.strip.empty? || quantity.to_s.strip == "0"

            Domain::Reservations::Line.build(product_id: product_id, quantity: quantity)
          end
        end

        def session_cookie(response, token)
          response.set_cookie(Authenticator.cookie_name(@system.config),
                              value: token, path: "/", httponly: true, secure: secure_cookies?, same_site: :lax)
        end

        def clear_session_cookie(response)
          response.delete_cookie(Authenticator.cookie_name(@system.config), path: "/", httponly: true, secure: secure_cookies?, same_site: :lax)
        end
      end
    end
  end
end
