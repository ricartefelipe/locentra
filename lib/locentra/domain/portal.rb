# frozen_string_literal: true

module Locentra
  module Domain
    # Portal do cliente: convites de acesso enviados pela equipe a contatos do cliente e acessos
    # concedidos a usuários. Um usuário acessa o portal de uma organização como um único cliente.
    module Portal
      INVITATION_TTL_SECONDS = 7 * 86_400

      INVITATION_STATUSES = {
        "pending" => "Aguardando aceite", "accepted" => "Aceito", "revoked" => "Cancelado", "expired" => "Expirado"
      }.freeze
      ACCESS_STATUSES = { "active" => "Ativo", "revoked" => "Revogado" }.freeze

      # Aviso exibido em toda solicitação de reserva feita pelo cliente.
      REQUEST_NOTICE = "A solicitação não garante disponibilidade: os itens só ficam reservados depois da confirmação da locadora, " \
                       "que pode recusar ou propor outro período."

      module Rules
        module_function

        # Um e-mail com acesso ativo na organização não recebe novo convite: para o mesmo cliente o
        # acesso já existe; para outro cliente, o usuário precisaria acessar como dois clientes.
        def grantable!(active_customer_id, customer_id)
          return true if active_customer_id.nil?
          raise Conflict.new("este e-mail já possui acesso ativo ao portal deste cliente", code: "portal_already_granted") if active_customer_id == customer_id

          raise Conflict.new("este e-mail já acessa o portal como outro cliente; revogue aquele acesso antes de convidar",
                             code: "portal_other_customer")
        end

        # Convites em aberto (não aceitos nem cancelados) do mesmo e-mail na organização. O novo
        # convite substitui os do próprio cliente e os já vencidos de qualquer cliente; um convite
        # ainda válido de outro cliente não é cancelado implicitamente: a equipe o cancela na página
        # daquele cliente. O bloco recebe o cliente do convite que impede o novo e devolve o nome
        # exibido na mensagem. Devolve os convites a substituir.
        def replaceable!(open_invitations, customer_id, now)
          blocking = open_invitations.find { |invitation| invitation.customer_id != customer_id && invitation.pending?(now) }
          return open_invitations unless blocking

          raise Conflict.new("este e-mail tem convite pendente ao portal para o cliente #{yield(blocking.customer_id)}; cancele aquele " \
                             "convite na página do cliente antes de convidar por este cadastro", code: "portal_pending_other_customer")
        end
      end

      Invitation = Data.define(:id, :organization_id, :customer_id, :contact_id, :email, :invited_by, :expires_at, :accepted_at,
                               :accepted_user_id, :revoked_at, :created_at) do
        # O convite vai para o e-mail de um contato do próprio cliente, que precisa estar ativo.
        def self.issue(id:, organization_id:, customer:, contact:, invited_by:, now:)
          raise ValidationError.field("cliente", "cliente bloqueado ou inativo não recebe acesso ao portal") unless customer.status == "active"
          raise NotFound, "contato" unless contact && contact.customer_id == customer.id
          raise ValidationError.field("contato", "o contato precisa ter e-mail para receber o convite") if contact.email.to_s.empty?

          new(id: id, organization_id: organization_id, customer_id: customer.id, contact_id: contact.id, email: contact.email,
              invited_by: invited_by, expires_at: now + INVITATION_TTL_SECONDS, accepted_at: nil, accepted_user_id: nil,
              revoked_at: nil, created_at: now)
        end

        # O instante de expiração pertence ao período vencido (`now >= expires_at` é expirado).
        def status(now)
          return "accepted" if accepted_at
          return "revoked" if revoked_at
          return "expired" if now >= expires_at

          "pending"
        end

        def pending?(now) = status(now) == "pending"
        def status_label(now) = INVITATION_STATUSES.fetch(status(now))

        def accept(user_id, now)
          raise ValidationError.field("token", "convite inválido ou expirado") unless pending?(now)

          with(accepted_at: now, accepted_user_id: user_id)
        end

        # Cancelamento pela equipe: convites aceitos ou já cancelados não mudam.
        def revoke(now)
          raise InvalidTransition.new("convite do portal", status(now), "revoked") if accepted_at || revoked_at

          with(revoked_at: now)
        end
      end

      Access = Data.define(:id, :organization_id, :user_id, :customer_id, :contact_id, :invitation_id, :status, :created_at,
                           :revoked_at) do
        def self.grant(id:, organization_id:, user_id:, invitation:, now:)
          new(id: id, organization_id: organization_id, user_id: user_id, customer_id: invitation.customer_id,
              contact_id: invitation.contact_id, invitation_id: invitation.id, status: "active", created_at: now, revoked_at: nil)
        end

        def active? = status == "active"
        def status_label = ACCESS_STATUSES.fetch(status)

        def revoke(now)
          raise Conflict.new("acesso ao portal já revogado", code: "already_revoked") unless active?

          with(status: "revoked", revoked_at: now)
        end

        # Aceite de novo convite por um usuário que já tem registro de acesso na organização: um acesso
        # revogado é reativado para o cliente do convite; um acesso ativo só é mantido para o mesmo cliente.
        def reactivate(invitation)
          if active? && customer_id != invitation.customer_id
            raise Conflict.new("sua conta já acessa o portal desta organização como outro cliente", code: "portal_other_customer")
          end

          with(status: "active", customer_id: invitation.customer_id, contact_id: invitation.contact_id, invitation_id: invitation.id,
               revoked_at: nil)
        end
      end
    end
  end
end
