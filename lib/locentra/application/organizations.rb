# frozen_string_literal: true

module Locentra
  module Application
    module Organizations
      # Limites contratados, verificados com lock na assinatura para valerem sob concorrência.
      class PlanLimits
        INACTIVE = %w[suspended cancelled].freeze
        LABELS = { assets: "ativos", branches: "filiais", users: "usuários" }.freeze

        def initialize(subscriptions:)
          @subscriptions = subscriptions
        end

        def ensure!(tx, kind, adding: 1)
          subscription = active_subscription!(tx)
          limit = subscription["max_#{kind}"]
          return true if limit.nil?

          used = @subscriptions.usage(tx, kind)
          return true if used + adding <= limit

          raise Domain::PlanLimitExceeded.new(kind.to_s,
                                              "Limite de #{LABELS.fetch(kind)} do plano #{subscription["plan_name"]} atingido (#{limit})")
        end

        def feature!(tx, feature)
          subscription = active_subscription!(tx)
          features = Array(subscription["features"]) + Array(subscription["extra_features"])
          return true if features.include?(feature)

          raise Domain::PlanLimitExceeded.new(feature, "Funcionalidade '#{feature}' não incluída no plano #{subscription["plan_name"]}")
        end

        # Consulta sem lock para telas; gravações continuam usando `feature!`, que bloqueia a assinatura.
        def includes?(tx, feature)
          subscription = @subscriptions.current(tx)
          return false if subscription.nil? || INACTIVE.include?(subscription["status"])

          (Array(subscription["features"]) + Array(subscription["extra_features"])).include?(feature)
        end

        private

        def active_subscription!(tx)
          subscription = @subscriptions.lock_current(tx)
          raise Domain::PlanLimitExceeded.new("subscription", "Organização sem assinatura") unless subscription
          raise Domain::PlanLimitExceeded.new("subscription", "Assinatura inativa") if INACTIVE.include?(subscription["status"])

          subscription
        end
      end

      # Nova filial: o limite de filiais do plano é verificado sob a trava da assinatura. O endereço acima de
      # 300 caracteres é recusado (não truncado).
      class CreateBranch
        def initialize(uow:, organizations:, limits:, audit:, clock:, ids:)
          @uow = uow
          @organizations = organizations
          @limits = limits
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, name:, code:, address: nil)
          @uow.run(actor, "organization.manage") do |tx, current|
            @limits.ensure!(tx, :branches)
            branch = Domain::Organizations::Branch.build(id: @ids.uuid, organization_id: tx.tenant_id!, name: name, code: code,
                                                         address: address)
            @organizations.insert_branch(tx, branch, @clock.now)
            @audit.record(tx, current, "branch.created", "branch", branch.id, "code" => branch.code)
            branch
          end
        end
      end

      class InviteMember
        TTL = 7 * 86_400

        def initialize(uow:, organizations:, limits:, notifier:, audit:, clock:, ids:)
          @uow = uow
          @organizations = organizations
          @limits = limits
          @notifier = notifier
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, email:, role:)
          address = Domain::Identity::Email.normalize(email)
          @uow.run(actor, "members.manage") do |tx, current|
            Authorizer.confirmed_email!(current, "members.invite")
            unless Domain::Identity.assignable_roles(current.role).include?(role)
              raise Domain::AccessDenied, "papel não pode ser atribuído por #{Domain::Identity.role_label(current.role)}"
            end
            raise Domain::Conflict.new("usuário já é membro ativo", code: "already_member") if @organizations.active_member_email?(tx,
                                                                                                                                   address)

            @limits.ensure!(tx, :users)
            @organizations.revoke_pending_invitations(tx, address, @clock.now)
            # O token definitivo é emitido pelo envio do e-mail; este valor apenas ocupa a coluna.
            token = "#{tx.tenant_id!}.#{@ids.token(32)}"
            invitation = { "id" => @ids.uuid, "organization_id" => tx.tenant_id!, "email" => address, "role" => role,
                           "token_digest" => Identity::Tokens.digest(token), "invited_by" => current.user_id,
                           "expires_at" => @clock.now + TTL, "created_at" => @clock.now }
            @organizations.insert_invitation(tx, invitation)
            @notifier.invitation(tx, invitation)
            @audit.record(tx, current, "member.invited", "invitation", invitation["id"], "email" => address, "role" => role)
            invitation
          end
        end
      end

      # Aceite de convite. O tenant é extraído do próprio token e confirmado pelo hash do segredo. O link
      # chega somente ao endereço convidado, que precisa ser o da conta: o aceite confirma o e-mail da conta
      # criada e também o da conta existente que ainda não o tinha confirmado (ADR-031).
      class AcceptInvitation
        def initialize(uow:, organizations:, users:, hasher:, audit:, clock:, ids:)
          @uow = uow
          @organizations = organizations
          @users = users
          @hasher = hasher
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # Com `user_id`, vincula a conta autenticada; sem ele, cria a conta com nome e senha. O convite
        # é conferido antes do bcrypt: token inválido ou expirado não custa um hash.
        def call(token:, user_id: nil, name: nil, password: nil)
          org_id, = token.to_s.split(".", 2)
          raise Domain::ValidationError.field("token", "convite inválido") unless Domain::Identifier.valid?(org_id)

          now = @clock.now
          digest = if user_id.nil?
                     Domain::Identity::PasswordPolicy.validate!(password)
                     pending!(org_id, token, now)
                     @hasher.hash(password)
                   end
          @uow.anonymous(tenant_id: org_id, user_id: user_id) do |tx|
            invitation = @organizations.lock_invitation(tx, Identity::Tokens.digest(token))
            raise Domain::ValidationError.field("token", "convite inválido ou expirado") unless usable?(invitation, now)

            member_id = resolve_user(tx, invitation, user_id, name, digest, now)
            @organizations.upsert_membership(tx, "id" => @ids.uuid, "organization_id" => org_id, "user_id" => member_id,
                                                 "role" => invitation["role"], "created_at" => now, "updated_at" => now)
            @organizations.mark_invitation_accepted(tx, invitation["id"], member_id, now)
            actor = Actor.user(user_id: member_id, organization_id: org_id, role: invitation["role"])
            @audit.record(tx, actor, "member.joined", "invitation", invitation["id"], "role" => invitation["role"])
            { organization_id: org_id, user_id: member_id }
          end
        end

        private

        def pending!(org_id, token, now)
          usable = @uow.anonymous(tenant_id: org_id) { |tx| usable?(@organizations.lock_invitation(tx, Identity::Tokens.digest(token)), now) }
          raise Domain::ValidationError.field("token", "convite inválido ou expirado") unless usable
        end

        def usable?(invitation, now)
          invitation && invitation["accepted_at"].nil? && invitation["revoked_at"].nil? && now < invitation["expires_at"]
        end

        def resolve_user(tx, invitation, user_id, name, digest, now)
          if user_id
            user = @users.find(tx, user_id)
            raise Domain::AccessDenied, "o convite foi enviado para outro e-mail" unless user && user["email"] == invitation["email"]

            @users.confirm_email(tx, user_id, now)
            return user_id
          end
          if @users.find_by_email(
            tx, invitation["email"]
          )
            raise Domain::Conflict.new("já existe conta com este e-mail; entre para aceitar o convite",
                                       code: "login_required")
          end

          new_id = @ids.uuid
          @users.insert(tx, "id" => new_id, "email" => invitation["email"], "name" => Domain::Organizations::Text.required(name, "nome", max: 120),
                            "password_digest" => digest, "email_confirmed_at" => now, "created_at" => now, "updated_at" => now)
          new_id
        end
      end

      class ChangeMemberRole
        def initialize(uow:, organizations:, audit:, clock:)
          @uow = uow
          @organizations = organizations
          @audit = audit
          @clock = clock
        end

        def call(actor, membership_id:, role:)
          raise Domain::ValidationError.field("papel", "papel inválido") unless Domain::Identity.valid_role?(role)

          @uow.run(actor, "members.manage") do |tx, current|
            member = @organizations.lock_membership(tx, Domain::Identifier.parse(membership_id)) || raise(Domain::NotFound, "membro")
            assignable = Domain::Identity.assignable_roles(current.role)
            raise Domain::AccessDenied, "papel não pode ser atribuído" unless assignable.include?(role)
            raise Domain::AccessDenied, "não é possível alterar o proprietário" if member["role"] == "owner"
            # Somente membros com papel que o ator poderia atribuir: administrador não altera outro
            # administrador (nem o rebaixa para depois removê-lo).
            raise Domain::AccessDenied, "administradores só podem ser alterados pelo proprietário" unless assignable.include?(member["role"])

            @organizations.update_membership_role(tx, member["id"], role, @clock.now)
            @audit.record(tx, current, "member.role_changed", "membership", member["id"], "from" => member["role"], "to" => role)
            role
          end
        end
      end

      # Revogação do vínculo: encerra as sessões do membro na organização e revoga as credenciais de
      # API e CLI criadas por ele, na mesma transação.
      class RevokeMembership
        def initialize(uow:, organizations:, sessions_repository:, credentials:, audit:, clock:)
          @uow = uow
          @organizations = organizations
          @sessions = sessions_repository
          @credentials = credentials
          @audit = audit
          @clock = clock
        end

        def call(actor, membership_id:)
          @uow.run(actor, "members.manage") do |tx, current|
            member = @organizations.lock_membership(tx, Domain::Identifier.parse(membership_id)) || raise(Domain::NotFound, "membro")
            raise Domain::AccessDenied, "o proprietário não pode ser removido" if member["role"] == "owner"
            raise Domain::Conflict.new("acesso já revogado", code: "already_revoked") if member["status"] == "revoked"
            if member["role"] == "admin" && current.role != "owner"
              raise Domain::AccessDenied,
                    "administradores só podem ser removidos pelo proprietário"
            end

            now = @clock.now
            @organizations.revoke_membership(tx, member["id"], current.user_id, now)
            @sessions.revoke_for_organization(tx, member["user_id"], tx.tenant_id!, now, "membership_revoked")
            revoked = @credentials.revoke_created_by(tx, member["user_id"], now)
            @audit.record(tx, current, "member.revoked", "membership", member["id"], "user_id" => member["user_id"], "credentials_revoked" => revoked)
            true
          end
        end
      end

      class ListMembers
        def initialize(uow:, organizations:)
          @uow = uow
          @organizations = organizations
        end

        def call(actor)
          @uow.run(actor, "members.read") do |tx, _current|
            { members: @organizations.members(tx), invitations: @organizations.pending_invitations(tx) }
          end
        end
      end

      # Organização, filiais e assinatura. Sem `permission`, serve aos formulários e à resolução de
      # `--filial` na CLI (qualquer membro); `read_organization` usa `organization.read` (página da
      # organização, API e `organization show`).
      class GetOrganization
        def initialize(uow:, organizations:, permission: nil)
          @uow = uow
          @organizations = organizations
          @permission = permission
        end

        # Com `tx`, lê na transação do chamador (resposta de uma alteração das configurações).
        def call(actor, tx: nil)
          Composition.run(@uow, actor, @permission, tx) do |t, current|
            org = @organizations.find(t, t.tenant_id!) || raise(Domain::NotFound.new("organização", feminine: true))
            { organization: org, branches: @organizations.branches(t), subscription: @organizations.subscription(t), actor: current }
          end
        end
      end
    end
  end
end
