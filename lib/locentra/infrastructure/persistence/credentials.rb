# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class CredentialRepository
        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("name", "kind", "token_digest", "token_hint", "scopes", "created_by", "created_at", "expires_at")])
            INSERT INTO api_credentials (id, organization_id, name, kind, token_digest, token_hint, scopes, created_by, created_at, expires_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end

        # Credencial válida de organização ativa (suspensa ou encerrada não autentica) cujo criador
        # continua membro ativo; `creator_role` limita os escopos efetivos.
        def find_active(tx, digest, now)
          tx.query_one(<<~SQL, [tx.tenant_id!, digest, now])
            SELECT c.id, c.kind, c.scopes, m.role AS creator_role
              FROM api_credentials c JOIN organizations o ON o.id = c.organization_id
              LEFT JOIN memberships m ON m.organization_id = c.organization_id AND m.user_id = c.created_by AND m.status = 'active'
             WHERE c.organization_id = $1 AND c.token_digest = $2 AND c.revoked_at IS NULL AND (c.expires_at IS NULL OR c.expires_at > $3)
               AND o.status = 'active' AND (c.created_by IS NULL OR m.id IS NOT NULL)
          SQL
        end

        # Credenciais ativas criadas pelo usuário (revogadas junto com o vínculo dele).
        def revoke_created_by(tx, user_id, now)
          tx.query(<<~SQL, [tx.tenant_id!, user_id, now]).map { |row| row["id"] }
            UPDATE api_credentials SET revoked_at = $3 WHERE organization_id = $1 AND created_by = $2 AND revoked_at IS NULL RETURNING id
          SQL
        end

        def touch(tx, id, now)
          tx.execute(<<~SQL, [id, now])
            UPDATE api_credentials SET last_used_at = $2
             WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < $2::timestamptz - interval '1 minute')
          SQL
        end

        # Metadados da credencial, sem o hash do segredo.
        def find(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT id, name, kind, scopes, created_at, expires_at, revoked_at, last_used_at FROM api_credentials
             WHERE organization_id = $1 AND id = $2
          SQL
        end

        def revoke(tx, id, now)
          tx.execute("UPDATE api_credentials SET revoked_at = $3 WHERE organization_id = $1 AND id = $2 AND revoked_at IS NULL",
                     [tx.tenant_id!, id, now])
        end

        def list(tx)
          tx.query(<<~SQL, [tx.tenant_id!])
            SELECT c.id, c.name, c.kind, c.token_hint, c.scopes, c.created_at, c.expires_at, c.revoked_at, c.last_used_at, u.name AS created_by_name
              FROM api_credentials c LEFT JOIN users u ON u.id = c.created_by
             WHERE c.organization_id = $1 ORDER BY c.created_at DESC
          SQL
        end
      end
    end
  end
end
