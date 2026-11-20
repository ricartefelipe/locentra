# frozen_string_literal: true

module Locentra
  module Application
    module Integrations
      TOKEN_PATTERN = /\Alcn_([0-9a-f]{32})_([A-Za-z0-9_-]{43})\z/

      # Escopos que a credencial pode usar agora: os gravados, limitados às permissões atuais de
      # quem a criou (rebaixamento reduz os escopos na requisição seguinte).
      def self.effective_scopes(row)
        scopes = row.fetch("scopes")
        role = row["creator_role"]
        role ? scopes & Domain::Identity.permissions_for(role) : scopes
      end

      # Credenciais de integração: escopos (permissões), tenant, validade e revogação. O segredo é
      # exibido uma única vez; o banco guarda apenas o SHA-256.
      class CreateCredential
        MAX_DAYS = 365

        def initialize(uow:, credentials:, limits:, audit:, clock:, ids:)
          @uow = uow
          @credentials = credentials
          @limits = limits
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, name:, scopes:, kind: "api", expires_in_days: 90)
          raise Domain::ValidationError.field("tipo", "use api ou cli") unless %w[api cli].include?(kind)

          list = Domain::Identity.validate_permissions!(Array(scopes).map(&:to_s).uniq)
          raise Domain::ValidationError.field("escopos", "informe ao menos um escopo") if list.empty?

          days = Integer(expires_in_days.to_s, 10)
          raise Domain::ValidationError.field("validade", "entre 1 e #{MAX_DAYS} dias") unless days.between?(1, MAX_DAYS)

          @uow.run(actor, "integrations.manage") do |tx, current|
            @limits.feature!(tx, "api") if kind == "api"
            granted = Domain::Identity.permissions_for(current.role)
            raise Domain::AccessDenied, "escopos acima das permissões do criador" unless (list - granted).empty?

            secret = @ids.token(32)
            token = "lcn_#{tx.tenant_id!.delete("-")}_#{secret}"
            now = @clock.now
            row = { "id" => @ids.uuid, "name" => Domain::Organizations::Text.required(name, "nome", min: 2, max: 80), "kind" => kind,
                    "token_digest" => Identity::Tokens.digest(token), "token_hint" => "…#{secret[-4, 4]}", "scopes" => list,
                    "created_by" => current.user_id, "created_at" => now, "expires_at" => now + (days * 86_400) }
            @credentials.insert(tx, row)
            @audit.record(tx, current, "credential.created", "api_credential", row["id"], "scopes" => list, "kind" => kind)
            row.merge("token" => token)
          end
        rescue ArgumentError
          raise Domain::ValidationError.field("validade", "número inteiro de dias")
        end
      end

      class RevokeCredential
        def initialize(uow:, credentials:, audit:, clock:)
          @uow = uow
          @credentials = credentials
          @audit = audit
          @clock = clock
        end

        def call(actor, credential_id)
          @uow.run(actor, "integrations.manage") do |tx, current|
            id = Domain::Identifier.parse(credential_id)
            raise Domain::NotFound, "credencial" unless @credentials.revoke(tx, id, @clock.now) == 1

            @audit.record(tx, current, "credential.revoked", "api_credential", id)
            true
          end
        end
      end

      class ListCredentials
        def initialize(uow:, credentials:)
          @uow = uow
          @credentials = credentials
        end

        def call(actor)
          @uow.run(actor, "integrations.manage") { |tx, _| @credentials.list(tx) }
        end
      end

      # Autentica um token Bearer. A organização embutida no token define o contexto de tenant da
      # consulta; o segredo é verificado pelo hash, e validade e revogação são checadas.
      #
      # `kind` restringe o tipo aceito pela interface: a API aceita somente credenciais `api` e a
      # CLI operacional somente `cli`. Credencial de outro tipo é tratada como inválida e não tem o
      # último uso atualizado.
      class AuthenticateCredential
        def initialize(uow:, credentials:, clock:)
          @uow = uow
          @credentials = credentials
          @clock = clock
        end

        def call(token, kind: nil, request_id: nil, ip: nil)
          match = TOKEN_PATTERN.match(token.to_s)
          return nil unless match

          hex = match[1]
          org_id = "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
          now = @clock.now
          row = @uow.anonymous(tenant_id: org_id) do |tx|
            found = @credentials.find_active(tx, Identity::Tokens.digest(token), now)
            found = nil if found && kind && found["kind"] != kind
            @credentials.touch(tx, found["id"], now) if found
            found
          end
          return nil unless row

          Actor.credential(kind: row["kind"], credential_id: row["id"], organization_id: org_id, scopes: Integrations.effective_scopes(row),
                           request_id: request_id, ip: ip, user_id: nil)
        end
      end

      # Identidade autenticada, para conferência (CLI operacional). Não exige permissão: a
      # UnitOfWork revalida a credencial ou o vínculo e devolve os escopos ou o papel atuais.
      class WhoAmI
        def initialize(uow:, credentials:, organizations:)
          @uow = uow
          @credentials = credentials
          @organizations = organizations
        end

        def call(actor)
          @uow.run(actor) do |tx, current|
            { organization: @organizations.find(tx, tx.tenant_id!), actor: current,
              credential: current.credential? ? @credentials.find(tx, current.credential_id) : nil }
          end
        end
      end
    end
  end
end
