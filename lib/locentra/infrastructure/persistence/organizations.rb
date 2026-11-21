# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class OrganizationRepository
        include OrganizationQueries

        D = Domain::Organizations
        LOCKS = { nil => "", share: " FOR SHARE", update: " FOR NO KEY UPDATE" }.freeze
        ORGANIZATION_COLUMNS = "id, name, slug, timezone, status, settings, lock_version"
        BRANCH_COLUMNS = "id, organization_id, name, code, address, active, deactivated_at, lock_version"

        def find(tx, id)
          row = tx.query_one("SELECT #{ORGANIZATION_COLUMNS} FROM organizations WHERE id = $1", [id])
          row && map_organization(row)
        end

        # Trava da organização do contexto para alterar as configurações ou contar as filiais ativas. FOR NO
        # KEY UPDATE não conflita com as chaves estrangeiras (FOR KEY SHARE) das inserções do tenant.
        def lock(tx, id)
          row = tx.query_one("SELECT #{ORGANIZATION_COLUMNS} FROM organizations WHERE id = $1 AND id = $2 FOR NO KEY UPDATE", [id, tx.tenant_id!])
          row && map_organization(row)
        end

        # Grava a revisão das configurações se a versão ainda for a esperada; devolve o número de linhas.
        def update_settings(tx, org, expected, now)
          tx.execute(<<~SQL, [tx.tenant_id!, org.name, org.timezone, org.settings, org.lock_version, now, expected])
            UPDATE organizations SET name = $2, timezone = $3, settings = $4, lock_version = $5, updated_at = $6
             WHERE id = $1 AND lock_version = $7
          SQL
        end

        def find_plan(tx, plan_id)
          tx.query_one("SELECT * FROM plans WHERE id = $1 AND active", [plan_id.to_s])
        end

        def plans(tx)
          tx.query("SELECT * FROM plans WHERE active ORDER BY position")
        end

        def insert(tx, org, now)
          tx.execute(<<~SQL, [org.id, org.name, org.slug, org.timezone, org.status, org.settings, now])
            INSERT INTO organizations (id, name, slug, timezone, status, settings, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
          SQL
        rescue Domain::Conflict
          raise Domain::Conflict.new("identificador da organização já utilizado; escolha outro nome", code: "slug_taken")
        end

        def insert_branch(tx, branch, now)
          tx.execute(<<~SQL, [branch.id, branch.organization_id, branch.name, branch.code, branch.address, now])
            INSERT INTO branches (id, organization_id, name, code, address, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $6)
          SQL
        rescue Domain::Conflict
          raise Domain::Conflict.new("código de filial já utilizado", code: "duplicate_branch")
        end

        def branches(tx)
          tx.query("SELECT #{BRANCH_COLUMNS} FROM branches WHERE organization_id = $1 ORDER BY name, code",
                   [tx.tenant_id!]).map { |row| map_branch(row) }
        end

        # Filial do tenant, ativa ou não. `lock`: nil (leitura), :share (FOR SHARE, operações que criam vínculo
        # com a filial) ou :update (FOR NO KEY UPDATE, edição, desativação e reativação).
        def find_branch(tx, id, lock: nil)
          clause = LOCKS.fetch(lock) { raise ArgumentError, "trava desconhecida: #{lock.inspect}" }
          row = tx.query_one("SELECT #{BRANCH_COLUMNS} FROM branches WHERE organization_id = $1 AND id = $2#{clause}", [tx.tenant_id!, id])
          row && map_branch(row)
        end

        def lock_branch(tx, id) = find_branch(tx, id, lock: :update)

        # Grava a filial se a versão ainda for a esperada; devolve o número de linhas. O código não muda.
        def update_branch(tx, branch, expected, now)
          tx.execute(<<~SQL, [tx.tenant_id!, branch.id, branch.name, branch.address, branch.active, branch.deactivated_at, branch.lock_version, now, expected])
            UPDATE branches SET name = $3, address = $4, active = $5, deactivated_at = $6, lock_version = $7, updated_at = $8
             WHERE organization_id = $1 AND id = $2 AND lock_version = $9
          SQL
        end

        def insert_membership(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "user_id", "role", "created_at"))
            INSERT INTO memberships (id, organization_id, user_id, role, status, created_at, updated_at) VALUES ($1, $2, $3, $4, 'active', $5, $5)
          SQL
        end

        def upsert_membership(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "user_id", "role", "created_at"))
            INSERT INTO memberships (id, organization_id, user_id, role, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, 'active', $5, $5)
            ON CONFLICT (organization_id, user_id)
            DO UPDATE SET role = EXCLUDED.role, status = 'active', revoked_at = NULL, revoked_by = NULL, updated_at = EXCLUDED.updated_at
          SQL
        end

        def active_membership(tx, organization_id, user_id)
          tx.query_one("SELECT id, role FROM memberships WHERE organization_id = $1 AND user_id = $2 AND status = 'active'",
                       [organization_id, user_id])
        end

        # Organizações visíveis ao usuário (RLS: vínculos próprios e organizações das quais é membro).
        def memberships_for_user(tx, user_id)
          staff = tx.query(<<~SQL, [user_id])
            SELECT o.id AS organization_id, o.name, o.slug, m.role, 'staff' AS kind
              FROM memberships m JOIN organizations o ON o.id = m.organization_id
             WHERE m.user_id = $1 AND m.status = 'active' AND o.status = 'active'
          SQL
          portal = tx.query(<<~SQL, [user_id])
            SELECT o.id AS organization_id, o.name, o.slug, NULL AS role, 'portal' AS kind, p.customer_id
              FROM portal_accesses p JOIN organizations o ON o.id = p.organization_id
             WHERE p.user_id = $1 AND p.status = 'active' AND o.status = 'active'
          SQL
          (staff + portal).sort_by { |row| row["name"] }
        end

        def active_member_email?(tx, email)
          !tx.query_one(<<~SQL, [tx.tenant_id!, email]).nil?
            SELECT 1 FROM memberships m JOIN users u ON u.id = m.user_id
             WHERE m.organization_id = $1 AND u.email = $2 AND m.status = 'active'
          SQL
        end

        def members(tx)
          tx.query(<<~SQL, [tx.tenant_id!])
            SELECT m.id, m.user_id, m.role, m.status, m.created_at, m.revoked_at, u.name, u.email
              FROM memberships m JOIN users u ON u.id = m.user_id
             WHERE m.organization_id = $1
             ORDER BY m.status, u.name
          SQL
        end

        def lock_membership(tx, id)
          tx.query_one("SELECT id, user_id, role, status FROM memberships WHERE organization_id = $1 AND id = $2 FOR UPDATE",
                       [tx.tenant_id!, id])
        end

        def update_membership_role(tx, id, role, now)
          tx.execute("UPDATE memberships SET role = $3, updated_at = $4 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, id, role, now])
        end

        def revoke_membership(tx, id, by, now)
          tx.execute(<<~SQL, [tx.tenant_id!, id, by, now])
            UPDATE memberships SET status = 'revoked', revoked_at = $4, revoked_by = $3, updated_at = $4
             WHERE organization_id = $1 AND id = $2 AND status = 'active'
          SQL
        end

        def insert_invitation(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "email", "role", "token_digest", "invited_by", "expires_at", "created_at"))
            INSERT INTO invitations (id, organization_id, email, role, token_digest, invited_by, expires_at, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          SQL
        end

        def revoke_pending_invitations(tx, email, now)
          tx.execute(<<~SQL, [tx.tenant_id!, email, now])
            UPDATE invitations SET revoked_at = $3 WHERE organization_id = $1 AND email = $2 AND accepted_at IS NULL AND revoked_at IS NULL
          SQL
        end

        def lock_invitation(tx, digest)
          tx.query_one(<<~SQL, [tx.tenant_id!, digest])
            SELECT id, email, role, expires_at, accepted_at, revoked_at FROM invitations
             WHERE organization_id = $1 AND token_digest = $2 FOR UPDATE
          SQL
        end

        def mark_invitation_accepted(tx, id, user_id, now)
          tx.execute("UPDATE invitations SET accepted_at = $3, accepted_user_id = $2 WHERE organization_id = $4 AND id = $1",
                     [id, user_id, now, tx.tenant_id!])
        end

        def pending_invitations(tx)
          tx.query(<<~SQL, [tx.tenant_id!])
            SELECT id, email, role, expires_at, created_at FROM invitations
             WHERE organization_id = $1 AND accepted_at IS NULL AND revoked_at IS NULL ORDER BY created_at DESC
          SQL
        end

        def insert_subscription(tx, row)
          tx.execute(<<~SQL, row.values_at("id", "organization_id", "plan_id", "status", "started_at", "trial_ends_at", "current_period_start", "current_period_end", "implementation_fee_cents", "created_at"))
            INSERT INTO subscriptions (id, organization_id, plan_id, status, started_at, trial_ends_at, current_period_start,
                                       current_period_end, implementation_fee_cents, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10)
          SQL
        end

        def subscription(tx)
          tx.query_one(<<~SQL, [tx.tenant_id!])
            SELECT s.*, p.name AS plan_name, p.monthly_price_cents, p.max_assets, p.max_branches, p.max_users, p.features
              FROM subscriptions s JOIN plans p ON p.id = s.plan_id WHERE s.organization_id = $1
          SQL
        end

        # Código legível sequencial por organização (R-000001). O UPDATE serializa concorrentes.
        def next_code(tx, name, prefix)
          value = tx.query_value(<<~SQL, [tx.tenant_id!, name])
            INSERT INTO organization_counters (organization_id, name, value) VALUES ($1, $2, 1)
            ON CONFLICT (organization_id, name) DO UPDATE SET value = organization_counters.value + 1
            RETURNING value
          SQL
          format("%<prefix>s-%<value>06d", prefix: prefix, value: value)
        end

        private

        def map_organization(row)
          D::Organization.new(id: row["id"], name: row["name"], slug: row["slug"], timezone: row["timezone"], status: row["status"],
                              settings: row["settings"] || {}, lock_version: row["lock_version"])
        end

        def map_branch(row)
          D::Branch.new(id: row["id"], organization_id: row["organization_id"], name: row["name"], code: row["code"],
                        address: row["address"], active: row["active"], deactivated_at: row["deactivated_at"]&.getutc,
                        lock_version: row["lock_version"])
        end
      end

      class SubscriptionRepository
        CURRENT = <<~SQL
          SELECT s.id, s.status, s.extra_features, p.name AS plan_name, p.max_assets, p.max_branches, p.max_users, p.features
            FROM subscriptions s JOIN plans p ON p.id = s.plan_id
           WHERE s.organization_id = $1
        SQL

        def lock_current(tx)
          tx.query_one("#{CURRENT} FOR UPDATE OF s", [tx.tenant_id!])
        end

        def current(tx)
          tx.query_one(CURRENT, [tx.tenant_id!])
        end

        def usage(tx, kind)
          org = tx.tenant_id!
          case kind
          when :assets
            tx.query_value(<<~SQL, [org])
              SELECT (SELECT count(*) FROM assets WHERE organization_id = $1 AND status <> 'retired')
                   + (SELECT COALESCE(sum(total_quantity), 0) FROM stock_pools WHERE organization_id = $1)
            SQL
          when :branches
            tx.query_value("SELECT count(*) FROM branches WHERE organization_id = $1 AND active", [org])
          when :users
            tx.query_value(<<~SQL, [org])
              SELECT (SELECT count(*) FROM memberships WHERE organization_id = $1 AND status = 'active')
                   + (SELECT count(*) FROM invitations WHERE organization_id = $1 AND accepted_at IS NULL AND revoked_at IS NULL)
            SQL
          else raise ArgumentError, "limite desconhecido: #{kind}"
          end.to_i
        end
      end
    end
  end
end
