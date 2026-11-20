# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Catálogo de tarifas adicionais da organização.
      class FeeRepository
        COLUMNS = "id, organization_id, code, name, description, default_amount_cents, active, lock_version, created_by, created_at, " \
                  "updated_at, deactivated_at"
        SORTS = { "name" => "lower(name), id", "code" => "code, id", "-created_at" => "created_at DESC, id" }.freeze

        include ActorNames

        def self.map(row)
          Domain::Pricing::Fee.new(
            id: row["id"], organization_id: row["organization_id"], code: row["code"], name: row["name"], description: row["description"],
            default_amount: Domain::Money.new(row["default_amount_cents"]), active: row["active"], lock_version: row["lock_version"],
            created_by: row["created_by"], created_at: row["created_at"]&.getutc, updated_at: row["updated_at"]&.getutc,
            deactivated_at: row["deactivated_at"]&.getutc
          )
        end

        def insert(tx, fee)
          tx.execute(<<~SQL, [fee.id, tx.tenant_id!, fee.code, fee.name, fee.description, fee.default_amount.cents, fee.created_by, fee.created_at])
            INSERT INTO additional_fees (id, organization_id, code, name, description, default_amount_cents, created_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
            ON CONFLICT (organization_id, code) DO NOTHING
          SQL
        end

        # Controle otimista: grava somente se a versão lida ainda é a atual.
        def update(tx, fee, expected_lock_version)
          tx.execute(<<~SQL, [tx.tenant_id!, fee.id, fee.name, fee.description, fee.default_amount.cents, fee.active, fee.deactivated_at, fee.updated_at, fee.lock_version, expected_lock_version])
            UPDATE additional_fees SET name = $3, description = $4, default_amount_cents = $5, active = $6, deactivated_at = $7, updated_at = $8,
                                       lock_version = $9
             WHERE organization_id = $1 AND id = $2 AND lock_version = $10
          SQL
        end

        def find(tx, id) = load(tx, "id = $2", id, lock: false)
        def find_by_code(tx, code) = load(tx, "code = $2", code, lock: false)
        def lock(tx, id) = load(tx, "id = $2", id, lock: true)
        def lock_by_code(tx, code) = load(tx, "code = $2", code, lock: true)

        # Busca por trecho do código ou do nome, com filtro de situação. Devolve [[Fee], total].
        def search(tx, status:, search:, sort:, limit:, offset:)
          order = SORTS.fetch(sort) { raise Domain::ValidationError.field("ordenacao", "inválida") }
          params = [tx.tenant_id!]
          conditions = ["organization_id = $1"]
          unless search.to_s.empty?
            params << "%#{escape_like(search.upcase)}%" << "%#{escape_like(search.downcase)}%"
            conditions << "(code LIKE $#{params.size - 1} ESCAPE '\\' OR lower(name) LIKE $#{params.size} ESCAPE '\\')"
          end
          if status
            params << (status == "active")
            conditions << "active = $#{params.size}"
          end
          where = conditions.join(" AND ")
          total = tx.query_value("SELECT count(*) FROM additional_fees WHERE #{where}", params)
          rows = tx.query("SELECT #{COLUMNS} FROM additional_fees WHERE #{where} ORDER BY #{order} " \
                          "LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}", params + [limit, offset])
          [rows.map { |row| self.class.map(row) }, total]
        end

        private

        def load(tx, condition, value, lock:)
          row = tx.query_one("SELECT #{COLUMNS} FROM additional_fees WHERE organization_id = $1 AND #{condition} #{"FOR UPDATE" if lock}",
                             [tx.tenant_id!, value])
          row && self.class.map(row)
        end

        def escape_like(text)
          text.gsub(/[\\%_]/) { |char| "\\#{char}" }
        end
      end
    end
  end
end
