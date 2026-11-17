# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class IdempotencyRepository
        # Retorna true quando a chave foi reservada por esta transação. Em concorrência, o INSERT
        # aguarda a transação que detém a chave terminar.
        def claim(tx, row)
          !tx.query_one(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("scope", "key", "fingerprint", "created_at", "expires_at")]).nil?
            INSERT INTO idempotency_keys (id, organization_id, scope, key, fingerprint, response_status, response_body, created_at, expires_at)
            VALUES ($1, $2, $3, $4, $5, 0, '{}', $6, $7)
            ON CONFLICT (organization_id, scope, key) DO NOTHING
            RETURNING id
          SQL
        end

        def store(tx, scope, key, status, body)
          tx.execute(<<~SQL, [tx.tenant_id!, scope, key, status, body])
            UPDATE idempotency_keys SET response_status = $4, response_body = $5 WHERE organization_id = $1 AND scope = $2 AND key = $3
          SQL
        end

        def find(tx, scope, key)
          tx.query_one(<<~SQL, [tx.tenant_id!, scope, key])
            SELECT fingerprint, response_status, response_body FROM idempotency_keys
             WHERE organization_id = $1 AND scope = $2 AND key = $3 AND response_status > 0
          SQL
        end

        def purge(tx, now)
          tx.execute("DELETE FROM idempotency_keys WHERE organization_id = $1 AND expires_at < $2", [tx.tenant_id!, now])
        end
      end
    end
  end
end
