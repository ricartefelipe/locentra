# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class CustomerRepository
        C = Domain::Customers
        COLUMNS = "id, organization_id, kind, name, trade_name, document, email, phone, notes, status"
        SORTS = { "name" => "lower(name) ASC, id", "-created_at" => "created_at DESC, id", "created_at" => "created_at ASC, id" }.freeze

        def insert(tx, customer, now)
          tx.execute(<<~SQL, [*customer.to_h.values_at(:id, :organization_id, :kind, :name, :trade_name, :document, :email, :phone, :notes, :status), now])
            INSERT INTO customers (id, organization_id, kind, name, trade_name, document, email, phone, notes, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
          SQL
        end

        def update(tx, customer, now)
          tx.execute(<<~SQL, [tx.tenant_id!, customer.id, customer.name, customer.trade_name, customer.email, customer.phone, customer.notes, customer.status, now])
            UPDATE customers SET name = $3, trade_name = $4, email = $5, phone = $6, notes = $7, status = $8, updated_at = $9
             WHERE organization_id = $1 AND id = $2
          SQL
        end

        def find(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM customers WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
          row && map(row)
        end

        def lock(tx, id)
          row = tx.query_one("SELECT #{COLUMNS} FROM customers WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
          row && map(row)
        end

        def document_taken?(tx, document)
          !tx.query_one("SELECT 1 FROM customers WHERE organization_id = $1 AND document = $2", [tx.tenant_id!, document]).nil?
        end

        # Busca com filtros e ordenação por allowlist; nenhum fragmento recebido entra no SQL.
        def search(tx, search:, status:, sort:, limit:, offset:)
          order = SORTS.fetch(sort) { raise Domain::ValidationError.field("ordenacao", "inválida") }
          conditions = ["organization_id = $1"]
          params = [tx.tenant_id!]
          unless search.empty?
            params << "%#{escape_like(search.downcase)}%"
            params << Domain::Customers::Document.digits(search).then { |d| d.empty? ? "-" : "#{d}%" }
            conditions << "(lower(name) LIKE $#{params.size - 1} ESCAPE '\\' OR document LIKE $#{params.size})"
          end
          if status
            raise Domain::ValidationError.field("situacao", "inválida") unless C::STATUSES.key?(status)

            params << status
            conditions << "status = $#{params.size}"
          end
          where = conditions.join(" AND ")
          total = tx.query_value("SELECT count(*) FROM customers WHERE #{where}", params)
          rows = tx.query("SELECT #{COLUMNS} FROM customers WHERE #{where} ORDER BY #{order} LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}",
                          params + [limit, offset])
          [rows.map { |row| map(row) }, total]
        end

        def insert_contact(tx, contact, now)
          tx.execute(<<~SQL, [*contact.to_h.values_at(:id, :organization_id, :customer_id, :name, :email, :phone, :role, :document, :authorized_pickup), now])
            INSERT INTO customer_contacts (id, organization_id, customer_id, name, email, phone, role, document, authorized_pickup, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          SQL
        end

        def contacts(tx, customer_id)
          tx.query(<<~SQL, [tx.tenant_id!, customer_id]).map { |row| C::Contact.new(**row.transform_keys(&:to_sym)) }
            SELECT id, organization_id, customer_id, name, email, phone, role, document, authorized_pickup
              FROM customer_contacts WHERE organization_id = $1 AND customer_id = $2 ORDER BY name
          SQL
        end

        def authorized_pickups(tx, customer_id)
          contacts(tx, customer_id).select(&:authorized_pickup)
        end

        def insert_address(tx, address, now)
          tx.execute(<<~SQL, [*address.to_h.values_at(:id, :organization_id, :customer_id, :label, :street, :number, :complement, :district, :city, :state, :postal_code), now])
            INSERT INTO customer_addresses (id, organization_id, customer_id, label, street, number, complement, district, city, state, postal_code, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
        end

        def addresses(tx, customer_id)
          tx.query(<<~SQL, [tx.tenant_id!, customer_id]).map { |row| C::Address.new(**row.transform_keys(&:to_sym)) }
            SELECT id, organization_id, customer_id, label, street, number, complement, district, city, state, postal_code
              FROM customer_addresses WHERE organization_id = $1 AND customer_id = $2 ORDER BY label
          SQL
        end

        private

        def map(row)
          C::Customer.new(**row.transform_keys(&:to_sym))
        end

        def escape_like(text)
          text.gsub(/[\\%_]/) { |char| "\\#{char}" }
        end
      end
    end
  end
end
