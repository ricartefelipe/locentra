# frozen_string_literal: true

module Locentra
  module Interfaces
    # Representação JSON da organização (configurações e filiais), compartilhada por
    # `GET /api/v1/organization` e por `organization show --json`: os dois canais devolvem o mesmo objeto.
    # Instantes em ISO 8601 UTC e multas em pontos-base inteiros. Os indicadores `*_default` comparam o
    # valor efetivo com o padrão, independentemente de a chave estar gravada.
    module OrganizationSerializers
      O = Domain::Organizations

      module_function

      def organization(org, branches)
        { "id" => org.id, "name" => org.name, "slug" => org.slug, "time_zone" => org.timezone,
          "time_zone_label" => O::Settings.zone_label(org.timezone), "status" => org.status, "lock_version" => org.lock_version,
          "settings" => settings(org), "branches" => branches.map { |branch| branch(branch) } }
      end

      def settings(org)
        policy = O::CancellationPolicy.canonical(org.cancellation_policy)
        { "hold_minutes" => org.hold_minutes, "hold_minutes_default" => org.default_hold_minutes?,
          "hold_minutes_limits" => { "min" => Domain::Reservations::HOLD_MINUTES.min, "max" => Domain::Reservations::HOLD_MINUTES.max },
          "cancellation_policy" => { "tiers" => O::CancellationPolicy.sorted(policy).map { |tier| tier.slice("min_hours_before", "fee_bps") } },
          "cancellation_policy_default" => org.default_cancellation_policy?,
          "cancellation_terms" => O::CancellationPolicy.describe(policy) }
      end

      def branch(branch)
        { "id" => branch.id, "code" => branch.code, "name" => branch.name, "address" => branch.address, "active" => branch.active,
          "deactivated_at" => branch.deactivated_at&.getutc&.iso8601 }
      end
    end
  end
end
