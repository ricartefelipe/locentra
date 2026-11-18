# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"
require_relative "../../system"
require_relative "invocation"
require_relative "token_source"
require_relative "output"
require_relative "commands"

module Locentra
  module Interfaces
    module CLI
      class CredentialRejected < StandardError; end

      # CLI operacional (`bin/locentra`).
      #
      # - Identidade: credencial de integração do tipo `cli`, lida de LOCENTRA_TOKEN ou de
      #   `--token-file` e autenticada por AuthenticateCredential. A UnitOfWork revalida credencial,
      #   tipo e escopos em cada operação; a auditoria registra actor_type `cli` e o request id da
      #   execução. Não há atalho: cada comando chama os mesmos casos de uso da web e da API.
      # - Banco: DATABASE_URL com o papel da aplicação (RLS e grants da aplicação). Na montagem, o
      #   papel conectado é conferido no próprio banco: superusuário, BYPASSRLS, proprietário do
      #   schema (credencial de migrations) e papel com políticas para todas as organizações (worker)
      #   são recusados. Comandos de banco continuam em bin/locentra-admin.
      # - Saída: texto em português ou JSON estável (`--json`) no stdout; erros e log no stderr.
      #   Toda saída passa pelo Redactor (token, senhas de banco); no JSON, valor a valor. Códigos
      #   em ExitCodes.
      class Operational
        E = ExitCodes
        DATABASE = Infrastructure::Database
        POOL_SIZE = 2
        LOG_LEVEL_ENV = "LOCENTRA_CLI_LOG_LEVEL"
        DATABASE_URLS = %w[DATABASE_URL MIGRATION_DATABASE_URL WORKER_DATABASE_URL].freeze
        URL_PASSWORD = %r{\A\s*[a-z][a-z0-9+.-]*://[^/:@\s]*:([^@\s]+)@}i
        CONNINFO_PASSWORD = /\bpassword\s*=\s*(?:'([^']*)'|(\S+))/i

        # Atributos do papel conectado que o tornam inadequado para a CLI de negócio.
        ROLE_CHECK = <<~SQL
          SELECT r.rolsuper OR r.rolbypassrls AS bypasses_rls,
                 EXISTS (SELECT 1 FROM pg_tables t WHERE t.schemaname = current_schema() AND pg_has_role(t.tableowner, 'USAGE')) AS owns_schema,
                 EXISTS (SELECT 1 FROM pg_policies p
                          WHERE p.schemaname = current_schema() AND current_user = ANY (p.roles) AND p.qual = 'true') AS all_organizations
            FROM pg_roles r WHERE r.rolname = current_user
        SQL
        ROLE_REFUSALS = {
          "bypasses_rls" => "superusuário ou BYPASSRLS",
          "owns_schema" => "proprietário do schema, credencial de migrations",
          "all_organizations" => "políticas com acesso a todas as organizações, papel do worker"
        }.freeze

        FAILURES = [
          [UsageError, E::USAGE, "usage"], [OptionParser::ParseError, E::USAGE, "usage"],
          [ConfigError, E::CONFIG, "configuration"], [PG::ConnectionBad, E::CONFIG, "connection"],
          [DATABASE::PoolTimeout, E::CONFIG, "connection"],
          [CredentialRejected, E::DENIED, "credential_rejected"], [Domain::AccessDenied, E::DENIED, "forbidden"],
          [Domain::Unavailable, E::UNAVAILABLE, "unavailable"], [Domain::Conflict, E::UNAVAILABLE, nil],
          [Domain::InvalidTransition, E::UNAVAILABLE, "invalid_transition"],
          [Domain::ValidationError, E::BUSINESS, "validation_error"], [Domain::NotFound, E::BUSINESS, "not_found"],
          [Domain::PlanLimitExceeded, E::BUSINESS, "plan_limit"], [Domain::Error, E::BUSINESS, "business_error"]
        ].freeze

        # `system` permite reutilizar um System já montado (testes); sem ele, a CLI monta o próprio
        # System a partir do ambiente e o encerra ao final.
        def initialize(env: ENV, out: $stdout, err: $stderr, system: nil)
          @env = env
          @out = SafeOutput.new(out)
          @err = SafeOutput.new(err)
          @system = system
          @request_id = SecureRandom.uuid
          protect(@env[TokenSource::ENV_NAME])
          DATABASE_URLS.each { |name| database_passwords(@env[name]).each { |password| protect(password) } }
          @logger = Infrastructure::Observability::StructuredLogger.new(io: @err.log_io, level: @env.fetch(LOG_LEVEL_ENV, "warn"),
                                                                        base: { "service" => "locentra-cli", "request_id" => @request_id })
        end

        def run(argv)
          parser = Parser.new
          invocation = parser.parse(argv)
          return help(parser, invocation) if invocation.help

          execute(invocation)
        rescue Interrupt
          @err.puts("interrompido")
          E::INTERRUPTED
        rescue StandardError => e
          failure(e, json: invocation ? invocation.json : argv.include?("--json"))
        end

        private

        def protect(secret)
          [@out, @err].each { |io| io.protect(secret.to_s.strip) }
        end

        # Senhas das URLs de banco do ambiente (formato URL, literal e decodificada, ou chave=valor),
        # mascaradas literalmente mesmo quando uma mensagem as repete fora do formato original.
        def database_passwords(url)
          text = url.to_s
          found = [text[URL_PASSWORD, 1], *text.scan(CONNINFO_PASSWORD).flatten].compact
          found + found.map { |password| URI.decode_www_form_component(password) }
        rescue ArgumentError
          found
        end

        def help(parser, invocation)
          @out.puts(invocation.options[:version] ? "locentra #{VERSION}" : parser.help_text)
          E::OK
        end

        def execute(invocation)
          token = TokenSource.new(env: @env, file: invocation.token_file).read
          protect(token)
          with_system do |system|
            actor = authenticate(system, token)
            result = Commands.new(system: system, actor: actor).run(invocation)
            emit(result, invocation.json)
            @logger.info(event: "cli.command", command: invocation.command.name, credential_id: actor.credential_id, exit_code: result.exit_code)
            result.exit_code
          end
        end

        def with_system
          return yield(@system) if @system

          system = boot
          yield system
        ensure
          system&.shutdown
        end

        # Monta o System e abre a primeira conexão já na montagem, para que URL inválida, banco
        # inacessível e papel inadequado sejam erros de configuração (2) antes de qualquer comando.
        def boot
          refuse_migration_credential!
          system = System.boot(@env, {}, logger: @logger, pool_name: "cli", pool_size: POOL_SIZE)
          verify_database_role!(system)
          system
        rescue StandardError
          system&.shutdown
          raise
        end

        # O papel é conferido no banco, independentemente de MIGRATION_DATABASE_URL estar configurada.
        def verify_database_role!(system)
          role = system.pool.with_connection { |conn| conn.exec(ROLE_CHECK)[0] }
          refusal = ROLE_REFUSALS.find { |attribute, _| role.fetch(attribute) }
          return unless refusal

          raise ConfigError, "DATABASE_URL usa um papel inadequado (#{refusal.last}); a CLI operacional exige o papel da aplicação"
        rescue PG::ConnectionBad
          raise
        rescue PG::Error => e
          # O libpq recusa a URL antes de conectar (ex.: esquema inválido) e pode repeti-la na
          # mensagem; a saída mascara a senha.
          raise ConfigError, "DATABASE_URL inválida: #{e.message.lines.first.to_s.strip}"
        end

        # Verificação prévia, sem conexão: DATABASE_URL igual à credencial de migrations (ou com o
        # mesmo usuário) é recusada antes de conectar.
        def refuse_migration_credential!
          app = @env["DATABASE_URL"].to_s
          migration = @env["MIGRATION_DATABASE_URL"].to_s
          return if app.empty? || migration.empty?

          user = database_user(app)
          return unless app == migration || (user && user == database_user(migration))

          raise ConfigError, "DATABASE_URL usa a credencial de migrations; a CLI operacional exige o papel da aplicação"
        end

        def database_user(url)
          URI.parse(url).user
        rescue URI::InvalidURIError
          nil
        end

        def authenticate(system, token)
          actor = system.use_cases[:authenticate_credential].call(token, kind: "cli", request_id: @request_id)
          raise CredentialRejected, "credencial recusada: inválida, revogada, expirada ou não é do tipo cli" unless actor

          actor
        end

        def emit(result, json)
          return @out.json(result.data) if json

          result.lines.each { |line| @out.puts(line) }
        end

        def failure(error, json:)
          _, status, code = FAILURES.find { |klass, _, _| error.is_a?(klass) }
          status ||= E::INTERNAL
          code ||= status == E::INTERNAL ? "internal_error" : error.code
          log_internal(error) if status == E::INTERNAL
          message = message_for(error, status)
          details = details_for(error)
          if json
            @err.json({ "error" => { "code" => code, "message" => message, "details" => details, "exit_code" => status,
                                     "request_id" => @request_id } }, pretty: false)
          else
            @err.puts("erro: #{message}")
            detail_lines(details).each { |line| @err.puts("  #{line}") }
            @err.puts("Use bin/locentra --help para ver o uso.") if status == E::USAGE
          end
          status
        end

        def message_for(error, status)
          case error
          when OptionParser::ParseError then usage_message(error)
          when PG::ConnectionBad then "não foi possível conectar ao banco (#{error.message.lines.first.to_s.strip})"
          when DATABASE::PoolTimeout then "tempo de espera por conexão com o banco esgotado"
          else status == E::INTERNAL ? "erro interno inesperado (referência #{@request_id}); detalhes no log" : error.message
          end
        end

        # Mensagens do OptionParser traduzidas, sem repetir o valor informado.
        def usage_message(error)
          option = error.args.first.to_s.split("=", 2).first
          case error
          when OptionParser::InvalidOption then "opção desconhecida: #{option}"
          when OptionParser::MissingArgument then "a opção #{option} exige um valor"
          when OptionParser::InvalidArgument then "valor inválido para #{option}"
          when OptionParser::NeedlessArgument then "a opção #{option} não aceita valor"
          else "uso incorreto"
          end
        end

        def details_for(error)
          case error
          when Domain::ValidationError then { "fields" => error.errors }
          when Domain::Unavailable then { "shortages" => error.shortages }
          else {}
          end
        end

        # A mensagem de validação já lista os campos; faltas de disponibilidade são detalhadas por produto.
        def detail_lines(details)
          details.fetch("shortages", []).map do |s|
            "#{s["sku"] || s["product_id"]}: solicitado #{s["requested"] || "—"}, disponível #{s["available"] || "—"}"
          end
        end

        def log_internal(error)
          @logger.error(event: "cli.error", error: error.class.name, message: error.message, backtrace: error.backtrace&.first(8))
        end
      end
    end
  end
end
