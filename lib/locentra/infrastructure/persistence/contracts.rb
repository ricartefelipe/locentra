# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Contratos, documentos e aditivos. Termos do contrato, documentos e aditivos são protegidos no
      # banco (trigger e privilégios revogados); somente situação, versão do documento atual e campos
      # de aceite (uma vez) são atualizados.
      class ContractRepository
        C = Domain::Contracts
        COLUMNS = "id, organization_id, code, reservation_id, customer_id, quote_id, status, terms_snapshot, current_document_version, " \
                  "issued_at, activated_at, closed_at, cancelled_at, cancellation_reason, cancellation_fee_cents, lock_version"
        DOCUMENT_COLUMNS = "d.id, d.contract_id, d.version, d.reason, d.attachment_id, d.sha256, d.data_snapshot, d.generated_at, d.accepted_at, " \
                           "d.accepted_by_name, d.accepted_by_document, d.accepted_ip, d.user_agent, d.accepted_via, d.acceptance_statement"
        OPEN = "status IN ('issued', 'active')"

        def insert(tx, contract, issued_by, now)
          tx.execute(<<~SQL, [contract.id, contract.organization_id, contract.code, contract.reservation_id, contract.customer_id, contract.quote_id, contract.status, contract.terms, contract.current_document_version, issued_by, contract.issued_at, now])
            INSERT INTO contracts (id, organization_id, code, reservation_id, customer_id, quote_id, status, terms_snapshot, current_document_version,
                                   issued_by, issued_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
        end

        def assign_code(tx, id, code)
          tx.execute("UPDATE contracts SET code = $3 WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id, code])
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM contracts WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM contracts WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && self.class.map(row)
        end

        def find_by_reservation(tx, reservation_id)
          row = tx.query_one("SELECT #{COLUMNS} FROM contracts WHERE organization_id = $1 AND reservation_id = $2",
                             [tx.tenant_id!, reservation_id])
          row && self.class.map(row)
        end

        def open_for_reservation(tx, reservation_id)
          row = tx.query_one("SELECT #{COLUMNS} FROM contracts WHERE organization_id = $1 AND reservation_id = $2 AND #{OPEN}",
                             [tx.tenant_id!, reservation_id])
          row && self.class.map(row)
        end

        def update(tx, contract, now)
          count = tx.execute(<<~SQL, [tx.tenant_id!, contract.id, contract.status, contract.current_document_version, contract.activated_at, contract.closed_at, contract.cancelled_at, contract.cancellation_reason, contract.cancellation_fee_cents, contract.lock_version, now])
            UPDATE contracts
               SET status = $3, current_document_version = $4, activated_at = $5, closed_at = $6, cancelled_at = $7, cancellation_reason = $8,
                   cancellation_fee_cents = $9, lock_version = $10, updated_at = $11
             WHERE organization_id = $1 AND id = $2 AND lock_version = $10 - 1
          SQL
          raise Domain::Conflict.new("contrato alterado por outra operação", code: "stale_contract") unless count == 1
        end

        # Documento legal da organização (CNPJ), exibido no contrato quando cadastrado.
        def organization_document(tx)
          tx.query_value("SELECT legal_document FROM organizations WHERE id = $1", [tx.tenant_id!])
        end

        def insert_document(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("contract_id", "version", "reason", "attachment_id", "sha256", "data_snapshot", "generated_by", "generated_at")])
            INSERT INTO contract_documents (id, organization_id, contract_id, version, reason, attachment_id, sha256, data_snapshot, generated_by,
                                            generated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end

        def documents(tx, contract_id)
          tx.query(<<~SQL, [tx.tenant_id!, contract_id])
            SELECT #{DOCUMENT_COLUMNS}, a.filename, a.byte_size, a.retain_until
              FROM contract_documents d JOIN attachments a ON a.organization_id = d.organization_id AND a.id = d.attachment_id
             WHERE d.organization_id = $1 AND d.contract_id = $2 ORDER BY d.version DESC
          SQL
        end

        # O anexo é documento gerado de um contrato do cliente (escopo de downloads do portal).
        def customer_document?(tx, attachment_id, customer_id)
          !tx.query_one(<<~SQL, [tx.tenant_id!, attachment_id, customer_id]).nil?
            SELECT 1 FROM contract_documents d
              JOIN contracts k ON k.organization_id = d.organization_id AND k.id = d.contract_id
             WHERE d.organization_id = $1 AND d.attachment_id = $2 AND k.customer_id = $3
          SQL
        end

        def lock_document(tx, contract_id, version)
          tx.query_one(<<~SQL, [tx.tenant_id!, contract_id, version])
            SELECT #{DOCUMENT_COLUMNS} FROM contract_documents d
             WHERE d.organization_id = $1 AND d.contract_id = $2 AND d.version = $3 FOR UPDATE
          SQL
        end

        # O aceite é gravado uma única vez: a condição e o trigger impedem sobrescrita.
        def record_acceptance(tx, document_id, acceptance)
          count = tx.execute(<<~SQL, [tx.tenant_id!, document_id, acceptance.accepted_at, acceptance.name, acceptance.document, acceptance.ip, acceptance.user_agent, acceptance.via, acceptance.user_id, acceptance.statement])
            UPDATE contract_documents
               SET accepted_at = $3, accepted_by_name = $4, accepted_by_document = $5, accepted_ip = $6, user_agent = $7, accepted_via = $8,
                   accepted_by_user_id = $9, acceptance_statement = $10
             WHERE organization_id = $1 AND id = $2 AND accepted_at IS NULL
          SQL
          raise Domain::Conflict.new("aceite já registrado para este documento", code: "already_accepted") unless count == 1
        end

        def insert_amendment(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("contract_id", "number", "kind", "description", "changes", "amount_delta_cents", "document_version", "created_by", "created_at")])
            INSERT INTO contract_amendments (id, organization_id, contract_id, number, kind, description, changes, amount_delta_cents,
                                             document_version, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          SQL
        end

        def amendments(tx, contract_id)
          tx.query(<<~SQL, [tx.tenant_id!, contract_id])
            SELECT id, number, kind, description, changes, amount_delta_cents, document_version, created_at
              FROM contract_amendments WHERE organization_id = $1 AND contract_id = $2 ORDER BY number
          SQL
        end

        def search(tx, status:, customer_id:, search:, limit:, offset:)
          params = [tx.tenant_id!]
          conditions = ["k.organization_id = $1"]
          { "k.status = $%d" => status, "k.customer_id = $%d" => customer_id }.each do |fragment, value|
            next if value.nil?

            params << value
            conditions << format(fragment, params.size)
          end
          unless search.to_s.empty?
            params << "%#{search.upcase.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
            conditions << "(k.code LIKE $#{params.size} ESCAPE '\\' OR r.code LIKE $#{params.size} ESCAPE '\\' " \
                          "OR upper(c.name) LIKE $#{params.size} ESCAPE '\\')"
          end
          where = conditions.join(" AND ")
          from_sql = "FROM contracts k JOIN customers c ON c.organization_id = k.organization_id AND c.id = k.customer_id " \
                     "JOIN reservations r ON r.organization_id = k.organization_id AND r.id = k.reservation_id"
          total = tx.query_value("SELECT count(*) #{from_sql} WHERE #{where}", params)
          rows = tx.query(<<~SQL, params + [limit, offset])
            SELECT #{COLUMNS.split(", ").map { |c| "k.#{c}" }.join(", ")}, c.name AS customer_name, r.code AS reservation_code
              #{from_sql} WHERE #{where} ORDER BY k.issued_at DESC, k.id LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}
          SQL
          [rows.map { |row| { contract: self.class.map(row), customer_name: row["customer_name"], reservation_code: row["reservation_code"] } },
           total]
        end

        def self.map(row)
          C::Contract.new(id: row["id"], organization_id: row["organization_id"], code: row["code"], reservation_id: row["reservation_id"],
                          customer_id: row["customer_id"], quote_id: row["quote_id"], status: row["status"], terms: row["terms_snapshot"],
                          current_document_version: row["current_document_version"], issued_at: row["issued_at"]&.utc,
                          activated_at: row["activated_at"]&.utc, closed_at: row["closed_at"]&.utc, cancelled_at: row["cancelled_at"]&.utc,
                          cancellation_reason: row["cancellation_reason"], cancellation_fee_cents: row["cancellation_fee_cents"],
                          lock_version: row["lock_version"])
        end
      end
    end
  end
end
