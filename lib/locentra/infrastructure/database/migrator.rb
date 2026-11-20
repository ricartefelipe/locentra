# frozen_string_literal: true

require "digest"
require "pg"

module Locentra
  module Infrastructure
    module Database
      class MigrationError < StandardError; end

      # Runner de migrations SQL versionadas.
      #
      # - Arquivos `db/migrations/NNNN_nome.sql`, aplicados em ordem numérica.
      # - Cada migration roda em transação própria e registra versão, nome e checksum SHA-256.
      # - Uma migration aplicada cujo arquivo mudou interrompe a execução (edição silenciosa).
      # - `pg_advisory_lock` garante exclusão mútua entre execuções simultâneas, inclusive em
      #   processos e máquinas diferentes.
      # - Usa credenciais de migration (proprietário do schema), separadas das da aplicação.
      class Migrator
        LOCK_KEY = 7_420_191_001
        FILE_PATTERN = /\A(\d{4})_([a-z0-9_]+)\.sql\z/

        Migration = Data.define(:version, :name, :path, :checksum)

        def initialize(url:, directory:, logger: nil, connect: ->(u) { PG.connect(u) })
          @url = url
          @directory = directory
          @logger = logger
          @connect = connect
        end

        def migrate
          with_lock do |conn|
            ensure_table(conn)
            applied = applied_versions(conn)
            verify_checksums!(applied)
            pending = migrations.reject { |m| applied.key?(m.version) }
            pending.each { |migration| apply(conn, migration) }
            pending.map(&:version)
          end
        end

        def status
          with_lock do |conn|
            ensure_table(conn)
            applied = applied_versions(conn)
            migrations.map do |m|
              state = if !applied.key?(m.version) then "pendente"
                      elsif applied[m.version] == m.checksum then "aplicada"
                      else "checksum divergente"
                      end
              { "version" => m.version, "name" => m.name, "status" => state }
            end
          end
        end

        def pending?
          with_connection do |conn|
            exists = conn.exec("SELECT to_regclass('public.schema_migrations') IS NOT NULL AS e").getvalue(0, 0) == "t"
            return true unless exists

            applied = conn.exec("SELECT version FROM schema_migrations").column_values(0)
            migrations.any? { |m| !applied.include?(m.version) }
          end
        end

        def migrations
          Dir.children(@directory).sort.filter_map do |file|
            match = FILE_PATTERN.match(file)
            next unless match

            path = File.join(@directory, file)
            Migration.new(version: match[1], name: match[2], path: path, checksum: Digest::SHA256.file(path).hexdigest)
          end
        end

        private

        def with_connection
          conn = @connect.call(@url)
          conn.exec("SET client_min_messages = warning")
          yield conn
        ensure
          conn&.close
        end

        def with_lock
          with_connection do |conn|
            conn.exec_params("SELECT pg_advisory_lock($1)", [LOCK_KEY])
            begin
              yield conn
            ensure
              conn.exec_params("SELECT pg_advisory_unlock($1)", [LOCK_KEY]) unless conn.finished?
            end
          end
        end

        def ensure_table(conn)
          conn.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS schema_migrations (
              version text PRIMARY KEY,
              name text NOT NULL,
              checksum text NOT NULL,
              applied_at timestamptz NOT NULL DEFAULT now()
            )
          SQL
        end

        def applied_versions(conn)
          conn.exec("SELECT version, checksum FROM schema_migrations").to_h { |row| [row["version"], row["checksum"]] }
        end

        def verify_checksums!(applied)
          by_version = migrations.to_h { |m| [m.version, m] }
          applied.each do |version, checksum|
            migration = by_version[version]
            raise MigrationError, "migration #{version} aplicada não existe mais no diretório" unless migration
            next if migration.checksum == checksum

            raise MigrationError, "migration #{version}_#{migration.name} foi alterada após aplicada; crie uma nova migration"
          end
        end

        def apply(conn, migration)
          @logger&.info(event: "db.migration.apply", version: migration.version, name: migration.name)
          conn.exec("BEGIN")
          conn.exec(File.read(migration.path))
          conn.exec_params("INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)",
                           [migration.version, migration.name, migration.checksum])
          conn.exec("COMMIT")
        rescue PG::Error => e
          conn.exec("ROLLBACK") unless conn.finished?
          raise MigrationError, "falha na migration #{migration.version}_#{migration.name}: #{e.message.lines.first&.strip}"
        end
      end
    end
  end
end
