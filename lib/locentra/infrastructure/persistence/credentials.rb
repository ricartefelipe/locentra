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

        def find_active(tx, digest, now)
          tx.query_one(<<~SQL, [tx.tenant_id!, digest, now])
            SELECT id, kind, scopes FROM api_credentials
             WHERE organization_id = $1 AND token_digest = $2 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > $3)
          SQL
        end

        def touch(tx, id, now)
          tx.execute(<<~SQL, [id, now])
            UPDATE api_credentials SET last_used_at = $2
             WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < $2::timestamptz - interval '1 minute')
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
