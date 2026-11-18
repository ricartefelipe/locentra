# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Convites e acessos do portal do cliente. Toda consulta filtra a organização do contexto.
      class PortalRepository
        PT = Domain::Portal
        INVITATION_COLUMNS = "i.id, i.organization_id, i.customer_id, i.contact_id, i.email, i.invited_by, i.expires_at, i.accepted_at, " \
                             "i.accepted_user_id, i.revoked_at, i.created_at"
        ACCESS_COLUMNS = "p.id, p.organization_id, p.user_id, p.customer_id, p.contact_id, p.invitation_id, p.status, p.created_at, p.revoked_at"

        def insert_invitation(tx, invitation, token_digest)
          tx.execute(<<~SQL, [invitation.id, tx.tenant_id!, invitation.customer_id, invitation.contact_id, invitation.email, token_digest, invitation.invited_by, invitation.expires_at, invitation.created_at])
            INSERT INTO portal_invitations (id, organization_id, customer_id, contact_id, email, token_digest, invited_by, expires_at, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
          SQL
        end

        # Cancela convites ainda não aceitos do e-mail na organização (inclusive os vencidos), liberando
        # o índice de convite pendente único.
        def revoke_pending_invitations(tx, email, by, now)
          tx.execute(<<~SQL, [tx.tenant_id!, email, by, now])
            UPDATE portal_invitations SET revoked_at = $4, revoked_by = $3
             WHERE organization_id = $1 AND email = $2 AND accepted_at IS NULL AND revoked_at IS NULL
          SQL
        end

        def lock_invitation(tx, id)
          row = tx.query_one("SELECT #{INVITATION_COLUMNS} FROM portal_invitations i WHERE i.organization_id = $1 AND i.id = $2 FOR UPDATE",
                             [tx.tenant_id!, id])
          row && map_invitation(row)
        end

        def lock_invitation_by_digest(tx, digest)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, digest])
            SELECT #{INVITATION_COLUMNS} FROM portal_invitations i WHERE i.organization_id = $1 AND i.token_digest = $2 FOR UPDATE
          SQL
          row && map_invitation(row)
        end

        # Convite ainda utilizável no momento do envio do e-mail (bloqueado para a troca do token).
        def lock_deliverable_invitation(tx, id, now)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, id, now])
            SELECT #{INVITATION_COLUMNS} FROM portal_invitations i
             WHERE i.organization_id = $1 AND i.id = $2 AND i.accepted_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > $3
               FOR UPDATE
          SQL
          row && map_invitation(row)
        end

        def assign_token(tx, id, digest)
          tx.execute("UPDATE portal_invitations SET token_digest = $3 WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id, digest])
        end

        def mark_accepted(tx, invitation)
          tx.execute(<<~SQL, [tx.tenant_id!, invitation.id, invitation.accepted_user_id, invitation.accepted_at])
            UPDATE portal_invitations SET accepted_at = $4, accepted_user_id = $3
             WHERE organization_id = $1 AND id = $2 AND accepted_at IS NULL AND revoked_at IS NULL
          SQL
        end

        def revoke_invitation(tx, invitation, by)
          tx.execute(<<~SQL, [tx.tenant_id!, invitation.id, by, invitation.revoked_at])
            UPDATE portal_invitations SET revoked_at = $4, revoked_by = $3
             WHERE organization_id = $1 AND id = $2 AND accepted_at IS NULL AND revoked_at IS NULL
          SQL
        end

        def invitations_for_customer(tx, customer_id, limit: 20)
          tx.query(<<~SQL, [tx.tenant_id!, customer_id, limit]).map { |row| { invitation: map_invitation(row), contact_name: row["contact_name"] } }
            SELECT #{INVITATION_COLUMNS}, c.name AS contact_name
              FROM portal_invitations i
              JOIN customer_contacts c ON c.organization_id = i.organization_id AND c.id = i.contact_id
             WHERE i.organization_id = $1 AND i.customer_id = $2
             ORDER BY i.created_at DESC, i.id DESC LIMIT $3
          SQL
        end

        # Cliente com acesso ativo para o e-mail na organização (nil quando não há).
        def active_customer_for_email(tx, email)
          tx.query_value(<<~SQL, [tx.tenant_id!, email])
            SELECT p.customer_id FROM portal_accesses p JOIN users u ON u.id = p.user_id
             WHERE p.organization_id = $1 AND u.email = $2 AND p.status = 'active'
          SQL
        end

        def lock_access(tx, id)
          row = tx.query_one("SELECT #{ACCESS_COLUMNS} FROM portal_accesses p WHERE p.organization_id = $1 AND p.id = $2 FOR UPDATE",
                             [tx.tenant_id!, id])
          row && map_access(row)
        end

        def lock_access_for_user(tx, user_id)
          row = tx.query_one("SELECT #{ACCESS_COLUMNS} FROM portal_accesses p WHERE p.organization_id = $1 AND p.user_id = $2 FOR UPDATE",
                             [tx.tenant_id!, user_id])
          row && map_access(row)
        end

        def insert_access(tx, access, created_by)
          tx.execute(<<~SQL, [access.id, tx.tenant_id!, access.user_id, access.customer_id, access.contact_id, access.invitation_id, created_by, access.created_at])
            INSERT INTO portal_accesses (id, organization_id, user_id, customer_id, contact_id, invitation_id, status, created_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, 'active', $7, $8, $8)
          SQL
        end

        def reactivate_access(tx, access, now)
          tx.execute(<<~SQL, [tx.tenant_id!, access.id, access.customer_id, access.contact_id, access.invitation_id, now])
            UPDATE portal_accesses
               SET status = 'active', customer_id = $3, contact_id = $4, invitation_id = $5, revoked_at = NULL, revoked_by = NULL, updated_at = $6
             WHERE organization_id = $1 AND id = $2
          SQL
        end

        def revoke_access(tx, access, by)
          tx.execute(<<~SQL, [tx.tenant_id!, access.id, by, access.revoked_at])
            UPDATE portal_accesses SET status = 'revoked', revoked_at = $4, revoked_by = $3, updated_at = $4
             WHERE organization_id = $1 AND id = $2 AND status = 'active'
          SQL
        end

        def accesses_for_customer(tx, customer_id)
          tx.query(<<~SQL, [tx.tenant_id!, customer_id]).map { |row| { access: map_access(row), name: row["user_name"], email: row["email"] } }
            SELECT #{ACCESS_COLUMNS}, u.name AS user_name, u.email
              FROM portal_accesses p JOIN users u ON u.id = p.user_id
             WHERE p.organization_id = $1 AND p.customer_id = $2
             ORDER BY p.status, u.name, p.id
          SQL
        end

        private

        def map_invitation(row)
          PT::Invitation.new(id: row["id"], organization_id: row["organization_id"], customer_id: row["customer_id"], contact_id: row["contact_id"],
                             email: row["email"], invited_by: row["invited_by"], expires_at: row["expires_at"].utc,
                             accepted_at: row["accepted_at"]&.utc, accepted_user_id: row["accepted_user_id"], revoked_at: row["revoked_at"]&.utc,
                             created_at: row["created_at"].utc)
        end

        def map_access(row)
          PT::Access.new(id: row["id"], organization_id: row["organization_id"], user_id: row["user_id"], customer_id: row["customer_id"],
                         contact_id: row["contact_id"], invitation_id: row["invitation_id"], status: row["status"],
                         created_at: row["created_at"].utc, revoked_at: row["revoked_at"]&.utc)
        end
      end
    end
  end
end
