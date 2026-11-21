# frozen_string_literal: true

module Locentra
  module Domain
    module Organizations
      # Normalização de textos curtos recebidos de formulários e API.
      module Text
        module_function

        def required(value, field, min: 1, max: 160)
          text = value.to_s.strip.gsub(/\s+/, " ")
          raise ValidationError.field(field, "obrigatório") if text.empty?
          raise ValidationError.field(field, "deve ter entre #{min} e #{max} caracteres") unless text.length.between?(min, max)

          text
        end

        def optional(value, max: 2000)
          text = value.to_s.strip
          return nil if text.empty?

          text[0, max]
        end

        # Texto opcional sem corte: acima do limite é recusado. Remove espaços das pontas e preserva as
        # quebras de linha internas, normalizadas para LF (o navegador envia CRLF e conta cada quebra como
        # um caractere no maxlength); vazio vira nil.
        def optional!(value, field, max:)
          text = value.to_s.gsub(/\r\n?/, "\n").strip
          return nil if text.empty?
          raise ValidationError.field(field, "até #{max} caracteres") if text.length > max

          text
        end

        def slugify(value)
          value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 60]
        end
      end

      # Organização (tenant). As configurações ficam em `settings` (somente chaves com valor diferente do
      # padrão; chaves desconhecidas são preservadas) e `lock_version` faz o controle otimista da edição.
      Organization = Data.define(:id, :name, :slug, :timezone, :status, :settings, :lock_version) do
        def initialize(lock_version: 1, **rest) = super

        def self.build(id:, name:, slug: nil, timezone: "America/Sao_Paulo")
          clean_name = Text.required(name, "nome", min: 2, max: 120)
          clean_slug = Text.slugify(slug.to_s.empty? ? clean_name : slug)
          raise ValidationError.field("identificador", "inválido") if clean_slug.length < 2

          TimeZone.new(timezone)
          new(id: id, name: clean_name, slug: clean_slug, timezone: timezone, status: "active", settings: {})
        end

        def active? = status == "active"

        # Identificador alternativo quando o derivado do nome já está em uso.
        def with_slug_suffix(suffix)
          with(slug: "#{slug[0, 60 - suffix.length - 1].sub(/-+\z/, "")}-#{suffix}")
        end

        def time_zone = TimeZone.new(timezone)

        # Política de cancelamento vigente para reservas e versões de orçamento novas; cada reserva, versão
        # e contrato guarda a própria cópia.
        def cancellation_policy
          settings.fetch("cancellation_policy", CancellationPolicy::DEFAULT)
        end

        def hold_minutes
          Integer(settings.fetch("hold_minutes", Settings::DEFAULT_HOLD_MINUTES).to_s, 10)
        end

        # "Padrão" pela igualdade de valor, independentemente de a chave estar gravada.
        def default_hold_minutes? = hold_minutes == Settings::DEFAULT_HOLD_MINUTES
        def default_cancellation_policy? = CancellationPolicy.default?(cancellation_policy)

        # Revisão das configurações a partir dos campos do formulário, com todos os erros reunidos. A troca
        # do fuso exige `confirm_timezone_change`. Sem diferença nos valores efetivos, devolve `self` (quem
        # chama compara com `equal?`); com diferença, a nova versão.
        def revise(name:, timezone:, hold_minutes:, cancellation_rows:, confirm_timezone_change: false)
          values = Pricing::Input.collect do |check|
            {
              name: check.call("nome") { Text.required(name, "nome", min: 2, max: 120) },
              timezone: check.call("fuso_horario") { Settings.timezone!(timezone, current: self.timezone) },
              hold_minutes: check.call("validade_bloqueio") { Settings.hold_minutes!(hold_minutes) },
              policy: check.call(CancellationPolicy::FIELD) { CancellationPolicy.from_form(cancellation_rows) }
            }.tap { |data| check.call("confirmar_fuso") { confirm_timezone!(data[:timezone], confirm_timezone_change) } }
          end
          return self if effective == [values[:name], values[:timezone], values[:hold_minutes], values[:policy]]

          with(name: values[:name], timezone: values[:timezone], lock_version: lock_version + 1,
               settings: Settings.store(settings, hold_minutes: values[:hold_minutes], cancellation_policy: values[:policy]))
        end

        # Campos alterados, com os valores efetivos (o padrão vale mesmo sem a chave gravada).
        def changes(after)
          Settings::TRACKED.zip(effective, after.effective).each_with_object({}) do |(field, before_value, after_value), diff|
            diff[field] = [before_value, after_value] unless before_value == after_value
          end
        end

        def timezone_changed?(after) = timezone != after.timezone

        # Nome, fuso, validade do bloqueio e política canônica, na ordem de Settings::TRACKED.
        def effective = [name, timezone, hold_minutes, CancellationPolicy.canonical(cancellation_policy)]

        private

        def confirm_timezone!(chosen, confirmed)
          return if chosen.nil? || chosen == timezone || confirmed

          raise ValidationError.field("confirmar_fuso", "confirme a troca do fuso horário depois de ler as consequências")
        end
      end

      BRANCH_STATUSES = { "active" => "Ativa", "inactive" => "Inativa" }.freeze

      # Filial. O código não muda (é usado em --filial e nos snapshots); nome e endereço são editáveis com
      # controle otimista, e a filial pode ser desativada e reativada (regras em docs/MAQUINAS-DE-ESTADO.md).
      Branch = Data.define(:id, :organization_id, :name, :code, :address, :active, :deactivated_at, :lock_version) do
        def initialize(deactivated_at: nil, lock_version: 1, **rest) = super

        def self.build(id:, organization_id:, name:, code:, address: nil)
          values = Pricing::Input.collect do |check|
            { code: check.call("codigo") { code!(code) }, name: check.call("nome") { name!(name) },
              address: check.call("endereco") { address!(address) } }
          end
          new(id: id, organization_id: organization_id, **values, active: true)
        end

        def self.code!(value)
          clean = value.to_s.strip.upcase
          raise ValidationError.field("codigo", "use até 12 letras, números ou hífen") unless clean.match?(/\A[A-Z0-9-]{1,12}\z/)

          clean
        end

        def self.name!(value) = Text.required(value, "nome", min: 2, max: 120)
        def self.address!(value) = Text.optional!(value, "endereco", max: Branch::MAX_ADDRESS)

        def status = active ? "active" : "inactive"
        def label_with_status = active ? name : "#{name} (inativa)"

        def revise(name:, address:)
          values = Pricing::Input.collect do |check|
            { name: check.call("nome") { Branch.name!(name) }, address: check.call("endereco") { Branch.address!(address) } }
          end
          return self if values[:name] == self.name && values[:address] == self.address

          with(**values, lock_version: lock_version + 1)
        end

        def changes(after)
          { "name" => [name, after.name], "address" => [address, after.address] }.reject { |_, (before, now)| before == now }
        end

        def deactivate(now)
          return self unless active

          with(active: false, deactivated_at: now, lock_version: lock_version + 1)
        end

        def reactivate
          return self if active

          with(active: true, deactivated_at: nil, lock_version: lock_version + 1)
        end
      end

      # Regras de desativação: vínculos que impedem (verificados pela aplicação sob trava da filial).
      class Branch
        MAX_ADDRESS = 300
        CODES_SHOWN = 5
        # Reservas em aberto; o bloqueio temporário só conta enquanto vigente.
        BLOCKING_RESERVATIONS = %w[requested held confirmed in_progress].freeze
        # Transferências pendentes que impedem quando têm a filial como destino (as de saída não impedem).
        BLOCKING_TRANSFERS = %w[requested in_transit].freeze
        BLOCKER_TEXTS = {
          reservations: ["reserva em aberto", "reservas em aberto", ->(_) { "conclua ou cancele" }],
          sent_quotes: ["orçamento enviado", "orçamentos enviados",
                        ->(_) { "aguarde a decisão, registre a recusa ou crie nova versão em outra filial" }],
          approved_quotes: ["orçamento aprovado", "orçamentos aprovados",
                            lambda { |count|
                              count == 1 ? "converta em reserva e conclua ou cancele a reserva" : "converta em reservas e conclua ou cancele as reservas"
                            }],
          incoming_transfers: ["transferência pendente com destino à filial", "transferências pendentes com destino à filial",
                               ->(_) { "registre o recebimento ou cancele" }]
        }.freeze

        # Mensagem com os vínculos que impedem a desativação (nil quando não há). `commitments` traz, por
        # tipo, `{ count:, codes: }` com no máximo CODES_SHOWN códigos.
        def self.deactivation_blockers(code, commitments)
          clauses = BLOCKER_TEXTS.filter_map do |kind, (one, many, action)|
            entry = commitments.fetch(kind, { count: 0, codes: [] })
            count = entry[:count].to_i
            next if count.zero?

            "#{count} #{count == 1 ? one : many} (#{codes_text(entry[:codes], count)}): #{action.call(count)}"
          end
          clauses.empty? ? nil : "Não é possível desativar a filial #{code}: #{clauses.join("; ")}."
        end

        def self.codes_text(codes, count)
          shown = Array(codes).first(CODES_SHOWN)
          rest = count - shown.size
          rest.positive? ? "#{shown.join(", ")} e mais #{rest}" : shown.join(", ")
        end
      end
    end
  end
end
