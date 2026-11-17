# frozen_string_literal: true

require "json"

module Locentra
  module Infrastructure
    module Database
      class NestedTransactionError < StandardError; end

      # Transação ativa ligada a uma única conexão. Repositórios recebem este objeto como
      # primeiro argumento e nunca acessam o pool: toda a operação ocorre na mesma conexão.
      class Transaction
        attr_reader :tenant_id, :user_id, :actor

        def initialize(conn, tenant_id:, user_id:, actor: nil)
          @conn = conn
          @tenant_id = tenant_id
          @user_id = user_id
          @actor = actor
          @savepoints = 0
          @after_commit = []
        end

        # Executa SQL parametrizado e devolve linhas como Hash com chaves String.
        def query(sql, params = [])
          result = ErrorTranslation.call { @conn.exec_params(sql, Params.encode(params)) }
          result.to_a
        ensure
          result&.clear
        end

        def query_one(sql, params = [])
          query(sql, params).first
        end

        def query_value(sql, params = [])
          row = query_one(sql, params)
          row&.values&.first
        end

        # Executa comando e devolve o número de linhas afetadas.
        def execute(sql, params = [])
          result = ErrorTranslation.call { @conn.exec_params(sql, Params.encode(params)) }
          result.cmd_tuples
        ensure
          result&.clear
        end

        # Ponto de restauração dentro da transação. Falhas desfazem somente o bloco.
        def savepoint
          @savepoints += 1
          name = "sp_#{@savepoints}"
          @conn.exec("SAVEPOINT #{name}")
          result = yield
          @conn.exec("RELEASE SAVEPOINT #{name}")
          result
        rescue StandardError
          @conn.exec("ROLLBACK TO SAVEPOINT #{name}") unless @conn.finished?
          raise
        end

        # Troca o contexto de tenant dentro da mesma transação. Usado somente em fluxos que
        # criam a organização ou aceitam convites, quando o tenant é derivado de dado verificado.
        def switch_tenant!(tenant_id)
          @conn.exec_params("SELECT set_config('app.tenant_id', $1, true)", [tenant_id.to_s])
          @tenant_id = tenant_id
        end

        def tenant_id!
          @tenant_id || raise(Domain::AccessDenied, "contexto de organização ausente")
        end

        # Ações executadas somente após COMMIT bem-sucedido (ex.: métricas, despertar worker).
        def after_commit(&block)
          @after_commit << block
        end

        def run_after_commit
          @after_commit.each(&:call)
        end
      end

      # Coordenador de transações.
      #
      # Política de aninhamento: abrir uma nova transação na mesma thread enquanto outra está ativa
      # gera NestedTransactionError. Casos de uso que compõem outros recebem a transação existente;
      # rollback parcial usa `Transaction#savepoint`.
      class Transactor
        THREAD_KEY = :locentra_active_transaction
        ISOLATION = { read_committed: "READ COMMITTED", repeatable_read: "REPEATABLE READ", serializable: "SERIALIZABLE" }.freeze
        RETRYABLE = [PG::TRDeadlockDetected, PG::TRSerializationFailure].freeze

        def initialize(pool:, logger: nil, metrics: nil)
          @pool = pool
          @logger = logger
          @metrics = metrics
        end

        def call(tenant_id: nil, user_id: nil, actor: nil, isolation: :read_committed, retries: 2, &)
          raise NestedTransactionError, "transação já ativa nesta thread" if Thread.current[THREAD_KEY]

          attempt = 0
          begin
            attempt += 1
            run(tenant_id, user_id, actor, isolation, &)
          rescue *RETRYABLE => e
            @metrics&.increment("db_transaction_retries_total", reason: e.class.name.split("::").last)
            retry if attempt <= retries
            raise Domain::Conflict.new("operação concorrente; tente novamente", code: "concurrent_update")
          end
        end

        def active?
          !Thread.current[THREAD_KEY].nil?
        end

        private

        def run(tenant_id, user_id, actor, isolation)
          @pool.with_connection do |conn|
            tx = Transaction.new(conn, tenant_id: tenant_id, user_id: user_id, actor: actor)
            Thread.current[THREAD_KEY] = tx
            begin
              conn.exec("BEGIN ISOLATION LEVEL #{ISOLATION.fetch(isolation)}")
              conn.exec_params("SELECT set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true)",
                               [tenant_id.to_s, user_id.to_s])
              result = yield tx
              conn.exec("COMMIT")
            rescue Exception # rubocop:disable Lint/RescueException -- rollback também em interrupções
              rollback(conn)
              raise
            ensure
              Thread.current[THREAD_KEY] = nil
            end
            tx.run_after_commit
            result
          end
        end

        def rollback(conn)
          conn.exec("ROLLBACK") unless conn.finished? || conn.transaction_status == PG::PQTRANS_IDLE
        rescue PG::Error => e
          @logger&.warn(event: "db.rollback_failed", error: e.class.name)
        end
      end

      # Converte violações de constraints em erros de domínio/aplicação. Mensagens do PostgreSQL
      # não são repassadas ao usuário para não expor detalhes do schema.
      module ErrorTranslation
        module_function

        def call
          yield
        rescue PG::ExclusionViolation
          raise Application::AllocationConflict, "alocação sobreposta"
        rescue PG::UniqueViolation => e
          raise Domain::Conflict.new("registro duplicado", code: "duplicate:#{constraint(e)}")
        rescue PG::ForeignKeyViolation
          raise Domain::NotFound, "registro relacionado"
        rescue PG::CheckViolation, PG::NotNullViolation, PG::InvalidTextRepresentation
          raise Domain::ValidationError.new({ "base" => ["dados inválidos"] })
        rescue PG::InsufficientPrivilege
          raise Domain::AccessDenied, "operação não permitida no contexto atual"
        end

        def constraint(error)
          error.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) || "desconhecida"
        end
      end

      # Codificação explícita de parâmetros. Valores nunca são interpolados no SQL.
      module Params
        ARRAY_ENCODER = PG::TextEncoder::Array.new(elements_type: PG::TextEncoder::String.new)

        module_function

        def encode(params)
          params.map { |value| encode_value(value) }
        end

        def encode_value(value)
          case value
          when nil then nil
          when Time then value.utc.iso8601(6)
          when Date then value.iso8601
          when true then "t"
          when false then "f"
          when Hash then JSON.generate(value)
          when Domain::Period then value.to_pg_range
          when Array then encode_array(value)
          else value.to_s
          end
        end

        def encode_array(values)
          return JSON.generate(values) if values.any?(Hash)

          ARRAY_ENCODER.encode(values.map { |v| v.nil? ? nil : encode_value(v) })
        end

        # Força serialização JSON para colunas jsonb que recebem arrays.
        def json(value)
          JSON.generate(value)
        end
      end
    end
  end
end
