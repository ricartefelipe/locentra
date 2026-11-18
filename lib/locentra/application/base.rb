# frozen_string_literal: true

module Locentra
  module Application
    # Identidade que executa uma operação. Construída pela interface (sessão, credencial de API,
    # CLI ou worker) e revalidada dentro da transação pela UnitOfWork.
    ACTOR_KINDS = %w[user api cli system customer].freeze

    Actor = Data.define(:kind, :user_id, :organization_id, :role, :membership_id, :credential_id, :customer_id,
                        :scopes, :request_id, :ip) do
      def self.user(user_id:, organization_id:, role:, membership_id: nil, request_id: nil, ip: nil)
        new(kind: "user", user_id: user_id, organization_id: organization_id, role: role, membership_id: membership_id,
            credential_id: nil, customer_id: nil, scopes: [], request_id: request_id, ip: ip)
      end

      def self.credential(kind:, credential_id:, organization_id:, scopes:, request_id: nil, ip: nil, user_id: nil)
        raise ArgumentError, "tipo inválido" unless %w[api cli].include?(kind)

        new(kind: kind, user_id: user_id, organization_id: organization_id, role: nil, membership_id: nil,
            credential_id: credential_id, customer_id: nil, scopes: scopes.freeze, request_id: request_id, ip: ip)
      end

      def self.system(organization_id:, request_id: nil)
        new(kind: "system", user_id: nil, organization_id: organization_id, role: nil, membership_id: nil,
            credential_id: nil, customer_id: nil, scopes: [], request_id: request_id, ip: nil)
      end

      def self.customer(user_id:, organization_id:, customer_id:, request_id: nil, ip: nil)
        new(kind: "customer", user_id: user_id, organization_id: organization_id, role: nil, membership_id: nil,
            credential_id: nil, customer_id: customer_id, scopes: [], request_id: request_id, ip: ip)
      end

      def user? = kind == "user"
      def system? = kind == "system"
      def customer? = kind == "customer"
      def credential? = %w[api cli].include?(kind)

      def audit_actor_id = user_id || credential_id
    end

    # Autorização por papel (usuários) ou por escopos (credenciais de integração e CLI).
    # O worker (`system`) executa somente tarefas internas enfileiradas pela própria aplicação.
    module Authorizer
      CUSTOMER_PERMISSIONS = %w[portal.access].freeze

      module_function

      def allowed?(actor, permission)
        case actor.kind
        when "user" then Domain::Identity.permitted?(actor.role, permission)
        when "api", "cli" then actor.scopes.include?(permission)
        when "system" then true
        when "customer" then CUSTOMER_PERMISSIONS.include?(permission)
        else false
        end
      end

      def authorize!(actor, permission)
        raise Domain::AccessDenied, "permissão necessária: #{permission}" unless allowed?(actor, permission)

        actor
      end
    end

    # Coordena transação, contexto de tenant e revalidação do vínculo do ator.
    #
    # O tenant vem do ator autenticado, nunca de parâmetros. Dentro da transação, o vínculo
    # (membro ativo, credencial válida, acesso de portal) é consultado novamente: uma revogação
    # tem efeito na operação seguinte, mesmo com sessão aberta.
    #
    # Conflitos que encerram a operação (disponibilidade, bloqueio vencido, concorrência,
    # idempotência e transição recusada pelo estado atual, que a interface também responde com 409)
    # são contados em `domain_conflicts_total{code}` independentemente da interface (formulário web,
    # API, worker ou CLI). `metrics` é uma porta com `increment(nome, **rótulos)`.
    class UnitOfWork
      INVALID_TRANSITION = "invalid_transition"

      def initialize(transactor:, access:, clock:, metrics: nil)
        @transactor = transactor
        @access = access
        @clock = clock
        @metrics = metrics
      end

      def run(actor, permission = nil, retries: 2)
        raise Domain::AccessDenied, "contexto de organização ausente" if actor.organization_id.nil?

        counting_conflicts do
          @transactor.call(tenant_id: actor.organization_id, user_id: actor.user_id, actor: actor, retries: retries) do |tx|
            current = refresh(tx, actor)
            Authorizer.authorize!(current, permission) if permission
            yield tx, current
          end
        end
      end

      # Transação sem ator de tenant (cadastro inicial, autenticação, aceite de convite). `request_id`
      # é o da requisição de origem, quando houver, para correlacionar as tarefas enfileiradas.
      def anonymous(tenant_id: nil, user_id: nil, request_id: nil, &)
        counting_conflicts { @transactor.call(tenant_id: tenant_id, user_id: user_id, request_id: request_id, &) }
      end

      private

      def counting_conflicts
        yield
      rescue Domain::Conflict => e
        @metrics&.increment("domain_conflicts_total", code: e.code)
        raise
      rescue Domain::InvalidTransition
        @metrics&.increment("domain_conflicts_total", code: INVALID_TRANSITION)
        raise
      end

      def refresh(tx, actor)
        case actor.kind
        when "user"
          membership = @access.active_membership(tx, actor.organization_id, actor.user_id)
          raise Domain::AccessDenied, "acesso à organização revogado" unless membership

          actor.with(role: membership.fetch("role"), membership_id: membership.fetch("id"))
        when "api", "cli"
          credential = @access.active_credential(tx, actor.credential_id, @clock.now)
          unless credential && credential.fetch("organization_id") == actor.organization_id
            raise Domain::AccessDenied,
                  "credencial inválida ou revogada"
          end

          actor.with(scopes: credential.fetch("scopes"))
        when "customer"
          portal = @access.active_portal_access(tx, actor.organization_id, actor.user_id)
          raise Domain::AccessDenied, "acesso ao portal revogado" unless portal && portal.fetch("customer_id") == actor.customer_id

          actor
        else
          actor
        end
      end
    end

    # Trilha de auditoria gravada na mesma transação da operação.
    class AuditTrail
      def initialize(repository:, clock:, ids:)
        @repository = repository
        @clock = clock
        @ids = ids
      end

      def record(tx, actor, action, resource_type, resource_id, details = {})
        @repository.insert(tx,
                           "id" => @ids.uuid, "organization_id" => tx.tenant_id!, "actor_type" => actor_type(actor),
                           "actor_id" => actor&.audit_actor_id, "action" => action, "resource_type" => resource_type,
                           "resource_id" => resource_id, "request_id" => actor&.request_id, "ip" => actor&.ip,
                           "details" => details, "occurred_at" => @clock.now)
      end

      private

      def actor_type(actor)
        return "system" if actor.nil?

        actor.kind
      end
    end

    # Paginação com limites explícitos.
    MAX_PAGE_LIMIT = 100

    Page = Data.define(:items, :limit, :offset, :total) do
      def self.params(limit: nil, offset: nil, default: 25)
        lim = limit.to_s.empty? ? default : Integer(limit.to_s, 10)
        off = offset.to_s.empty? ? 0 : Integer(offset.to_s, 10)
        raise Domain::ValidationError.field("limite", "entre 1 e #{MAX_PAGE_LIMIT}") unless lim.between?(1, MAX_PAGE_LIMIT)
        raise Domain::ValidationError.field("deslocamento", "não pode ser negativo") if off.negative?

        [lim, off]
      rescue ArgumentError
        raise Domain::ValidationError.field("paginacao", "valores inteiros")
      end

      def next_offset = offset + limit < total ? offset + limit : nil
      def previous_offset = offset.positive? ? [offset - limit, 0].max : nil
    end
  end
end
