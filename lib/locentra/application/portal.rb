# frozen_string_literal: true

module Locentra
  module Application
    # Portal do cliente.
    #
    # A equipe concede o acesso por convite ao e-mail de um contato do cliente (permissão
    # `customers.write` e funcionalidade `portal` do plano) e pode revogá-lo a qualquer momento. As
    # operações do cliente usam o ator `customer`: a UnitOfWork revalida o acesso ativo em cada
    # transação e todo recurso é filtrado pelo `customer_id` do acesso (de outro cliente ou de outra
    # organização resulta em "não encontrado").
    module Portal
      PT = Domain::Portal
      PERMISSION = "portal.access"
      FEATURE = "portal"

      module_function

      # Operações do próprio cliente: outros atores não usam a permissão do portal.
      def customer!(actor)
        raise Domain::AccessDenied, "operação restrita ao portal do cliente" unless actor.customer?

        actor
      end

      # Convite de acesso ao portal para um contato do cliente. O token é emitido pelo worker no envio
      # do e-mail; a coluna recebe um valor descartável até lá. Convites em aberto do mesmo e-mail
      # substituídos pelo novo são cancelados com auditoria própria (`reason: replaced`); um convite
      # pendente de outro cliente impede o novo (Domain::Portal::Rules.replaceable!).
      class InviteContact
        def initialize(uow:, portal:, customers:, limits:, notifier:, audit:, clock:, ids:)
          @uow = uow
          @portal = portal
          @customers = customers
          @limits = limits
          @notifier = notifier
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, customer_id:, contact_id:)
          @uow.run(actor, "customers.write") do |tx, current|
            raise Domain::AccessDenied, "convites do portal são enviados por usuários da equipe" unless current.user?

            @limits.feature!(tx, FEATURE)
            now = @clock.now
            customer = @customers.find(tx, Domain::Identifier.parse(customer_id, "cliente")) || raise(Domain::NotFound, "cliente")
            contact_key = Domain::Identifier.parse(contact_id, "contato")
            contact = @customers.contacts(tx, customer.id).find { |c| c.id == contact_key }
            invitation = PT::Invitation.issue(id: @ids.uuid, organization_id: tx.tenant_id!, customer: customer, contact: contact,
                                              invited_by: current.user_id, now: now)
            PT::Rules.grantable!(@portal.active_customer_for_email(tx, invitation.email), customer.id)
            replaced = replace(tx, current, invitation, now)
            @portal.insert_invitation(tx, invitation, Identity::Tokens.digest("#{tx.tenant_id!}.#{@ids.token(32)}"))
            @notifier.portal_invitation(tx, invitation)
            @audit.record(tx, current, "portal.invited", "customer", customer.id,
                          "invitation_id" => invitation.id, "contact_id" => contact.id, "email" => invitation.email,
                          "replaced_invitation_ids" => replaced.map(&:id))
            invitation
          end
        end

        private

        # Cancela os convites em aberto substituídos (liberando o índice de convite pendente único) e
        # registra cada cancelamento no cliente do convite cancelado.
        def replace(tx, current, invitation, now)
          open = @portal.lock_open_invitations_for_email(tx, invitation.email)
          PT::Rules.replaceable!(open, invitation.customer_id, now) { |id| @customers.find(tx, id).name }.each do |old|
            @portal.revoke_invitation(tx, old.revoke(now), current.user_id)
            @audit.record(tx, current, "portal.invitation_cancelled", "customer", old.customer_id,
                          "invitation_id" => old.id, "email" => old.email, "reason" => "replaced", "replaced_by" => invitation.id)
          end
        end
      end

      # Cancelamento de convite ainda não aceito.
      class CancelInvitation
        def initialize(uow:, portal:, audit:, clock:)
          @uow = uow
          @portal = portal
          @audit = audit
          @clock = clock
        end

        def call(actor, customer_id:, invitation_id:)
          @uow.run(actor, "customers.write") do |tx, current|
            invitation = @portal.lock_invitation(tx, Domain::Identifier.parse(invitation_id, "convite"))
            raise Domain::NotFound, "convite" unless invitation && invitation.customer_id == Domain::Identifier.parse(customer_id, "cliente")

            cancelled = invitation.revoke(@clock.now)
            @portal.revoke_invitation(tx, cancelled, current.user_id)
            @audit.record(tx, current, "portal.invitation_cancelled", "customer", invitation.customer_id,
                          "invitation_id" => invitation.id, "email" => invitation.email, "reason" => "cancelled")
            cancelled
          end
        end
      end

      # Aceite do convite. O tenant vem do próprio token e é confirmado pelo hash do segredo. Sem
      # `user_id`, cria a conta (nome e senha); com ele, vincula a conta autenticada de mesmo e-mail.
      class AcceptInvitation
        def initialize(uow:, portal:, customers:, users:, limits:, hasher:, audit:, clock:, ids:)
          @uow = uow
          @portal = portal
          @customers = customers
          @users = users
          @limits = limits
          @hasher = hasher
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(token:, user_id: nil, name: nil, password: nil)
          org_id, = token.to_s.split(".", 2)
          raise Domain::ValidationError.field("token", "convite inválido") unless Domain::Identifier.valid?(org_id)

          digest = if user_id.nil?
                     Domain::Identity::PasswordPolicy.validate!(password)
                     @hasher.hash(password)
                   end
          now = @clock.now
          @uow.anonymous(tenant_id: org_id, user_id: user_id) do |tx|
            invitation = @portal.lock_invitation_by_digest(tx, Identity::Tokens.digest(token))
            raise Domain::ValidationError.field("token", "convite inválido ou expirado") unless invitation&.pending?(now)

            @limits.feature!(tx, FEATURE)
            customer = @customers.find(tx, invitation.customer_id)
            raise Domain::ValidationError.field("cliente", "o cadastro do cliente não está ativo") unless customer&.status == "active"

            member_id = resolve_user(tx, invitation, user_id, name, digest, now)
            access = grant(tx, invitation, member_id, now)
            @portal.mark_accepted(tx, invitation.accept(member_id, now))
            actor = Actor.customer(user_id: member_id, organization_id: org_id, customer_id: customer.id)
            @audit.record(tx, actor, "portal.access_granted", "customer", customer.id, "invitation_id" => invitation.id, "access_id" => access.id)
            { organization_id: org_id, user_id: member_id, customer_id: customer.id, access_id: access.id }
          end
        end

        private

        def resolve_user(tx, invitation, user_id, name, digest, now)
          if user_id
            user = @users.find(tx, user_id)
            raise Domain::AccessDenied, "o convite foi enviado para outro e-mail" unless user && user["email"] == invitation.email

            return user_id
          end
          if @users.find_by_email(tx, invitation.email)
            raise Domain::Conflict.new("já existe conta com este e-mail; entre para aceitar o convite", code: "login_required")
          end

          new_id = @ids.uuid
          @users.insert(tx, "id" => new_id, "email" => invitation.email, "name" => Domain::Organizations::Text.required(name, "nome", max: 120),
                            "password_digest" => digest, "email_confirmed_at" => now, "created_at" => now, "updated_at" => now)
          new_id
        end

        def grant(tx, invitation, user_id, now)
          existing = @portal.lock_access_for_user(tx, user_id)
          if existing
            access = existing.reactivate(invitation)
            @portal.reactivate_access(tx, access, now)
            return access
          end

          access = PT::Access.grant(id: @ids.uuid, organization_id: tx.tenant_id!, user_id: user_id, invitation: invitation, now: now)
          @portal.insert_access(tx, access, invitation.invited_by)
          access
        end
      end

      # Revogação com efeito imediato: a UnitOfWork e a autenticação recusam o acesso na operação
      # seguinte e as sessões de portal do usuário nesta organização são encerradas.
      class RevokeAccess
        def initialize(uow:, portal:, sessions_repository:, audit:, clock:)
          @uow = uow
          @portal = portal
          @sessions = sessions_repository
          @audit = audit
          @clock = clock
        end

        def call(actor, customer_id:, access_id:)
          @uow.run(actor, "customers.write") do |tx, current|
            access = @portal.lock_access(tx, Domain::Identifier.parse(access_id, "acesso"))
            raise Domain::NotFound, "acesso ao portal" unless access && access.customer_id == Domain::Identifier.parse(customer_id, "cliente")

            now = @clock.now
            revoked = access.revoke(now)
            @portal.revoke_access(tx, revoked, current.user_id)
            @sessions.revoke_portal_for_organization(tx, access.user_id, tx.tenant_id!, now, "portal_access_revoked")
            @audit.record(tx, current, "portal.access_revoked", "customer", access.customer_id, "access_id" => access.id, "user_id" => access.user_id)
            revoked
          end
        end
      end

      # Acessos e convites de um cliente (tela do cliente, equipe).
      class ListAccesses
        def initialize(uow:, portal:, customers:, limits:, clock:)
          @uow = uow
          @portal = portal
          @customers = customers
          @limits = limits
          @clock = clock
        end

        def call(actor, customer_id)
          @uow.run(actor, "customers.read") do |tx, _current|
            id = Domain::Identifier.parse(customer_id, "cliente")
            raise Domain::NotFound, "cliente" unless @customers.find(tx, id)

            { accesses: @portal.accesses_for_customer(tx, id), invitations: @portal.invitations_for_customer(tx, id),
              enabled: @limits.includes?(tx, FEATURE), now: @clock.now }
          end
        end
      end

      # Página inicial do cliente: próximas reservas, orçamentos aguardando decisão, contratos
      # aguardando aceite e saldo em aberto.
      class Home
        LIMIT = 5
        CLOSED_RESERVATIONS = %w[cancelled expired completed].freeze

        def initialize(uow:, customers:, reservations:, quotes:, contracts:, receivables:, clock:)
          @uow = uow
          @customers = customers
          @reservations = reservations
          @quotes = quotes
          @contracts = contracts
          @receivables = receivables
          @clock = clock
        end

        def call(actor)
          @uow.run(Portal.customer!(actor), PERMISSION) do |tx, current|
            customer = @customers.find(tx, current.customer_id) || raise(Domain::NotFound, "cliente")
            upcoming, = @reservations.search(tx, status: nil, customer_id: customer.id, search: "", from: @clock.now, to: nil, sort: "starts_at",
                                                 limit: LIMIT * 4, offset: 0)
            reservations = upcoming.reject { |row| CLOSED_RESERVATIONS.include?(row[:reservation].status) }.first(LIMIT)
            quotes, quotes_total = @quotes.search(tx, status: "sent", customer_id: customer.id, search: "", sort: "-created_at", limit: LIMIT,
                                                      offset: 0, sent_only: true)
            contracts, contracts_total = @contracts.search(tx, status: "issued", customer_id: customer.id, search: "", limit: LIMIT, offset: 0)
            { customer: customer, reservations: reservations, quotes: quotes, quotes_total: quotes_total, contracts: contracts,
              contracts_total: contracts_total, totals: @receivables.customer_totals(tx, customer.id) }
          end
        end
      end

      # Disponibilidade de um produto ativo para o cliente: somente se atende a quantidade pedida,
      # sem totais de frota, ativos ou alocações.
      ProductAvailability = Data.define(:product_id, :name, :description, :category, :requested, :available)

      # Consulta de disponibilidade pelo cliente. Compõe a consulta da equipe na mesma transação e
      # reduz o resultado ao necessário para decidir uma solicitação.
      class CheckAvailability
        MAX_DAYS = 90

        def initialize(uow:, organizations:, check:, clock:)
          @uow = uow
          @organizations = organizations
          @check = check
          @clock = clock
        end

        def call(actor, branch_id:, period:, lines: [])
          Domain::Reservations::Rules.validate_start!(period, @clock.now)
          raise Domain::ValidationError.field("fim", "período de no máximo #{MAX_DAYS} dias") if period.duration_seconds > MAX_DAYS * 86_400

          requested = lines.empty? ? {} : Domain::Reservations::Rules.normalize_lines(lines).to_h { |l| [l.product_id, l.quantity] }
          @uow.run(Portal.customer!(actor), PERMISSION) do |tx, current|
            branch = Domain::Identifier.parse(branch_id, "filial")
            raise Domain::NotFound, "filial" unless @organizations.branch_active?(tx, branch)

            @check.call(current, branch_id: branch, period: period, tx: tx).map { |row| present(row, requested) }
          end
        end

        # Filiais ativas para a escolha do local de retirada (somente nome e identificador são exibidos).
        def branches(actor)
          @uow.run(Portal.customer!(actor), PERMISSION) { |tx, _current| @organizations.branches(tx).select(&:active) }
        end

        private

        def present(row, requested)
          product = row["product"]
          wanted = requested[product.id]
          ProductAvailability.new(product_id: product.id, name: product.name, description: product.description, category: product.category,
                                  requested: wanted, available: row["available"] >= (wanted || 1))
        end
      end

      # Solicitação de reserva pelo cliente: CreateReservation em modo `request` com origem `portal`,
      # sempre para o próprio cliente. A solicitação não aloca nem garante disponibilidade.
      class RequestReservation
        def initialize(uow:, create_reservation:)
          @uow = uow
          @create_reservation = create_reservation
        end

        def call(actor, branch_id:, period:, lines:, notes: nil)
          @uow.run(Portal.customer!(actor), PERMISSION) do |tx, current|
            @create_reservation.call(current, { customer_id: current.customer_id, branch_id: branch_id, period: period, lines: lines,
                                                mode: "request", source: "portal", notes: notes }, tx: tx)
          end
        end
      end

      # Escopo de anexos do portal: o cliente baixa somente documentos gerados de contratos próprios.
      class ContractDocumentScope
        def initialize(contracts:)
          @contracts = contracts
        end

        def customer_owns?(tx, customer_id, attachment)
          attachment["owner_type"] == "contract" && @contracts.customer_document?(tx, attachment["id"], customer_id)
        end
      end
    end
  end
end
