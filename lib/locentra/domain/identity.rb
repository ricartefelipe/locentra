# frozen_string_literal: true

module Locentra
  module Domain
    # Papéis, permissões e regras de credenciais.
    module Identity
      ROLES = {
        "owner" => "Proprietário",
        "admin" => "Administrador",
        "manager" => "Gerente",
        "attendant" => "Atendente",
        "stock_operator" => "Operador de estoque",
        "finance" => "Financeiro",
        "auditor" => "Auditor"
      }.freeze

      STAFF = ROLES.keys.freeze
      ALL = STAFF
      OPERATIONS = %w[owner admin manager attendant stock_operator].freeze

      # Matriz de permissões por papel. Fonte única para a interface, a API, a CLI e o worker.
      PERMISSIONS = {
        "organization.manage" => %w[owner admin],
        "subscription.manage" => %w[owner],
        "members.read" => %w[owner admin manager auditor],
        "members.manage" => %w[owner admin],
        "integrations.manage" => %w[owner admin],
        "customers.read" => ALL,
        "customers.write" => %w[owner admin manager attendant],
        "catalog.read" => ALL,
        "catalog.write" => %w[owner admin manager stock_operator],
        "assets.write" => %w[owner admin manager stock_operator],
        "availability.read" => ALL,
        "reservations.read" => ALL,
        "reservations.write" => %w[owner admin manager attendant],
        "reservations.cancel" => %w[owner admin manager],
        "quotes.read" => ALL,
        "quotes.write" => %w[owner admin manager attendant],
        "contracts.read" => ALL,
        "contracts.write" => %w[owner admin manager attendant],
        "fulfillment.write" => %w[owner admin manager attendant stock_operator],
        "inspections.write" => %w[owner admin manager stock_operator],
        "maintenance.write" => %w[owner admin manager stock_operator],
        "damage_charges.approve" => %w[owner admin manager],
        "finance.read" => %w[owner admin manager finance auditor],
        "finance.write" => %w[owner admin finance],
        "finance.refund" => %w[owner admin finance],
        "deposits.manage" => %w[owner admin manager finance],
        "audit.read" => %w[owner admin auditor],
        "jobs.manage" => %w[owner admin],
        "reports.export" => %w[owner admin manager finance auditor]
      }.freeze

      # Desconto manual máximo por papel, em pontos-base.
      DISCOUNT_LIMITS_BPS = {
        "owner" => 10_000, "admin" => 10_000, "manager" => 2_000, "attendant" => 500
      }.freeze

      module_function

      def role_label(role) = ROLES.fetch(role, role)

      def valid_role?(role) = ROLES.key?(role)

      def permitted?(role, permission)
        PERMISSIONS.fetch(permission) { raise ArgumentError, "permissão desconhecida: #{permission}" }.include?(role)
      end

      def permissions_for(role)
        PERMISSIONS.select { |_permission, roles| roles.include?(role) }.keys
      end

      def discount_limit_bps(role) = DISCOUNT_LIMITS_BPS.fetch(role, 0)

      # Papéis que um membro pode atribuir. O papel de proprietário não é concedido por convite.
      def assignable_roles(by_role)
        case by_role
        when "owner" then STAFF - ["owner"]
        when "admin" then STAFF - %w[owner admin]
        else []
        end
      end

      def validate_permissions!(list)
        unknown = list - PERMISSIONS.keys
        raise ValidationError.field("escopos", "escopos desconhecidos: #{unknown.join(", ")}") unless unknown.empty?

        list
      end

      # Política de senha. bcrypt considera apenas os primeiros 72 bytes; senhas maiores são
      # rejeitadas em vez de truncadas silenciosamente.
      module PasswordPolicy
        MIN_LENGTH = 12
        MAX_BYTES = 72

        module_function

        def validate!(password)
          text = password.to_s
          errors = []
          errors << "deve ter ao menos #{MIN_LENGTH} caracteres" if text.length < MIN_LENGTH
          errors << "deve ter no máximo #{MAX_BYTES} bytes" if text.bytesize > MAX_BYTES
          errors << "não pode conter apenas espaços" if text.strip.empty?
          raise ValidationError.new({ "senha" => errors }) unless errors.empty?

          text
        end
      end

      module Email
        PATTERN = /\A[^@\s]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/

        module_function

        def normalize(value, field = "email")
          email = value.to_s.strip.downcase
          raise ValidationError.field(field, "e-mail inválido") unless email.length <= 254 && email.match?(PATTERN)

          email
        end
      end
    end
  end
end
