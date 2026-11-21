# frozen_string_literal: true

require_relative "output"
require_relative "command_support"
require_relative "../organization_serializers"

module Locentra
  module Interfaces
    module CLI
      # Consulta da organização na CLI operacional (escopo `organization.read`): fuso horário, validade
      # padrão do bloqueio temporário, política de cancelamento e filiais. A saída JSON é o mesmo objeto de
      # `GET /api/v1/organization` (OrganizationSerializers). As configurações e as filiais são alteradas
      # somente pela interface web.
      class OrganizationCommands
        include CommandSupport

        F = Formatting
        OS = OrganizationSerializers
        O = Domain::Organizations
        HANDLERS = %i[organization_show].freeze
        BRANCH_HEADERS = %w[Código Nome Endereço Situação].freeze

        def self.handles?(handler) = HANDLERS.include?(handler)

        def initialize(system:, actor:)
          @system = system
          @actor = actor
        end

        def run(invocation)
          case invocation.command.handler
          when :organization_show then organization_show
          end
        end

        private

        def organization_show
          data = uc(:read_organization).call(@actor)
          org = data[:organization]
          Result.ok(OS.organization(org, data[:branches]),
                    [*settings_lines(org), "Filiais:", *F.table(BRANCH_HEADERS, data[:branches].map { |branch| branch_row(branch, org) }), "",
                     "Alterações: somente pela interface web (Organização > Editar configurações)."])
        end

        def settings_lines(org)
          policy = O::CancellationPolicy.canonical(org.cancellation_policy)
          ["Organização: #{F.clean(org.name)} (#{org.slug})",
           "Fuso horário: #{org.timezone} — #{O::Settings.zone_label(org.timezone)}",
           "Validade padrão do bloqueio temporário: #{org.hold_minutes} minutos#{" (padrão)" if org.default_hold_minutes?}",
           "Política de cancelamento#{" (padrão)" if org.default_cancellation_policy?}:",
           *O::CancellationPolicy.describe(policy).map { |line| "  - #{line}" }]
        end

        def branch_row(branch, org)
          status = branch.active ? "Ativa" : "Inativa desde #{F.time(branch.deactivated_at, org.time_zone)}"
          [branch.code, branch.name, branch.address, status]
        end
      end
    end
  end
end
