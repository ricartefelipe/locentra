# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Orçamentos e versões. Versões são somente inserção (UPDATE/DELETE revogados no banco).
      class QuoteRepository
        Q = Domain::Quotes
        COLUMNS = "id, organization_id, code, customer_id, branch_id, status, current_version, approved_version, hold_policy, hold_minutes, " \
                  "hold_reservation_id, reservation_id, sent_at, approved_at, approved_by_type, approved_by_user_id, approved_by_name, " \
                  "approved_ip, rejected_at, rejection_reason, expired_at, converted_at, lock_version"
        VERSION_COLUMNS = "id, quote_id, version, branch_id, starts_at, ends_at, valid_until, items, pricing, terms, manual_discount_bps, " \
                          "deposit_cents, total_cents, created_at"
        SORTS = { "-created_at" => "q.created_at DESC, q.id", "created_at" => "q.created_at ASC, q.id", "code" => "q.code ASC" }.freeze

        def insert(tx, quote, created_by, now)
          tx.execute(<<~SQL, [quote.id, quote.organization_id, quote.code, quote.customer_id, quote.branch_id, quote.status, quote.current_version, quote.hold_policy, quote.hold_minutes, created_by, now])
            INSERT INTO quotes (id, organization_id, code, customer_id, branch_id, status, current_version, hold_policy, hold_minutes, created_by,
                                created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
          SQL
        end

        def assign_code(tx, id, code)
          tx.execute("UPDATE quotes SET code = $3 WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id, code])
        end

        def insert_version(tx, version, created_by)
          tx.execute(<<~SQL, [version.id, tx.tenant_id!, version.quote_id, version.number, version.branch_id, version.period.starts_at, version.period.ends_at, version.valid_until, Infrastructure::Database::Params.json(version.items), version.pricing, version.terms, version.manual_discount_bps, version.deposit.cents, version.total.cents, created_by, version.created_at])
            INSERT INTO quote_versions (id, organization_id, quote_id, version, branch_id, starts_at, ends_at, valid_until, items, pricing, terms,
                                        manual_discount_bps, deposit_cents, total_cents, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11, $12, $13, $14, $15, $16)
          SQL
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM quotes WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM quotes WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        # Orçamento enviado ou aprovado, ainda não convertido, cujo bloqueio temporário é a reserva.
        def holding(tx, reservation_id)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT #{COLUMNS} FROM quotes
             WHERE organization_id = $1 AND hold_reservation_id = $2 AND status IN ('sent', 'approved') LIMIT 1
          SQL
          row && self.class.map(row)
        end

        # Orçamento ligado à reserva, seja pela conversão ou pelo bloqueio temporário do envio.
        def find_by_reservation(tx, reservation_id)
          row = tx.query_one(<<~SQL, [tx.tenant_id!, reservation_id])
            SELECT #{COLUMNS} FROM quotes WHERE organization_id = $1 AND (reservation_id = $2 OR hold_reservation_id = $2)
             ORDER BY created_at DESC LIMIT 1
          SQL
          row && self.class.map(row)
        end

        # Atualização otimista: a versão de lock lida precisa ser a anterior à gravada.
        def update(tx, quote, now)
          count = tx.execute(<<~SQL, [tx.tenant_id!, quote.id, quote.status, quote.current_version, quote.approved_version, quote.branch_id, quote.hold_policy, quote.hold_minutes, quote.hold_reservation_id, quote.reservation_id, quote.sent_at, quote.approved_at, quote.approved_by_type, quote.approved_by_user_id, quote.approved_by_name, quote.approved_ip, quote.rejected_at, quote.rejection_reason, quote.expired_at, quote.converted_at, quote.lock_version, now])
            UPDATE quotes
               SET status = $3, current_version = $4, approved_version = $5, branch_id = $6, hold_policy = $7, hold_minutes = $8,
                   hold_reservation_id = $9, reservation_id = $10, sent_at = $11, approved_at = $12, approved_by_type = $13,
                   approved_by_user_id = $14, approved_by_name = $15, approved_ip = $16, rejected_at = $17, rejection_reason = $18,
                   expired_at = $19, converted_at = $20, lock_version = $21, updated_at = $22
             WHERE organization_id = $1 AND id = $2 AND lock_version = $21 - 1
          SQL
          raise Domain::Conflict.new("orçamento alterado por outra operação", code: "stale_quote") unless count == 1
        end

        def find_version(tx, quote_id, number)
          row = tx.query_one("SELECT #{VERSION_COLUMNS} FROM quote_versions WHERE organization_id = $1 AND quote_id = $2 AND version = $3",
                             [tx.tenant_id!, quote_id, number])
          row && self.class.map_version(row)
        end

        def versions(tx, quote_id)
          tx.query("SELECT #{VERSION_COLUMNS} FROM quote_versions WHERE organization_id = $1 AND quote_id = $2 ORDER BY version DESC",
                   [tx.tenant_id!, quote_id]).map { |row| self.class.map_version(row) }
        end

        # Orçamentos enviados cuja versão atual venceu. SKIP LOCKED ignora orçamentos em uso.
        def lock_expired_sent(tx, now, limit)
          tx.query(<<~SQL, [tx.tenant_id!, now, limit]).map { |row| self.class.map(row) }
            SELECT #{COLUMNS.split(", ").map { |c| "q.#{c}" }.join(", ")}
              FROM quotes q JOIN quote_versions v ON v.organization_id = q.organization_id AND v.quote_id = q.id AND v.version = q.current_version
             WHERE q.organization_id = $1 AND q.status = 'sent' AND v.valid_until <= $2
             ORDER BY v.valid_until LIMIT $3
               FOR UPDATE OF q SKIP LOCKED
          SQL
        end

        def search(tx, status:, customer_id:, search:, sort:, limit:, offset:)
          params = [tx.tenant_id!]
          conditions = ["q.organization_id = $1"]
          { "q.status = $%d" => status, "q.customer_id = $%d" => customer_id }.each do |fragment, value|
            next if value.nil?

            params << value
            conditions << format(fragment, params.size)
          end
          unless search.to_s.empty?
            params << "%#{search.upcase.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
            conditions << "(q.code LIKE $#{params.size} ESCAPE '\\' OR upper(c.name) LIKE $#{params.size} ESCAPE '\\')"
          end
          where = conditions.join(" AND ")
          from_sql = "FROM quotes q JOIN customers c ON c.organization_id = q.organization_id AND c.id = q.customer_id " \
                     "JOIN quote_versions v ON v.organization_id = q.organization_id AND v.quote_id = q.id AND v.version = q.current_version"
          total = tx.query_value("SELECT count(*) #{from_sql} WHERE #{where}", params)
          rows = tx.query(<<~SQL, params + [limit, offset])
            SELECT #{COLUMNS.split(", ").map { |c| "q.#{c}" }.join(", ")}, c.name AS customer_name, v.total_cents, v.valid_until,
                   v.starts_at, v.ends_at
              #{from_sql} WHERE #{where} ORDER BY #{SORTS.fetch(sort)} LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}
          SQL
          [rows.map { |row| search_row(row) }, total]
        end

        def self.map(row)
          Q::Quote.new(**row.slice(*COLUMNS.split(", ")).transform_keys(&:to_sym))
        end

        def self.map_version(row)
          Q::Version.new(id: row["id"], quote_id: row["quote_id"], number: row["version"], branch_id: row["branch_id"],
                         period: Domain::Period.new(row["starts_at"], row["ends_at"]), valid_until: row["valid_until"].utc,
                         items: row["items"], pricing: row["pricing"], terms: row["terms"], manual_discount_bps: row["manual_discount_bps"],
                         deposit: Domain::Money.new(row["deposit_cents"]), total: Domain::Money.new(row["total_cents"]),
                         created_at: row["created_at"].utc)
        end

        private

        def search_row(row)
          { quote: self.class.map(row), customer_name: row["customer_name"], total: Domain::Money.new(row["total_cents"]),
            valid_until: row["valid_until"].utc, period: Domain::Period.new(row["starts_at"], row["ends_at"]) }
        end
      end
    end
  end
end
