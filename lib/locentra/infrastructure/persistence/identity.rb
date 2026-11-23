# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class UserRepository
        COLUMNS = "id, email, name, password_digest, email_confirmed_at, failed_login_count, locked_until, created_at"

        def find(tx, id)
          tx.query_one("SELECT #{COLUMNS} FROM users WHERE id = $1", [id])
        end

        def find_by_email(tx, email)
          tx.query_one("SELECT #{COLUMNS} FROM users WHERE email = $1", [email])
        end

        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], row["email"], row["name"], row["password_digest"], row["email_confirmed_at"], row["created_at"], row["updated_at"]])
            INSERT INTO users (id, email, name, password_digest, email_confirmed_at, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
          SQL
        end

        # Incrementa falhas e bloqueia temporariamente ao atingir o limite, numa única instrução.
        def register_failure(tx, id, max_failures, lock_until, now)
          tx.execute(<<~SQL, [id, max_failures, lock_until, now])
            UPDATE users
               SET failed_login_count = failed_login_count + 1,
                   locked_until = CASE WHEN failed_login_count + 1 >= $2 THEN $3::timestamptz ELSE locked_until END,
                   updated_at = $4
             WHERE id = $1
          SQL
        end

        def reset_failures(tx, id, now)
          tx.execute("UPDATE users SET failed_login_count = 0, locked_until = NULL, updated_at = $2 WHERE id = $1", [id, now])
        end

        def confirm_email(tx, id, now)
          tx.execute("UPDATE users SET email_confirmed_at = COALESCE(email_confirmed_at, $2), updated_at = $2 WHERE id = $1", [id, now])
        end

        # Somente enquanto a conta não tem confirmação; devolve se gravou.
        def update_unconfirmed_email(tx, id, email, now)
          tx.execute("UPDATE users SET email = $2, updated_at = $3 WHERE id = $1 AND email_confirmed_at IS NULL", [id, email, now]) == 1
        end

        def update_password(tx, id, digest, now)
          tx.execute("UPDATE users SET password_digest = $2, failed_login_count = 0, locked_until = NULL, updated_at = $3 WHERE id = $1",
                     [id, digest, now])
        end
      end

      class SessionRepository
        def insert(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "token_digest", "kind", "user_id", "organization_id", "csrf_token", "ip", "user_agent", "created_at", "last_seen_at", "idle_expires_at", "absolute_expires_at"))
            INSERT INTO sessions (id, token_digest, kind, user_id, organization_id, csrf_token, ip, user_agent, created_at,
                                  last_seen_at, idle_expires_at, absolute_expires_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
        end

        def find_by_digest(tx, digest)
          tx.query_one(<<~SQL, [digest])
            SELECT s.id, s.kind, s.user_id, s.organization_id, s.csrf_token, s.ip, s.user_agent, s.created_at, s.last_seen_at,
                   s.idle_expires_at, s.absolute_expires_at, s.revoked_at, u.email, u.name AS user_name, u.email_confirmed_at,
                   u.created_at AS user_created_at
              FROM sessions s JOIN users u ON u.id = s.user_id
             WHERE s.token_digest = $1
          SQL
        end

        def touch(tx, id, now, idle_until)
          tx.execute("UPDATE sessions SET last_seen_at = $2, idle_expires_at = $3 WHERE id = $1 AND revoked_at IS NULL",
                     [id, now, idle_until])
        end

        def revoke(tx, id, now, reason)
          tx.execute("UPDATE sessions SET revoked_at = $2, revoked_reason = $3 WHERE id = $1 AND revoked_at IS NULL", [id, now, reason])
        end

        def revoke_all_for_user(tx, user_id, now, reason)
          tx.execute("UPDATE sessions SET revoked_at = $2, revoked_reason = $3 WHERE user_id = $1 AND revoked_at IS NULL",
                     [user_id, now, reason])
        end

        def revoke_for_organization(tx, user_id, organization_id, now, reason)
          tx.execute(<<~SQL, [user_id, organization_id, now, reason])
            UPDATE sessions SET revoked_at = $3, revoked_reason = $4
             WHERE user_id = $1 AND organization_id = $2 AND revoked_at IS NULL
          SQL
        end

        # Somente as sessões do portal: o mesmo usuário pode ter sessões de equipe na organização.
        def revoke_portal_for_organization(tx, user_id, organization_id, now, reason)
          tx.execute(<<~SQL, [user_id, organization_id, now, reason])
            UPDATE sessions SET revoked_at = $3, revoked_reason = $4
             WHERE user_id = $1 AND organization_id = $2 AND kind = 'portal' AND revoked_at IS NULL
          SQL
        end
      end

      class UserTokenRepository
        def insert(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "user_id", "purpose", "token_digest", "expires_at", "created_at"))
            INSERT INTO user_tokens (id, user_id, purpose, token_digest, expires_at, created_at) VALUES ($1, $2, $3, $4, $5, $6)
          SQL
        end

        def invalidate_pending(tx, user_id, purpose, now)
          tx.execute("UPDATE user_tokens SET used_at = $3 WHERE user_id = $1 AND purpose = $2 AND used_at IS NULL", [user_id, purpose, now])
        end

        def usable?(tx, digest, purpose, now)
          !tx.query_one(<<~SQL, [digest, purpose, now]).nil?
            SELECT 1 FROM user_tokens WHERE token_digest = $1 AND purpose = $2 AND used_at IS NULL AND expires_at > $3
          SQL
        end

        # Marca como usado e devolve a linha somente se ainda válido: uso único sob concorrência.
        def consume(tx, digest, purpose, now)
          tx.query_one(<<~SQL, [digest, purpose, now])
            UPDATE user_tokens SET used_at = $3
             WHERE token_digest = $1 AND purpose = $2 AND used_at IS NULL AND expires_at > $3
            RETURNING id, user_id
          SQL
        end
      end

      # Consultas de vínculo usadas pela UnitOfWork para revalidar o ator a cada operação.
      class AccessRepository
        # Traz também a confirmação de e-mail e a criação do usuário (ADR-031): a UnitOfWork calcula a
        # situação da conta no instante da operação.
        def active_membership(tx, organization_id, user_id)
          tx.query_one(<<~SQL, [organization_id, user_id])
            SELECT m.id, m.role, u.email_confirmed_at, u.created_at AS user_created_at
              FROM memberships m JOIN organizations o ON o.id = m.organization_id JOIN users u ON u.id = m.user_id
             WHERE m.organization_id = $1 AND m.user_id = $2 AND m.status = 'active' AND o.status = 'active'
          SQL
        end

        # Como no vínculo de usuários, a organização precisa estar ativa (não suspensa nem encerrada).
        # Quem criou a credencial precisa continuar membro ativo; `creator_role` é o papel atual dele
        # (os escopos efetivos não passam das permissões desse papel). A confirmação de e-mail e a criação
        # de quem a criou dão a situação da credencial (ADR-031); sem criador, as colunas vêm nulas.
        def active_credential(tx, credential_id, now)
          return nil unless credential_id

          tx.query_one(<<~SQL, [credential_id, now])
            SELECT c.id, c.organization_id, c.kind, c.scopes, m.role AS creator_role,
                   u.email_confirmed_at AS creator_email_confirmed_at, u.created_at AS creator_created_at
              FROM api_credentials c JOIN organizations o ON o.id = c.organization_id
              LEFT JOIN memberships m ON m.organization_id = c.organization_id AND m.user_id = c.created_by AND m.status = 'active'
              LEFT JOIN users u ON u.id = c.created_by
             WHERE c.id = $1 AND c.revoked_at IS NULL AND (c.expires_at IS NULL OR c.expires_at > $2) AND o.status = 'active'
               AND (c.created_by IS NULL OR m.id IS NOT NULL)
          SQL
        end

        def active_portal_access(tx, organization_id, user_id)
          tx.query_one(<<~SQL, [organization_id, user_id])
            SELECT p.id, p.customer_id FROM portal_accesses p JOIN organizations o ON o.id = p.organization_id
             WHERE p.organization_id = $1 AND p.user_id = $2 AND p.status = 'active' AND o.status = 'active'
          SQL
        end
      end
    end
  end
end
