# frozen_string_literal: true

module Locentra
  module Domain
    module Customers
      # Documentos brasileiros com validação de dígitos verificadores.
      module Document
        module_function

        def digits(value) = value.to_s.gsub(/\D/, "")

        def valid_cpf?(value)
          numbers = digits(value)
          return false unless numbers.length == 11 && numbers.chars.uniq.size > 1

          base = numbers[0, 9].chars.map(&:to_i)
          first = check_digit(base, 10)
          second = check_digit(base + [first], 11)
          numbers[9, 2] == "#{first}#{second}"
        end

        def valid_cnpj?(value)
          numbers = digits(value)
          return false unless numbers.length == 14 && numbers.chars.uniq.size > 1

          base = numbers[0, 12].chars.map(&:to_i)
          first = cnpj_digit(base, [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
          second = cnpj_digit(base + [first], [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
          numbers[12, 2] == "#{first}#{second}"
        end

        def format(value)
          numbers = digits(value)
          case numbers.length
          when 11 then "#{numbers[0, 3]}.#{numbers[3, 3]}.#{numbers[6, 3]}-#{numbers[9, 2]}"
          when 14 then "#{numbers[0, 2]}.#{numbers[2, 3]}.#{numbers[5, 3]}/#{numbers[8, 4]}-#{numbers[12, 2]}"
          else numbers
          end
        end

        def check_digit(numbers, start_weight)
          sum = numbers.each_with_index.sum { |n, i| n * (start_weight - i) }
          rest = (sum * 10) % 11
          rest == 10 ? 0 : rest
        end

        def cnpj_digit(numbers, weights)
          sum = numbers.zip(weights).sum { |n, w| n * w }
          rest = sum % 11
          rest < 2 ? 0 : 11 - rest
        end
      end

      KINDS = { "individual" => "Pessoa física", "company" => "Pessoa jurídica" }.freeze
      STATUSES = { "active" => "Ativo", "blocked" => "Bloqueado", "inactive" => "Inativo" }.freeze

      Customer = Data.define(:id, :organization_id, :kind, :name, :trade_name, :document, :email, :phone, :notes, :status) do
        def self.build(id:, organization_id:, kind:, name:, document:, trade_name: nil, email: nil, phone: nil, notes: nil)
          raise ValidationError.field("tipo", "tipo de cliente inválido") unless KINDS.key?(kind)

          numbers = Document.digits(document)
          valid = kind == "individual" ? Document.valid_cpf?(numbers) : Document.valid_cnpj?(numbers)
          raise ValidationError.field("documento", kind == "individual" ? "CPF inválido" : "CNPJ inválido") unless valid

          new(id: id, organization_id: organization_id, kind: kind,
              name: Organizations::Text.required(name, "nome", min: 2, max: 160),
              trade_name: Organizations::Text.optional(trade_name, max: 160),
              document: numbers,
              email: email.to_s.strip.empty? ? nil : Identity::Email.normalize(email),
              phone: Organizations::Text.optional(phone, max: 30),
              notes: Organizations::Text.optional(notes, max: 2000),
              status: "active")
        end

        def blocked? = status == "blocked"

        def formatted_document = Document.format(document)

        def kind_label = KINDS.fetch(kind)
      end

      Contact = Data.define(:id, :organization_id, :customer_id, :name, :email, :phone, :role, :document, :authorized_pickup) do
        def self.build(id:, organization_id:, customer_id:, name:, email: nil, phone: nil, role: nil, document: nil,
                       authorized_pickup: false)
          doc = Document.digits(document)
          raise ValidationError.field("documento", "CPF inválido") if authorized_pickup && !Document.valid_cpf?(doc)

          new(id: id, organization_id: organization_id, customer_id: customer_id,
              name: Organizations::Text.required(name, "nome", min: 2, max: 160),
              email: email.to_s.strip.empty? ? nil : Identity::Email.normalize(email),
              phone: Organizations::Text.optional(phone, max: 30),
              role: Organizations::Text.optional(role, max: 80),
              document: doc.empty? ? nil : doc,
              authorized_pickup: authorized_pickup ? true : false)
        end
      end

      Address = Data.define(:id, :organization_id, :customer_id, :label, :street, :number, :complement, :district, :city, :state,
                            :postal_code) do
        def self.build(id:, organization_id:, customer_id:, street:, city:, state:, label: "principal", number: nil, complement: nil,
                       district: nil, postal_code: nil)
          uf = state.to_s.strip.upcase
          raise ValidationError.field("uf", "UF inválida") unless uf.match?(/\A[A-Z]{2}\z/)

          cep = Document.digits(postal_code)
          raise ValidationError.field("cep", "CEP deve ter 8 dígitos") unless cep.empty? || cep.length == 8

          new(id: id, organization_id: organization_id, customer_id: customer_id,
              label: Organizations::Text.required(label, "rotulo", max: 40),
              street: Organizations::Text.required(street, "logradouro", max: 200),
              number: Organizations::Text.optional(number, max: 20),
              complement: Organizations::Text.optional(complement, max: 100),
              district: Organizations::Text.optional(district, max: 100),
              city: Organizations::Text.required(city, "cidade", max: 100),
              state: uf, postal_code: cep.empty? ? nil : cep)
        end
      end
    end
  end
end
