# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Consultas de apoio às configurações da organização e à gestão de filiais, incluídas em
      # OrganizationRepository (um único repositório de organizações). Todas filtram `organization_id` pelo
      # tenant da transação, além da RLS.
      module OrganizationQueries
        CODES_SHOWN = Domain::Organizations::Branch::CODES_SHOWN

        def active_branch_count(tx)
          tx.query_value("SELECT count(*) FROM branches WHERE organization_id = $1 AND active", [tx.tenant_id!]).to_i
        end

        # Ativos (exceto baixados) e unidades de estoque da filial; não impedem a desativação.
        def branch_usage(tx, branch_id)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, branch_id])
            SELECT (SELECT count(*) FROM assets WHERE organization_id = $1 AND branch_id = $2 AND status <> 'retired') AS assets,
                   (SELECT COALESCE(sum(total_quantity), 0) FROM stock_pools WHERE organization_id = $1 AND branch_id = $2) AS stock_units
          SQL
          { assets: row["assets"].to_i, stock_units: row["stock_units"].to_i }
        end

        # Compromissos que impedem a desativação (regras em Domain::Organizations::Branch), cada um com a
        # contagem total e até CODES_SHOWN códigos.
        def branch_commitments(tx, branch_id, now)
          org = tx.tenant_id!
          branch = Domain::Organizations::Branch
          { reservations: codes(tx, <<~SQL, [org, branch_id, branch::BLOCKING_RESERVATIONS, now]),
            SELECT code, count(*) OVER () AS total FROM reservations
             WHERE organization_id = $1 AND branch_id = $2 AND status = ANY($3::text[]) AND (status <> 'held' OR hold_expires_at > $4)
             ORDER BY code LIMIT #{CODES_SHOWN}
          SQL
            sent_quotes: codes(tx, <<~SQL, [org, branch_id, now]),
              SELECT q.code, count(*) OVER () AS total
                FROM quotes q JOIN quote_versions v ON v.organization_id = q.organization_id AND v.quote_id = q.id AND v.version = q.current_version
               WHERE q.organization_id = $1 AND v.branch_id = $2 AND q.status = 'sent' AND v.valid_until > $3
               ORDER BY q.code LIMIT #{CODES_SHOWN}
            SQL
            approved_quotes: codes(tx, <<~SQL, [org, branch_id]),
              SELECT code, count(*) OVER () AS total FROM quotes
               WHERE organization_id = $1 AND branch_id = $2 AND status = 'approved'
               ORDER BY code LIMIT #{CODES_SHOWN}
            SQL
            incoming_transfers: codes(tx, <<~SQL, [org, branch_id, branch::BLOCKING_TRANSFERS]) }
              SELECT code, count(*) OVER () AS total FROM transfers
               WHERE organization_id = $1 AND to_branch_id = $2 AND status = ANY($3::text[])
               ORDER BY code LIMIT #{CODES_SHOWN}
            SQL
        end

        # Registros afetados por uma troca de fuso: reservas em aberto (mesmo critério da desativação de
        # filial), contratos em aberto e cupons e condições negociadas com instante de vigência futuro.
        def timezone_impact(tx, now)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, Domain::Organizations::Branch::BLOCKING_RESERVATIONS, now])
            SELECT (SELECT count(*) FROM reservations WHERE organization_id = $1 AND status = ANY($2::text[])
                       AND (status <> 'held' OR hold_expires_at > $3)) AS open_reservations,
                   (SELECT count(*) FROM contracts WHERE organization_id = $1 AND status IN ('issued', 'active')) AS open_contracts,
                   (SELECT count(*) FROM coupons WHERE organization_id = $1 AND active AND (valid_from > $3 OR valid_until > $3))
                 + (SELECT count(*) FROM customer_price_agreements WHERE organization_id = $1
                       AND (valid_from > $3 OR LEAST(valid_until, ended_at) > $3)) AS scheduled_terms
          SQL
          row.to_h { |key, value| [key.to_sym, value.to_i] }
        end

        private

        def codes(tx, sql, params)
          rows = tx.query(sql, params)
          { count: rows.first ? rows.first["total"].to_i : 0, codes: rows.map { |row| row["code"] } }
        end
      end
    end
  end
end
