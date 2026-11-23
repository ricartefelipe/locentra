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
        "organization.read" => ALL,
        "organization.manage" => %w[owner admin],
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
        "coupons.read" => %w[owner admin manager attendant finance auditor],
        "coupons.write" => %w[owner admin manager],
        "price_agreements.read" => %w[owner admin manager attendant finance auditor],
        "price_agreements.write" => %w[owner admin manager],
        "fees.read" => ALL,
        "fees.write" => %w[owner admin manager],
        "fees.override" => %w[owner admin manager],
        "fulfillment.write" => %w[owner admin manager attendant stock_operator],
        "inspections.write" => %w[owner admin manager stock_operator],
        "maintenance.write" => %w[owner admin manager stock_operator],
        "damage_charges.approve" => %w[owner admin manager],
        "finance.read" => %w[owner admin manager finance auditor],
        "finance.write" => %w[owner admin finance],
        "finance.refund" => %w[owner admin finance],
        "deposits.manage" => %w[owner admin manager finance],
        "audit.read" => %w[owner admin auditor],
        "jobs.manage" => %w[owner admin]
      }.freeze

      # Permissões de consulta; as demais da matriz alteram dados. A conta somente leitura (e-mail não
      # confirmado depois do prazo) mantém apenas estas.
      READ_PERMISSIONS = PERMISSIONS.keys.select { |permission| permission.end_with?(".read") }.freeze

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

      # Permissão da matriz que altera dados. Permissões fora da matriz (como `portal.access`, do ator
      # cliente) não pertencem a usuários da equipe e ficam de fora.
      def mutation?(permission)
        PERMISSIONS.key?(permission) && !READ_PERMISSIONS.include?(permission)
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

      # Confirmação de e-mail (RF-05, ADR-031). Sem a confirmação, a conta entra e opera normalmente dentro
      # da organização, mas não executa as ações que fazem a plataforma agir para fora em nome dela
      # (OUTBOUND_ACTIONS). A partir de GRACE_PERIOD_SECONDS contados da criação do usuário, a conta não
      # confirmada fica somente leitura. Os instantes vêm sempre do relógio injetado.
      module EmailConfirmation
        GRACE_PERIOD_DAYS = 7
        DAY_SECONDS = 86_400
        GRACE_PERIOD_SECONDS = GRACE_PERIOD_DAYS * DAY_SECONDS

        CONFIRMED = "confirmed"
        PENDING = "pending"
        READ_ONLY = "read_only"
        STATUSES = [CONFIRMED, PENDING, READ_ONLY].freeze

        # Ação bloqueada até a confirmação => complemento de "Confirme seu e-mail para ...".
        OUTBOUND_ACTIONS = {
          "members.invite" => "convidar membros da equipe",
          "credentials.create" => "criar credenciais de API e CLI",
          "webhooks.create" => "cadastrar endpoints de webhook",
          "webhooks.resume" => "reativar endpoints de webhook",
          "webhooks.redeliver" => "reenviar entregas de webhook",
          "payments.configure" => "configurar o provedor de pagamentos",
          "payments.request" => "solicitar cobranças pelo provedor de pagamentos",
          "quotes.send" => "enviar orçamentos aos clientes",
          "contracts.issue" => "emitir contratos, que são enviados aos clientes por e-mail",
          "portal.invite" => "convidar clientes para o portal"
        }.freeze

        # Situação da conta num instante. `deadline` e `remaining_seconds` (inteiro, arredondado para cima)
        # existem somente para a conta não confirmada.
        Standing = Data.define(:status, :deadline, :remaining_seconds) do
          def confirmed? = status == CONFIRMED
          def read_only? = status == READ_ONLY

          # Dias restantes arredondados para cima: de 1 segundo a 1 dia, conta como 1 dia.
          def remaining_days = (remaining_seconds.to_i + DAY_SECONDS - 1) / DAY_SECONDS
        end

        module_function

        def deadline(created_at)
          raise ArgumentError, "instante de criação do usuário ausente" if created_at.nil?

          created_at + GRACE_PERIOD_SECONDS
        end

        # O prazo termina exatamente em `created_at + 7 dias`: a partir desse instante, inclusive, a conta
        # não confirmada é somente leitura.
        def standing(confirmed_at:, created_at:, now:)
          return Standing.new(status: CONFIRMED, deadline: nil, remaining_seconds: nil) if confirmed_at

          limit = deadline(created_at)
          return Standing.new(status: READ_ONLY, deadline: limit, remaining_seconds: 0) if now >= limit

          Standing.new(status: PENDING, deadline: limit, remaining_seconds: (limit.to_r - now.to_r).ceil)
        end

        def status(confirmed_at:, created_at:, now:) = standing(confirmed_at: confirmed_at, created_at: created_at, now: now).status

        # Recusa a ação para fora quando a situação não é "confirmada" (situação desconhecida também recusa).
        def outbound!(status, action)
          label = OUTBOUND_ACTIONS.fetch(action) { raise ArgumentError, "ação desconhecida: #{action}" }
          raise EmailUnconfirmed.outbound(label) unless status == CONFIRMED

          status
        end

        # Recusa a mutação quando a conta está somente leitura.
        def writable!(status)
          raise EmailUnconfirmed.read_only if status == READ_ONLY

          status
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
