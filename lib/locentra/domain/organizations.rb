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

        def slugify(value)
          value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 60]
        end
      end

      Organization = Data.define(:id, :name, :slug, :timezone, :status, :settings) do
        def self.build(id:, name:, slug: nil, timezone: "America/Sao_Paulo")
          clean_name = Text.required(name, "nome", min: 2, max: 120)
          clean_slug = Text.slugify(slug.to_s.empty? ? clean_name : slug)
          raise ValidationError.field("identificador", "inválido") if clean_slug.length < 2

          TimeZone.new(timezone)
          new(id: id, name: clean_name, slug: clean_slug, timezone: timezone, status: "active", settings: {})
        end

        def active? = status == "active"

        def time_zone = TimeZone.new(timezone)

        # Política de cancelamento padrão; cada contrato guarda o snapshot vigente.
        def cancellation_policy
          settings.fetch("cancellation_policy", CancellationPolicy::DEFAULT)
        end

        def hold_minutes
          Integer(settings.fetch("hold_minutes", 30))
        end
      end

      Branch = Data.define(:id, :organization_id, :name, :code, :address, :active) do
        def self.build(id:, organization_id:, name:, code:, address: nil)
          clean_code = code.to_s.strip.upcase
          raise ValidationError.field("codigo", "use até 12 letras, números ou hífen") unless clean_code.match?(/\A[A-Z0-9-]{1,12}\z/)

          new(id: id, organization_id: organization_id, name: Text.required(name, "nome", min: 2, max: 120),
              code: clean_code, address: Text.optional(address, max: 300), active: true)
        end
      end

      # Política de cancelamento: percentual retido conforme antecedência em relação ao início.
      module CancellationPolicy
        DEFAULT = {
          "tiers" => [
            { "min_hours_before" => 72, "fee_bps" => 0 },
            { "min_hours_before" => 24, "fee_bps" => 3000 },
            { "min_hours_before" => 0, "fee_bps" => 10_000 }
          ]
        }.freeze

        module_function

        # Retorna a multa em pontos-base para cancelamento em `now` de uma locação iniciando em `starts_at`.
        def fee_bps(policy, starts_at:, now:)
          hours_before = Rational(starts_at.to_i - now.to_i, 3600)
          tiers = policy.fetch("tiers").sort_by { |tier| -tier.fetch("min_hours_before") }
          tier = tiers.find { |candidate| hours_before >= candidate.fetch("min_hours_before") } || tiers.last
          tier.fetch("fee_bps")
        end
      end
    end
  end
end
