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
      #
      # Cada endereço tem limite de tentativas por hora (o IP é limitado na rota). O e-mail já
      # cadastrado é verificado antes do bcrypt, que só é calculado para um cadastro que pode ser
      # concluído. Nome de organização repetido recebe sufixo aleatório no identificador, sem revelar
      # que outra organização usa o mesmo nome.
      class SignUp
        TRIAL_DAYS = 14
        EMAIL_LIMIT = 5
        EMAIL_WINDOW = 3600
        SLUG_ATTEMPTS = 3

        def initialize(uow:, users:, organizations:, hasher:, notifier:, clock:, ids:, audit:, rate_limiter:)
          @uow = uow
          @users = users
          @organizations = organizations
          @hasher = hasher
          @notifier = notifier
          @clock = clock
          @ids = ids
          @audit = audit
          @rate_limiter = rate_limiter
        end

        def call(name:, email:, password:, organization_name:, plan_id: "profissional", timezone: "America/Sao_Paulo", request_id: nil)
          now = @clock.now
          email = Domain::Identity::Email.normalize(email)
          throttle!(email)
          Domain::Identity::PasswordPolicy.validate!(password)
          user_name = Domain::Organizations::Text.required(name, "nome", max: 120)
          org = organization(organization_name, timezone)
          @uow.anonymous { |tx| email_taken!(tx, email) }
          digest = @hasher.hash(password)

          @uow.anonymous(request_id: request_id) do |tx|
            email_taken!(tx, email)
            plan = @organizations.find_plan(tx, plan_id) || raise(Domain::ValidationError.field("plano", "plano inexistente"))
            user_id = @ids.uuid
            @users.insert(tx, "id" => user_id, "email" => email, "name" => user_name, "password_digest" => digest, "created_at" => now,
                              "updated_at" => now)
            tx.switch_tenant!(org.id)
            org = create_tenant(tx, org, user_id, plan, now)
            @notifier.email_confirmation(tx, user_id)
            actor = Actor.user(user_id: user_id, organization_id: org.id, role: "owner", request_id: request_id)
            @audit.record(tx, actor, "organization.created", "organization", org.id, "plan" => plan.fetch("id"))
            { user_id: user_id, organization_id: org.id }
          end
        end

        private

        # Erros do nome da organização vão para o campo "organizacao" do formulário (o campo "nome"
        # é o da pessoa).
        def organization(name, timezone)
          Domain::Organizations::Organization.build(id: @ids.uuid, name: name, timezone: timezone)
        rescue Domain::ValidationError => e
          raise e unless e.errors.key?("nome") || e.errors.key?("identificador")

          raise Domain::ValidationError.new({ "organizacao" => e.errors.values_at("nome", "identificador").compact.flatten })
        end

        def throttle!(email)
          result = @rate_limiter.hit("signup:email:#{email}", limit: EMAIL_LIMIT, window_seconds: EMAIL_WINDOW)
          raise TooManyRequests, result.retry_after unless result.allowed
        end

        def email_taken!(tx, email)
          return unless @users.find_by_email(tx, email)

          raise Domain::Conflict.new("e-mail já cadastrado; entre com sua conta para criar outra organização", code: "email_taken")
        end

        def insert_organization(tx, org, now, attempt = 1)
          tx.savepoint { @organizations.insert(tx, org, now) }
          org
        rescue Domain::Conflict => e
          raise unless e.code == "slug_taken" && attempt < SLUG_ATTEMPTS

          insert_organization(tx, org.with_slug_suffix(@ids.uuid.delete("-")[-6, 6]), now, attempt + 1)
        end

        def create_tenant(tx, org, user_id, plan, now)
          org = insert_organization(tx, org, now)
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
          org
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

        # Confere, sem consumir, que o token ainda pode ser usado.
        def usable!(tx, token, purpose)
          return if @repository.usable?(tx, Tokens.digest(token), purpose, @clock.now)

          raise Domain::ValidationError.field("token", "link inválido ou expirado")
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

      # Reenvio do e-mail de confirmação para o usuário da sessão (ADR-031). Liberado também para a conta
      # somente leitura. Cada usuário tem limite de pedidos por hora (o IP é limitado na rota); o token é
      # emitido pelo worker no envio, que invalida o link anterior. Conta já confirmada não recebe e-mail.
      class ResendEmailConfirmation
        USER_LIMIT = 3
        USER_WINDOW = 3600

        def initialize(uow:, users:, notifier:, rate_limiter:)
          @uow = uow
          @users = users
          @notifier = notifier
          @rate_limiter = rate_limiter
        end

        # Devolve :sent ou :already_confirmed. O limite é contado fora da transação do envio (o limitador
        # tem transação própria).
        def call(user_id:, request_id: nil)
          return :already_confirmed if confirmed?(user_id)

          throttle!(user_id)
          @uow.anonymous(user_id: user_id, request_id: request_id) do |tx|
            next :already_confirmed if confirmed?(user_id, tx)

            @notifier.email_confirmation(tx, user_id)
            :sent
          end
        end

        private

        def confirmed?(user_id, tx = nil)
          return @uow.anonymous(user_id: user_id) { |t| confirmed?(user_id, t) } unless tx

          user = @users.find(tx, user_id) || raise(Domain::NotFound, "usuário")
          !user["email_confirmed_at"].nil?
        end

        def throttle!(user_id)
          result = @rate_limiter.hit("email_confirmation:user:#{user_id}", limit: USER_LIMIT, window_seconds: USER_WINDOW)
          raise TooManyRequests, result.retry_after unless result.allowed
        end
      end

      # Correção do próprio e-mail enquanto a conta não está confirmada (ADR-031): o proprietário que errou o
      # endereço no cadastro não fica preso à conta somente leitura. Liberada também na conta somente leitura;
      # o e-mail já confirmado não é trocado por aqui.
      #
      # Exige a senha atual (conferida depois do limite por usuário, que vem antes do bcrypt; o IP é limitado
      # na rota), normaliza o endereço e recusa o mesmo endereço e o de outra conta. Na mesma transação: grava o
      # endereço somente se a conta continua sem confirmação, invalida os links de confirmação e de recuperação
      # de senha enviados ao endereço anterior, enfileira a confirmação para o novo e audita em cada organização
      # da qual a pessoa é membro ativo, com o endereço anterior mascarado.
      class CorrectUnconfirmedEmail
        USER_LIMIT = 3
        USER_WINDOW = 3600
        EMAIL_TAKEN = "e-mail já cadastrado em outra conta"

        def initialize(uow:, users:, tokens:, organizations:, hasher:, notifier:, rate_limiter:, audit:, clock:)
          @uow = uow
          @users = users
          @tokens = tokens
          @organizations = organizations
          @hasher = hasher
          @notifier = notifier
          @rate_limiter = rate_limiter
          @audit = audit
          @clock = clock
        end

        # Devolve o novo endereço.
        def call(user_id:, email:, password:, request_id: nil, ip: nil)
          address = Domain::Identity::Email.normalize(email)
          user = @uow.anonymous(user_id: user_id) { |tx| @users.find(tx, user_id) } || raise(Domain::NotFound, "usuário")
          Domain::Identity::EmailConfirmation.correctable!(user["email_confirmed_at"])
          throttle!(user_id)
          raise Domain::ValidationError.field("email", "informe um endereço diferente do atual") if address == user["email"]

          password!(password, user)
          correct(user, address, request_id, ip)
        rescue Domain::Conflict => e
          raise unless e.code == "duplicate:users_email_key"

          raise Domain::Conflict.new(EMAIL_TAKEN, code: "email_taken")
        end

        private

        def password!(password, user)
          text = password.to_s
          return if text.bytesize <= Domain::Identity::PasswordPolicy::MAX_BYTES && @hasher.verify(text, user["password_digest"])

          raise Domain::ValidationError.field("senha", "senha atual incorreta")
        end

        def correct(user, address, request_id, ip)
          @uow.anonymous(user_id: user["id"], request_id: request_id) do |tx|
            raise Domain::Conflict.new(EMAIL_TAKEN, code: "email_taken") if @users.find_by_email(tx, address)

            now = @clock.now
            # Confirmada entre a leitura e a gravação: a correção deixa de valer.
            confirmed_meanwhile = !@users.update_unconfirmed_email(tx, user["id"], address, now)
            Domain::Identity::EmailConfirmation.correctable!(confirmed_meanwhile || nil)
            %w[email_confirmation password_reset].each { |purpose| @tokens.invalidate_pending(tx, user["id"], purpose, now) }
            @notifier.email_confirmation(tx, user["id"])
            audit(tx, user, address, request_id, ip)
            address
          end
        end

        def audit(tx, user, address, request_id, ip)
          details = { "email" => address, "previous_email" => Domain::Identity::Email.mask(user["email"]) }
          @organizations.memberships_for_user(tx, user["id"]).select { |row| row["kind"] == "staff" }.each do |membership|
            tx.switch_tenant!(membership["organization_id"])
            actor = Actor.user(user_id: user["id"], organization_id: membership["organization_id"], role: membership["role"],
                               request_id: request_id, ip: ip)
            @audit.record(tx, actor, "user.email_corrected", "user", user["id"], details)
          end
        end

        def throttle!(user_id)
          result = @rate_limiter.hit("email_correction:user:#{user_id}", limit: USER_LIMIT, window_seconds: USER_WINDOW)
          raise TooManyRequests, result.retry_after unless result.allowed
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

        # O token é conferido antes do bcrypt: link inválido ou expirado não custa um hash.
        def call(token:, password:)
          Domain::Identity::PasswordPolicy.validate!(password)
          @uow.anonymous { |tx| @tokens.usable!(tx, token, "password_reset") }
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
