# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../config"
require_relative "../../infrastructure"
require_relative "../../infrastructure/observability/logger"
require_relative "output"

module Locentra
  module Interfaces
    module CLI
      # Comandos administrativos de banco. Usam MIGRATION_DATABASE_URL (proprietário do schema) e são
      # separados da CLI operacional, que usa as credenciais e as permissões da aplicação.
      class Admin
        COMMANDS = {
          "db:migrate" => "Aplica migrations pendentes (exclusão mútua por advisory lock)",
          "db:status" => "Lista migrations aplicadas, pendentes e com checksum divergente",
          "db:seed" => "Carrega dados demonstrativos idempotentes (duas organizações); recusado com APP_ENV=production"
        }.freeze

        def initialize(env: ENV, out: $stdout, err: $stderr)
          @env = env
          @out = out
          @err = err
        end

        def run(argv)
          options = { json: false }
          parser = build_parser(options)
          command = parser.parse(argv).first
          return 0 if options[:help]

          unless COMMANDS.key?(command)
            @err.puts(parser)
            return 64
          end

          dispatch(command, options)
        rescue OptionParser::ParseError => e
          @err.puts("erro: #{e.message}")
          64
        rescue Infrastructure::Database::MigrationError, ConfigError => e
          @err.puts("erro: #{e.message}")
          1
        rescue PG::Error => e
          database_error(e)
        end

        private

        # Falha de conexão (inclusive URL que o libpq não consegue interpretar, que levanta PG::Error
        # com a URL inteira na mensagem) sai com 2; erro de comando no banco, com 1. A mensagem passa
        # pelo mesmo filtro da CLI operacional: senha de URL ou de parâmetros de conexão nunca é impressa.
        def database_error(error)
          message = Redactor.scrub(error.message.lines.first.to_s.strip)
          connection = error.is_a?(PG::ConnectionBad) || error.instance_of?(PG::Error)
          @err.puts(connection ? "erro: não foi possível conectar ao banco (#{message})" : "erro do banco: #{message}")
          connection ? 2 : 1
        end

        def build_parser(options)
          OptionParser.new do |opts|
            opts.banner = "Uso: bin/locentra-admin COMANDO [opções]\n\nComandos:\n" \
                          "#{COMMANDS.map { |k, v| format("  %-12<k>s %<v>s", k: k, v: v) }.join("\n")}\n\nOpções:"
            opts.on("--json", "Saída em JSON") { options[:json] = true }
            opts.on("--allow-production", "Permite db:seed com APP_ENV=production (contas com senha pública)") { options[:allow_production] = true }
            opts.on("-h", "--help", "Ajuda") do
              @out.puts(opts)
              options[:help] = true
            end
          end
        end

        def dispatch(command, options)
          case command
          when "db:migrate" then db_migrate(options)
          when "db:status" then db_status(options)
          when "db:seed" then db_seed(options)
          end
        end

        def migrator
          url = @env["MIGRATION_DATABASE_URL"].to_s
          raise ConfigError, "MIGRATION_DATABASE_URL não definido" if url.empty?

          logger = Infrastructure::Observability::StructuredLogger.new(io: @err, level: @env.fetch("LOG_LEVEL", "info"))
          Infrastructure::Database::Migrator.new(url: url, directory: File.expand_path("../../../../db/migrations", __dir__),
                                                 logger: logger)
        end

        def db_migrate(options)
          applied = migrator.migrate
          emit(options, { "applied" => applied }, applied.empty? ? "Nenhuma migration pendente." : "Aplicadas: #{applied.join(", ")}")
          0
        end

        def db_status(options)
          rows = migrator.status
          text = rows.map { |r| format("%<v>s  %-40<n>s %<s>s", v: r["version"], n: r["name"], s: r["status"]) }.join("\n")
          emit(options, rows, text)
          rows.any? { |r| r["status"] == "checksum divergente" } ? 1 : 0
        end

        # O seed cria proprietários com a senha de demonstração publicada no README: em produção só com
        # --allow-production explícito.
        def db_seed(options)
          if @env.fetch("APP_ENV", "development") == "production" && !options[:allow_production]
            raise ConfigError, "db:seed cria contas com senha pública e é recusado com APP_ENV=production (use --allow-production " \
                               "somente em ambiente de demonstração)"
          end

          require_relative "../../system"
          require_relative "../../seed"
          system = System.boot(@env)
          summary = Seed.new(system).run
          emit(options, summary, "Seed concluído: #{summary.map { |o| o["slug"] }.join(", ")}")
          0
        ensure
          system&.shutdown
        end

        def emit(options, data, text)
          @out.puts(options[:json] ? JSON.pretty_generate(data) : text)
        end
      end
    end
  end
end
