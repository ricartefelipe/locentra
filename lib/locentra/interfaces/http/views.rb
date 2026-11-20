# frozen_string_literal: true

require "erb"
require "cgi"
require "json"
require "securerandom"
require "uri"
require_relative "labels"

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
          "blocked" => "danger", "inactive" => "muted", "revoked" => "muted", "picking" => "warning", "delivered" => "success",
          "partial" => "info", "not_delivered" => "muted", "pending" => "warning", "checked" => "info", "approved" => "success",
          "rejected" => "danger", "open" => "warning", "dismissed" => "muted", "received" => "success", "resolved" => "muted",
          "overdue" => "danger", "affected_by_overdue" => "warning", "asset_unavailable" => "danger", "draft" => "neutral",
          "sent" => "info", "converted" => "muted", "issued" => "warning", "closed" => "muted"
        }.freeze

        # Rótulo em português de um código interno (ver Labels::GROUPS).
        def label(group, value) = Labels.label(group, value)

        # Percentual a partir de pontos-base, com aritmética inteira (Domain::Percent).
        def percent(bps) = Domain::Percent.label(bps)
        def percent_value(bps) = Domain::Percent.value(bps)

        def asset_status(status) = Domain::Catalog::ASSET_STATUSES.fetch(status.to_s) { Labels.label(:field, status) }

        def status_badge(status, label)
          badge(label, STATUS_TONES.fetch(status, "neutral"))
        end

        # Situações do financeiro (cobranças, pagamentos, reembolsos, cauções e conciliação).
        FINANCE_TONES = {
          "open" => "warning", "partial" => "info", "paid" => "success", "credit" => "danger", "cancelled" => "muted",
          "pending_submission" => "neutral", "submission_unknown" => "warning", "pending" => "warning", "confirmed" => "success",
          "failed" => "danger", "awaiting" => "neutral", "held" => "info", "settled" => "muted", "running" => "info", "completed" => "success",
          "resolved" => "muted"
        }.freeze

        def finance_badge(status, label)
          badge(label, FINANCE_TONES.fetch(status, "neutral"))
        end

        def url(path, params = {})
          query = params.compact.reject { |_, v| v.to_s.empty? }
          query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}"
        end

        def u(text) = URI.encode_www_form_component(text.to_s)

        def field_errors(errors, field)
          messages = Array(errors && errors[field.to_s])
          return raw("") if messages.empty?

          raw(%(<p class="field-error" id="erro-#{h(field)}" role="alert">#{h(messages.join("; "))}</p>))
        end

        # Atributos de acessibilidade do campo: um único aria-describedby com a ajuda do campo
        # (`describedby`) e, havendo erro, a mensagem de erro.
        def invalid(errors, field, describedby: nil)
          error = errors&.key?(field.to_s)
          ids = [describedby, error ? "erro-#{field}" : nil].compact
          attributes = +""
          attributes << ' aria-invalid="true"' if error
          attributes << %( aria-describedby="#{h(ids.join(" "))}") unless ids.empty?
          raw(attributes)
        end

        # Valor reenviado de um campo indexado (nome[chave]); ignora formatos inesperados.
        def keyed_value(values, group, key)
          bucket = values.is_a?(Hash) ? values[group] : nil
          bucket.is_a?(Hash) ? bucket[key] : nil
        end

        # Mantém aberto o bloco <details> cujo formulário tem erro em algum dos campos informados.
        def open_if(errors, *fields) = raw(fields.any? { |field| errors&.key?(field.to_s) } ? " open" : "")

        # Formulário de outra tela de detalhe que falhou: a página volta com o <details> do formulário
        # aberto e com os valores enviados (a requisição atual é o POST para o `path` do formulário).
        def open_after_failure(path) = raw(failed_submission?(path) ? " open" : "")
        def submitted(path, field) = failed_submission?(path) ? request.form[field].to_s : ""

        def failed_submission?(path)
          !request.get? && request.path == path && @errors.is_a?(Hash) && !@errors.empty?
        end

        # Chave de envio único de formulários que movimentam dinheiro (idempotência do envio).
        def submission_field = raw(%(<input type="hidden" name="envio" value="#{SecureRandom.uuid}">))

        def selected(current, value) = raw(current.to_s == value.to_s ? " selected" : "")
        def checked(flag) = raw(flag ? " checked" : "")

        def can?(permission) = request.can?(permission)

        # Itens da navegação principal com a permissão exigida para exibi-los.
        NAVIGATION = [
          ["Painel", "/", "reservations.read"],
          ["Reservas", "/reservas", "reservations.read"],
          ["Orçamentos", "/orcamentos", "quotes.read"],
          ["Contratos", "/contratos", "contracts.read"],
          ["Disponibilidade", "/disponibilidade", "availability.read"],
          ["Clientes", "/clientes", "customers.read"],
          ["Financeiro", "/financeiro", "finance.read"],
          ["Produtos e kits", "/produtos", "catalog.read"],
          ["Ativos", "/ativos", "catalog.read"],
          ["Retiradas e devoluções", "/operacao", "fulfillment.write"],
          ["Manutenção", "/manutencao", "maintenance.write"],
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

        # Navegação do portal do cliente (todas as seções exigem somente o acesso ao portal).
        PORTAL_NAVIGATION = [
          ["Início", "/portal"],
          ["Disponibilidade e solicitação", "/portal/disponibilidade"],
          ["Minhas reservas", "/portal/reservas"],
          ["Orçamentos", "/portal/orcamentos"],
          ["Contratos", "/portal/contratos"],
          ["Cobranças e saldos", "/portal/financeiro"]
        ].freeze

        def portal_navigation = PORTAL_NAVIGATION

        def portal_nav_class(prefix)
          active = prefix == "/portal" ? request.path == "/portal" : request.path.start_with?(prefix)
          active ? raw(%( aria-current="page" class="active")) : raw("")
        end

        # Nome de quem está conectado (sessão), para o cabeçalho.
        def session_user_name = request.session && request.session["user_name"]

        private

        def instance_assigns
          instance_variables.reject { |v| %i[@templates @request].include?(v) }
                            .to_h { |v| [v.to_s.delete_prefix("@").to_sym, instance_variable_get(v)] }
        end
      end
    end
  end
end
