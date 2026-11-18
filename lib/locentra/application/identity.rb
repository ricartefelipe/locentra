# frozen_string_literal: true

require "digest"

module Locentra
  module Application
    module Identity
      class AuthenticationFailed < Domain::Error
        def initialize(message = "E-mail ou senha inválidos, ou conta temporariamente bloqueada")
          super
        end
      end

      class TooManyRequests < Domain::Error
        attr_reader :retry_after

        def initialize(retry_after)
          @retry_after = retry_after
          super("Muitas tentativas. Aguarde antes de tentar novamente.")
        end
      end

      module Tokens
        module_function

        def digest(token) = Digest::SHA256.hexdigest(token.to_s)
      end

      # Sessões opacas armazenadas no servidor. O cookie carrega somente o token aleatório; o banco
      # guarda o SHA-256 do token. Expiração por inatividade e absoluta; rotação em login e troca
      # de organização; revogação individual ou de todas as sessões do usuário.
      class Sessions
        IDLE_SECONDS = 2 * 3600
        ABSOLUTE_SECONDS = 12 * 3600
        TOUCH_INTERVAL = 60

        def initialize(uow:, repository:, clock:, ids:, idle_seconds: IDLE_SECONDS, absolute_seconds: ABSOLUTE_SECONDS)
          @uow = uow
          @repository = repository
          @clock = clock
          @ids = ids
          @idle = idle_seconds
          @absolute = absolute_seconds
        end

        def create(user_id:, organization_id: nil, kind: "staff", ip: nil, user_agent: nil, rotate_from: nil)
          token = @ids.token(32)
          now = @clock.now
          row = {
            "id" => @ids.uuid, "token_digest" => Tokens.digest(token), "kind" => kind, "user_id" => user_id,
            "organization_id" => organization_id, "csrf_token" => @ids.token(32), "ip" => ip, "user_agent" => user_agent.to_s[0, 300],
            "created_at" => now, "last_seen_at" => now, "idle_expires_at" => now + @idle, "absolute_expires_at" => now + @absolute
          }
          @uow.anonymous(user_id: user_id) do |tx|
            @repository.revoke(tx, rotate_from, now, "rotated") if rotate_from
            @repository.insert(tx, row)
          end
          [token, row]
        end

        # Resolve o token do cookie; nil quando inexistente, revogado ou expirado.
        def resolve(token)
          return nil if token.to_s.empty? || token.to_s.length > 200

          now = @clock.now
          @uow.anonymous do |tx|
            session = @repository.find_by_digest(tx, Tokens.digest(token))
            next nil unless session && session["revoked_at"].nil?
            next nil if now >= session["idle_expires_at"] || now >= session["absolute_expires_at"]

            if now - session["last_seen_at"] >= TOUCH_INTERVAL
              idle_until = [now + @idle, session["absolute_expires_at"]].min
              @repository.touch(tx, session["id"], now, idle_until)
              session = session.merge("last_seen_at" => now, "idle_expires_at" => idle_until)
            end
            session
          end
        end

        def rotate(session, organization_id:)
          create(user_id: session["user_id"], organization_id: organization_id, kind: session["kind"], ip: session["ip"],
                 user_agent: session["user_agent"], rotate_from: session["id"])
        end

        def revoke(session_id, reason = "logout")
          @uow.anonymous { |tx| @repository.revoke(tx, session_id, @clock.now, reason) }
        end

        def revoke_all(user_id, reason)
          @uow.anonymous { |tx| @repository.revoke_all_for_user(tx, user_id, @clock.now, reason) }
        end
      end

      # Autenticação por e-mail e senha com limitação de tentativas por IP e por conta, bloqueio
      # temporário e comparação de tempo constante mesmo quando o usuário não existe.
      class Authenticate
        MAX_FAILURES = 5
        LOCK_SECONDS = 15 * 60

        def initialize(uow:, users:, hasher:, rate_limiter:, clock:)
          @uow = uow
          @users = users
          @hasher = hasher
          @rate_limiter = rate_limiter
          @clock = clock
        end

        def call(email:, password:, ip:)
          normalized = email.to_s.strip.downcase[0, 254]
          throttle!("login:ip:#{ip}", 30, 300)
          throttle!("login:email:#{normalized}", 10, 900)
          now = @clock.now

          # A falha é registrada em transação confirmada; o erro só é lançado após o commit.
          result = @uow.anonymous { |tx| verify(tx, normalized, password.to_s, now) }
          raise AuthenticationFailed if result == :failed

          result
        end

        private

        def verify(tx, email, password, now)
          user = @users.find_by_email(tx, email)
          unless user
            @hasher.verify(password, @hasher.dummy_digest)
            return :failed
          end
          return :failed if user["locked_until"] && user["locked_until"] > now
          return :failed if password.bytesize > Domain::Identity::PasswordPolicy::MAX_BYTES

          unless @hasher.verify(password, user["password_digest"])
            @users.register_failure(tx, user["id"], MAX_FAILURES, now + LOCK_SECONDS, now)
            return :failed
          end
          @users.reset_failures(tx, user["id"], now)
          user
        end

        def throttle!(key, limit, window)
          result = @rate_limiter.hit(key, limit: limit, window_seconds: window)
          raise TooManyRequests, result.retry_after unless result.allowed
        end
      end

      # Cadastro de nova organização: usuário proprietário, filial principal e assinatura em teste.
      # `request_id` (da requisição, quando houver) correlaciona a auditoria e o e-mail de confirmação.
      class SignUp
        TRIAL_DAYS = 14

        def initialize(uow:, users:, organizations:, hasher:, notifier:, clock:, ids:, audit:)
          @uow = uow
          @users = users
          @organizations = organizations
          @hasher = hasher
          @notifier = notifier
          @clock = clock
          @ids = ids
          @audit = audit
        end

        def call(name:, email:, password:, organization_name:, plan_id: "profissional", timezone: "America/Sao_Paulo", request_id: nil)
          now = @clock.now
          email = Domain::Identity::Email.normalize(email)
          Domain::Identity::PasswordPolicy.validate!(password)
          user_name = Domain::Organizations::Text.required(name, "nome", max: 120)
          org = Domain::Organizations::Organization.build(id: @ids.uuid, name: organization_name, timezone: timezone)
          digest = @hasher.hash(password)

          @uow.anonymous(request_id: request_id) do |tx|
            if @users.find_by_email(
              tx, email
            )
              raise Domain::Conflict.new("e-mail já cadastrado; entre com sua conta para criar outra organização",
                                         code: "email_taken")
            end

            plan = @organizations.find_plan(tx, plan_id) || raise(Domain::ValidationError.field("plano", "plano inexistente"))
            user_id = @ids.uuid
            @users.insert(tx, "id" => user_id, "email" => email, "name" => user_name, "password_digest" => digest, "created_at" => now,
                              "updated_at" => now)
            tx.switch_tenant!(org.id)
            create_tenant(tx, org, user_id, plan, now)
            @notifier.email_confirmation(tx, user_id)
            actor = Actor.user(user_id: user_id, organization_id: org.id, role: "owner", request_id: request_id)
            @audit.record(tx, actor, "organization.created", "organization", org.id, "plan" => plan.fetch("id"))
            { user_id: user_id, organization_id: org.id }
          end
        end

        private

        def create_tenant(tx, org, user_id, plan, now)
          @organizations.insert(tx, org, now)
          @organizations.insert_branch(tx,
                                       Domain::Organizations::Branch.build(id: @ids.uuid, organization_id: org.id, name: "Matriz", code: "MATRIZ"), now)
          @organizations.insert_membership(tx, "id" => @ids.uuid, "organization_id" => org.id, "user_id" => user_id, "role" => "owner",
                                               "created_at" => now, "updated_at" => now)
          today = now.to_date
          @organizations.insert_subscription(tx,
                                             "id" => @ids.uuid, "organization_id" => org.id, "plan_id" => plan.fetch("id"), "status" => "trialing",
                                             "started_at" => now, "trial_ends_at" => now + (TRIAL_DAYS * 86_400),
                                             "current_period_start" => today, "current_period_end" => today.next_month,
                                             "implementation_fee_cents" => plan.fetch("implementation_fee_cents"), "created_at" => now, "updated_at" => now)
        end
      end

      # Tokens de uso único (confirmação de e-mail e recuperação de senha).
      class OneTimeTokens
        def initialize(repository:, clock:, ids:)
          @repository = repository
          @clock = clock
          @ids = ids
        end

        def issue(tx, user_id, purpose, ttl_seconds)
          token = @ids.token(32)
          now = @clock.now
          @repository.invalidate_pending(tx, user_id, purpose, now)
          @repository.insert(tx, "id" => @ids.uuid, "user_id" => user_id, "purpose" => purpose, "token_digest" => Tokens.digest(token),
                                 "expires_at" => now + ttl_seconds, "created_at" => now)
          token
        end

        # Consome o token atomicamente: duas tentativas simultâneas não podem ambas ter sucesso.
        def consume(tx, token, purpose)
          row = @repository.consume(tx, Tokens.digest(token), purpose, @clock.now)
          raise Domain::ValidationError.field("token", "link inválido ou expirado") unless row

          row
        end
      end

      class ConfirmEmail
        def initialize(uow:, tokens:, users:, clock:)
          @uow = uow
          @tokens = tokens
          @users = users
          @clock = clock
        end

        def call(token)
          @uow.anonymous do |tx|
            row = @tokens.consume(tx, token, "email_confirmation")
            @users.confirm_email(tx, row.fetch("user_id"), @clock.now)
            row.fetch("user_id")
          end
        end
      end

      # Recuperação de senha. A resposta é idêntica para e-mails existentes e inexistentes; o token
      # é emitido pelo envio do e-mail (worker) e nunca fica gravado em texto claro. A tarefa do e-mail
      # recebe o `request_id` da requisição como correlação.
      class RequestPasswordReset
        def initialize(uow:, users:, rate_limiter:, notifier:)
          @uow = uow
          @users = users
          @rate_limiter = rate_limiter
          @notifier = notifier
        end

        def call(email:, ip:, request_id: nil)
          normalized = email.to_s.strip.downcase[0, 254]
          return true unless @rate_limiter.hit("reset:ip:#{ip}", limit: 10, window_seconds: 3600).allowed
          return true unless @rate_limiter.hit("reset:email:#{normalized}", limit: 3, window_seconds: 3600).allowed

          @uow.anonymous(request_id: request_id) do |tx|
            user = @users.find_by_email(tx, normalized)
            @notifier.password_reset(tx, user) if user
          end
          true
        end
      end

      class ResetPassword
        def initialize(uow:, users:, tokens:, hasher:, sessions_repository:, clock:)
          @uow = uow
          @users = users
          @tokens = tokens
          @hasher = hasher
          @sessions = sessions_repository
          @clock = clock
        end

        def call(token:, password:)
          Domain::Identity::PasswordPolicy.validate!(password)
          digest = @hasher.hash(password)
          @uow.anonymous do |tx|
            row = @tokens.consume(tx, token, "password_reset")
            now = @clock.now
            @users.update_password(tx, row.fetch("user_id"), digest, now)
            @sessions.revoke_all_for_user(tx, row.fetch("user_id"), now, "password_reset")
            row.fetch("user_id")
          end
        end
      end

      # Lista as organizações às quais o usuário tem vínculo ativo.
      class ListMemberships
        def initialize(uow:, organizations:)
          @uow = uow
          @organizations = organizations
        end

        def call(user_id)
          @uow.anonymous(user_id: user_id) { |tx| @organizations.memberships_for_user(tx, user_id) }
        end
      end
    end
  end
end
