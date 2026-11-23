# frozen_string_literal: true

module Locentra
  module Application
    # Identidade que executa uma operação. Construída pela interface (sessão, credencial de API,
    # CLI ou worker) e revalidada dentro da transação pela UnitOfWork.
    ACTOR_KINDS = %w[user api cli system customer].freeze

    # `email_status` (Domain::Identity::EmailConfirmation::STATUSES) só existe para usuários da equipe e é
    # preenchido pela UnitOfWork na revalidação, com o relógio da aplicação; antes disso vale nil.
    Actor = Data.define(:kind, :user_id, :organization_id, :role, :membership_id, :credential_id, :customer_id,
                        :scopes, :request_id, :ip, :email_status) do
      def self.user(user_id:, organization_id:, role:, membership_id: nil, request_id: nil, ip: nil, email_status: nil)
        new(kind: "user", user_id: user_id, organization_id: organization_id, role: role, membership_id: membership_id,
            credential_id: nil, customer_id: nil, scopes: [], request_id: request_id, ip: ip, email_status: email_status)
      end

      def self.credential(kind:, credential_id:, organization_id:, scopes:, request_id: nil, ip: nil, user_id: nil)
        raise ArgumentError, "tipo inválido" unless %w[api cli].include?(kind)

        new(kind: kind, user_id: user_id, organization_id: organization_id, role: nil, membership_id: nil,
            credential_id: credential_id, customer_id: nil, scopes: scopes.freeze, request_id: request_id, ip: ip, email_status: nil)
      end

      def self.system(organization_id:, request_id: nil)
        new(kind: "system", user_id: nil, organization_id: organization_id, role: nil, membership_id: nil,
            credential_id: nil, customer_id: nil, scopes: [], request_id: request_id, ip: nil, email_status: nil)
      end

      def self.customer(user_id:, organization_id:, customer_id:, request_id: nil, ip: nil)
        new(kind: "customer", user_id: user_id, organization_id: organization_id, role: nil, membership_id: nil,
            credential_id: nil, customer_id: customer_id, scopes: [], request_id: request_id, ip: ip, email_status: nil)
      end

      def user? = kind == "user"
      def customer? = kind == "customer"
      def credential? = %w[api cli].include?(kind)

      def audit_actor_id = user_id || credential_id
    end

    # Autorização por papel (usuários) ou por escopos (credenciais de integração e CLI).
    # O worker (`system`) executa somente tarefas internas enfileiradas pela própria aplicação.
    #
    # Confirmação de e-mail (ADR-031), somente para usuários da equipe: `authorize!` recusa as permissões que
    # alteram dados quando a conta está somente leitura (consultas que usam uma permissão de alteração passam
    # `read: true`), e `confirmed_email!` recusa as ações que agem para fora em nome da organização enquanto o
    # e-mail não estiver confirmado. Credenciais não passam por essas regras: só são criadas por usuário
    # confirmado, e a confirmação não é desfeita. `allowed?` continua sendo somente a matriz de papéis.
    module Authorizer
      CUSTOMER_PERMISSIONS = %w[portal.access].freeze
      EC = Domain::Identity::EmailConfirmation

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

      def authorize!(actor, permission, read: false)
        raise Domain::AccessDenied, "permissão necessária: #{permission}" unless allowed?(actor, permission)

        writable!(actor) if !read && Domain::Identity.mutation?(permission)
        actor
      end

      # Conta somente leitura recusa a alteração.
      def writable!(actor)
        EC.writable!(actor.email_status) if actor.user?
        actor
      end

      # Ação que age para fora em nome da organização (Domain::Identity::EmailConfirmation::OUTBOUND_ACTIONS).
      def confirmed_email!(actor, action)
        EC.outbound!(actor.email_status, action) if actor.user?
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
    # API, worker ou CLI). A recusa por e-mail não confirmado (403) entra na mesma métrica, com o código
    # `email_unconfirmed` e sem rótulos de usuário. `metrics` é uma porta com `increment(nome, **rótulos)`.
    #
    # `read: true` declara consulta que usa uma permissão de alteração (por exemplo, a lista de credenciais
    # com `integrations.manage`): a conta somente leitura continua podendo consultá-la.
    class UnitOfWork
      INVALID_TRANSITION = "invalid_transition"

      def initialize(transactor:, access:, clock:, metrics: nil)
        @transactor = transactor
        @access = access
        @clock = clock
        @metrics = metrics
      end

      def run(actor, permission = nil, retries: 2, read: false)
        raise Domain::AccessDenied, "contexto de organização ausente" if actor.organization_id.nil?

        counting_conflicts do
          @transactor.call(tenant_id: actor.organization_id, user_id: actor.user_id, actor: actor, retries: retries) do |tx|
            current = refresh(tx, actor)
            Authorizer.authorize!(current, permission, read: read) if permission
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
      rescue Domain::Conflict, Domain::EmailUnconfirmed => e
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

          actor.with(role: membership.fetch("role"), membership_id: membership.fetch("id"), email_status: email_status(membership))
        when "api", "cli"
          # O tipo também é conferido: um ator "cli" só é aceito com credencial do tipo cli.
          credential = @access.active_credential(tx, actor.credential_id, @clock.now)
          unless credential && credential.fetch("organization_id") == actor.organization_id && credential.fetch("kind") == actor.kind
            raise Domain::AccessDenied,
                  "credencial inválida ou revogada"
          end

          actor.with(scopes: Integrations.effective_scopes(credential))
        when "customer"
          portal = @access.active_portal_access(tx, actor.organization_id, actor.user_id)
          raise Domain::AccessDenied, "acesso ao portal revogado" unless portal && portal.fetch("customer_id") == actor.customer_id

          actor
        else
          actor
        end
      end

      # Situação da confirmação de e-mail do usuário do vínculo, no instante da operação.
      def email_status(membership)
        Domain::Identity::EmailConfirmation.status(confirmed_at: membership.fetch("email_confirmed_at"),
                                                   created_at: membership.fetch("user_created_at"), now: @clock.now)
      end
    end

    # Execução com transação própria ou composta: com `tx`, o chamador já abriu a transação e revalidou o
    # ator; a permissão é conferida de novo sobre o ator recebido. Sem `tx`, a unidade de trabalho abre a
    # transação, revalida o ator e confere a permissão (caminho da interface web e da CLI).
    module Composition
      module_function

      def run(uow, actor, permission, tx, &)
        return uow.run(actor, permission, &) unless tx

        Authorizer.authorize!(actor, permission) if permission
        yield tx, actor
      end

      # Permissão da leitura do detalhe. Quando a própria mutação devolve o detalhe, lido na transação dela,
      # confere-se a permissão da mutação (`mutation`), já exigida nessa transação: quem tem somente o escopo
      # de escrita recebe o resultado sem precisar também do de leitura. Fora da transação composta vale
      # sempre a permissão de leitura.
      def detail_permission(tx, read, mutation) = tx && mutation ? mutation : read
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

    # Paginação com limites explícitos. O deslocamento máximo mantém o valor dentro do tipo do
    # PostgreSQL (OFFSET é bigint) e evita varreduras profundas sem sentido.
    MAX_PAGE_LIMIT = 100
    MAX_PAGE_OFFSET = 1_000_000

    Page = Data.define(:items, :limit, :offset, :total) do
      def self.params(limit: nil, offset: nil, default: 25)
        lim = limit.to_s.empty? ? default : Integer(limit.to_s, 10)
        off = offset.to_s.empty? ? 0 : Integer(offset.to_s, 10)
        raise Domain::ValidationError.field("limite", "entre 1 e #{MAX_PAGE_LIMIT}") unless lim.between?(1, MAX_PAGE_LIMIT)
        raise Domain::ValidationError.field("deslocamento", "não pode ser negativo") if off.negative?
        raise Domain::ValidationError.field("deslocamento", "no máximo #{MAX_PAGE_OFFSET}") if off > MAX_PAGE_OFFSET

        [lim, off]
      rescue ArgumentError
        raise Domain::ValidationError.field("paginacao", "valores inteiros")
      end

      def next_offset = offset + limit < total ? offset + limit : nil
      def previous_offset = offset.positive? ? [offset - limit, 0].max : nil
    end
  end
end
