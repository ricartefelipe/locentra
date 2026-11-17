# frozen_string_literal: true

require "erb"
require "cgi"
require "json"
require "uri"

module Locentra
  module Interfaces
    module HTTP
      # Texto HTML já escapado ou produzido por helper confiável.
      class SafeHtml < String
        def to_s = self
      end

      module Html
        module_function

        def escape(value)
          return value if value.is_a?(SafeHtml)

          SafeHtml.new(CGI.escapeHTML(value.to_s))
        end

        def safe(text) = SafeHtml.new(text.to_s)

        # JSON seguro para embutir em <script type="application/json">: caracteres que poderiam
        # encerrar o elemento ou abrir comentários HTML são escapados.
        def json_for_script(data)
          JSON.generate(data).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026").gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
        end
      end

      # ERB com escape automático: `<%= %>` escapa sempre; HTML confiável precisa passar por
      # `raw` ou por um helper que devolva SafeHtml.
      class EscapingERB < ERB
        def set_eoutvar(compiler, eoutvar = "_erbout")
          super
          compiler.insert_cmd = "#{eoutvar}.<< ::Locentra::Interfaces::HTTP::Html.escape"
        end
      end

      # Métodos compilados a partir dos templates (um método por arquivo, compilado uma vez).
      module CompiledTemplates; end

      class Templates
        NAME = %r{\A[a-z0-9_/]+\z}

        def initialize(root:, reload: false)
          @root = root
          @reload = reload
          @compiled = {}
          @mutex = Thread::Mutex.new
        end

        def method_for(name)
          raise ArgumentError, "nome de template inválido" unless name.match?(NAME)

          @mutex.synchronize do
            @compiled.delete(name) if @reload
            @compiled[name] ||= compile(name)
          end
        end

        private

        def compile(name)
          path = File.join(@root, "#{name}.html.erb")
          method_name = "__template_#{name.tr("/", "__")}"
          EscapingERB.new(File.read(path), trim_mode: "-").def_method(CompiledTemplates, method_name, path)
          method_name
        end
      end

      # Contexto de renderização: recebe as variáveis do controlador e os helpers de apresentação.
      class ViewContext
        include CompiledTemplates

        ASSIGN = /\A[a-z_][a-z0-9_]*\z/

        attr_reader :request

        def initialize(templates, request, assigns)
          @templates = templates
          @request = request
          assigns.each do |key, value|
            raise ArgumentError, "variável de view inválida: #{key}" unless key.to_s.match?(ASSIGN)

            instance_variable_set(:"@#{key}", value)
          end
        end

        # O resultado de um template já passou pelo escape automático de cada expressão; por isso é
        # marcado como seguro para ser incluído em outro template sem escape duplo.
        def render(name)
          Html.safe(send(@templates.method_for(name)))
        end

        def partial(name, **locals)
          ViewContext.new(@templates, @request, instance_assigns.merge(locals)).render(name)
        end

        def raw(text) = Html.safe(text)

        def h(value) = Html.escape(value)

        def csrf_token = request.csrf_token

        def csrf_field
          raw(%(<input type="hidden" name="_csrf" value="#{h(csrf_token)}">))
        end

        def money(value)
          cents = value.is_a?(Domain::Money) ? value.cents : value.to_i
          Domain::Money.new(cents).format_brl
        end

        def time_zone = request.time_zone

        def datetime(value, pattern = "%d/%m/%Y %H:%M")
          return "—" if value.nil?

          time_zone.format_local(value, pattern)
        end

        def date(value)
          return "—" if value.nil?

          value.is_a?(Date) ? value.strftime("%d/%m/%Y") : datetime(value, "%d/%m/%Y")
        end

        def local_input(value)
          return "" if value.nil?

          time_zone.format_local(value, "%Y-%m-%dT%H:%M")
        end

        def badge(text, tone = "neutral")
          raw(%(<span class="badge badge-#{h(tone)}">#{h(text)}</span>))
        end

        STATUS_TONES = {
          "confirmed" => "success", "in_progress" => "info", "held" => "warning", "requested" => "neutral", "completed" => "muted",
          "cancelled" => "danger", "expired" => "muted", "available" => "success", "checked_out" => "info", "in_inspection" => "warning",
          "in_maintenance" => "warning", "in_transit" => "info", "lost" => "danger", "retired" => "muted", "active" => "success",
          "blocked" => "danger", "inactive" => "muted", "revoked" => "muted", "draft" => "neutral", "sent" => "info", "approved" => "success",
          "rejected" => "danger", "converted" => "muted", "issued" => "warning", "closed" => "muted"
        }.freeze

        def status_badge(status, label)
          badge(label, STATUS_TONES.fetch(status, "neutral"))
        end

        def url(path, params = {})
          query = params.compact.reject { |_, v| v.to_s.empty? }
          query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}"
        end

        def u(text) = URI.encode_www_form_component(text.to_s)

        def link_to(text, href, **attrs)
          extra = attrs.map { |k, v| %( #{k.to_s.tr("_", "-")}="#{h(v)}") }.join
          raw(%(<a href="#{h(href)}"#{extra}>#{h(text)}</a>))
        end

        def field_errors(errors, field)
          messages = Array(errors && errors[field.to_s])
          return raw("") if messages.empty?

          raw(%(<p class="field-error" id="erro-#{h(field)}" role="alert">#{h(messages.join("; "))}</p>))
        end

        def invalid(errors, field)
          return raw("") unless errors&.key?(field.to_s)

          raw(%( aria-invalid="true" aria-describedby="erro-#{h(field)}"))
        end

        def selected(current, value) = raw(current.to_s == value.to_s ? " selected" : "")
        def checked(flag) = raw(flag ? " checked" : "")

        def json_script(id, data)
          raw(%(<script type="application/json" id="#{h(id)}">#{Html.json_for_script(data)}</script>))
        end

        def can?(permission) = request.can?(permission)

        # Itens da navegação principal com a permissão exigida para exibi-los.
        NAVIGATION = [
          ["Painel", "/", "reservations.read"],
          ["Reservas", "/reservas", "reservations.read"],
          ["Orçamentos", "/orcamentos", "quotes.read"],
          ["Contratos", "/contratos", "contracts.read"],
          ["Disponibilidade", "/disponibilidade", "availability.read"],
          ["Clientes", "/clientes", "customers.read"],
          ["Produtos e kits", "/produtos", "catalog.read"],
          ["Ativos", "/ativos", "catalog.read"],
          ["Usuários e permissões", "/usuarios", "members.read"],
          ["Integrações", "/integracoes", "integrations.manage"],
          ["Organização", "/organizacao", "organization.manage"],
          ["Auditoria", "/auditoria", "audit.read"]
        ].freeze

        def navigation
          NAVIGATION.select { |_, _, permission| can?(permission) }.map { |label, path, _| [label, path] }
        end

        def nav_class(prefix)
          active = prefix == "/" ? request.path == "/" : request.path.start_with?(prefix)
          active ? raw(%( aria-current="page" class="active")) : raw("")
        end

        private

        def instance_assigns
          instance_variables.reject { |v| %i[@templates @request].include?(v) }
                            .to_h { |v| [v.to_s.delete_prefix("@").to_sym, instance_variable_get(v)] }
        end
      end
    end
  end
end
