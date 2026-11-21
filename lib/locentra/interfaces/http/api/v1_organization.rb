# frozen_string_literal: true

require_relative "v1"

module Locentra
  module Interfaces
    module HTTP
      module API
        # Alteração das configurações da organização pela API v1 (ADR-029): somente por sessão de usuário com
        # `organization.manage` (cookie de sessão e `X-CSRF-Token`). Credenciais, mesmo com o escopo, recebem 403:
        # a regra de UpdateSettings (ADR-028) vale também aqui.
        #
        # PATCH parcial: chave presente altera o campo e chave ausente mantém o valor atual. `lock_version` é
        # obrigatório (a escrita parcial de configurações que afetam todo o tenant não sobrescreve às cegas uma
        # alteração concorrente) e a troca de fuso exige `confirm_time_zone_change: true`. Chaves desconhecidas
        # ou não editáveis são recusadas no próprio nome, em vez de ignoradas.
        class OrganizationV1Controller < V1Controller
          ALLOWED = %w[name time_zone hold_minutes cancellation_policy confirm_time_zone_change lock_version].freeze
          UNKNOWN = "campo desconhecido ou não editável"
          POLICY_FIELD = Domain::Organizations::CancellationPolicy::FIELD
          POLICY_FORMAT = "informe a política como um objeto com somente tiers (lista de faixas com min_hours_before e fee_bps)"

          def update_settings(ctx)
            data = ctx.json
            attrs, version = settings_input(data)
            idempotent(ctx, "organization.manage", "PATCH /api/v1/organization/settings", data) do |tx, actor|
              result = uc(:update_organization_settings).call(actor, attrs, lock_version: version, via: "api", tx: tx)
              current = uc(:read_organization).call(actor, tx: tx)
              [200, { "organization" => OrganizationSerializers.organization(current[:organization], current[:branches]),
                      "changed" => result.changed }]
            end
          end

          private

          # Atributos somente das chaves presentes e a versão do controle otimista, com os erros de formato reunidos.
          def settings_input(data)
            collect do |check|
              (data.keys - ALLOWED).each { |key| check.call(key) { raise Domain::ValidationError.field(key, UNKNOWN) } }
              attrs = {}
              attrs[:name] = check.call("nome") { strict_text(data, "name", "nome") } if data.key?("name")
              attrs[:timezone] = check.call("fuso_horario") { strict_text(data, "time_zone", "fuso_horario") } if data.key?("time_zone")
              attrs[:hold_minutes] = check.call("validade_bloqueio") { strict_integer(data, "hold_minutes", "validade_bloqueio") } if data.key?("hold_minutes")
              attrs[:cancellation_tiers] = check.call(POLICY_FIELD) { policy_tiers(data["cancellation_policy"]) } if data.key?("cancellation_policy")
              attrs[:confirm_timezone_change] = check.call("confirmar_fuso") { strict_boolean(data, "confirm_time_zone_change", "confirmar_fuso") } || false
              [attrs, check.call("lock_version") { strict_integer(data, "lock_version", "lock_version", min: 1, allow_nil: false) }]
            end
          end

          # Mesmo formato de `GET /organization` (`{ "tiers": [...] }`); as faixas são validadas pela política.
          def policy_tiers(value)
            raise Domain::ValidationError.field(POLICY_FIELD, POLICY_FORMAT) unless value.is_a?(Hash) && value.keys == ["tiers"]

            value["tiers"]
          end
        end
      end
    end
  end
end
