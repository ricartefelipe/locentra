# frozen_string_literal: true

module Locentra
  module Wiring
    # Montagem dos casos de uso da organização (leitura, configurações e filiais), chamada pela raiz de
    # composição (System). Devolve o mapa nome → caso de uso.
    module Organizations
      O = Application::Organizations

      module_function

      def build(uow:, repos:, services:, clock:, ids:)
        organizations = repos.fetch(:organizations)
        audit = services.fetch(:audit)
        common = { uow: uow, organizations: organizations }
        {
          create_branch: O::CreateBranch.new(**common, limits: services.fetch(:limits), audit: audit, clock: clock, ids: ids),
          get_organization: O::GetOrganization.new(**common),
          read_organization: O::GetOrganization.new(**common, permission: "organization.read"),
          get_organization_settings: O::GetSettings.new(**common, audit_log: repos.fetch(:audit), clock: clock),
          preview_organization_settings: O::PreviewSettings.new(**common),
          update_organization_settings: O::UpdateSettings.new(**common, audit: audit, clock: clock),
          get_branch: O::GetBranch.new(**common, audit_log: repos.fetch(:audit), clock: clock),
          update_branch: O::UpdateBranch.new(**common, audit: audit, clock: clock),
          set_branch_active: O::SetBranchActive.new(**common, limits: services.fetch(:limits), audit: audit, clock: clock)
        }
      end
    end
  end
end
