# frozen_string_literal: true

require "pg"
require "connection_pool"

module Locentra
  module Infrastructure
    module Database
      class PoolTimeout < StandardError; end

      # Pool de conexões PostgreSQL por processo.
      #
      # - Conexões são criadas sob demanda (nenhuma conexão é aberta na construção).
      # - Após fork, o pool descarta conexões herdadas (`auto_reload_after_fork`) e o processo filho
      #   abre as suas; uma conexão nunca é usada por duas threads ao mesmo tempo.
      # - Na devolução, qualquer transação pendente sofre ROLLBACK; conexões quebradas são descartadas.
      class ConnectionPool
        attr_reader :size

        def initialize(url:, size:, timeout:, name:, metrics: nil, logger: nil, statement_timeout_ms: 15_000)
          @url = url
          @size = size
          @timeout = timeout
          @name = name
          @metrics = metrics
          @logger = logger
          @statement_timeout_ms = statement_timeout_ms
          @pool = ::ConnectionPool.new(size: size, timeout: timeout, name: name, auto_reload_after_fork: true) { connect }
        end

        def with_connection
          started = monotonic
          @pool.with do |conn|
            @metrics&.observe("db_pool_wait_seconds", monotonic - started, pool: @name)
            ensure_healthy!(conn)
            begin
              yield conn
            ensure
              release(conn)
            end
          end
        rescue ::ConnectionPool::TimeoutError
          @metrics&.increment("db_pool_timeouts_total", pool: @name)
          raise PoolTimeout, "tempo de espera por conexão esgotado no pool #{@name}"
        end

        def shutdown
          @pool.shutdown { |conn| conn.close unless conn.finished? }
        end

        def stats
          { "size" => size, "available" => @pool.available, "idle" => @pool.idle }
        end

        private

        def connect
          configure(PG.connect(@url))
        end

        def configure(conn)
          conn.exec("SET TIME ZONE 'UTC'")
          conn.exec("SET statement_timeout = #{Integer(@statement_timeout_ms)}")
          conn.exec("SET idle_in_transaction_session_timeout = 60000")
          conn.type_map_for_results = TypeMap.for_results(conn)
          conn
        end

        def ensure_healthy!(conn)
          return if !conn.finished? && conn.status == PG::CONNECTION_OK

          conn.reset
          configure(conn)
        end

        # Garante que a conexão volte ao pool sem transação aberta. Conexões em estado
        # desconhecido são reiniciadas para não contaminar a próxima requisição.
        def release(conn)
          return if conn.finished?

          case conn.transaction_status
          when PG::PQTRANS_IDLE then nil
          when PG::PQTRANS_INTRANS, PG::PQTRANS_INERROR
            conn.exec("ROLLBACK")
          else
            conn.reset
            configure(conn)
          end
        rescue PG::Error => e
          @logger&.warn(event: "db.connection_discarded", pool: @name, error: e.class.name)
          @pool.discard_current_connection { |broken| broken.close unless broken.finished? }
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # Decodificação explícita dos tipos usados pelo schema. Tipos não listados chegam como String.
      module TypeMap
        module_function

        def for_results(_conn)
          map = PG::TypeMapByOid.new
          [20, 21, 23].each { |oid| map.add_coder(PG::TextDecoder::Integer.new(oid: oid)) }
          map.add_coder(PG::TextDecoder::Boolean.new(oid: 16))
          map.add_coder(PG::TextDecoder::TimestampWithTimeZone.new(oid: 1184))
          map.add_coder(PG::TextDecoder::Date.new(oid: 1082))
          map.add_coder(PG::TextDecoder::Numeric.new(oid: 1700))
          map.add_coder(PG::TextDecoder::JSON.new(oid: 114))
          map.add_coder(PG::TextDecoder::JSON.new(oid: 3802))
          map.add_coder(PG::TextDecoder::Array.new(oid: 1009, elements_type: PG::TextDecoder::String.new))
          map.add_coder(PG::TextDecoder::Array.new(oid: 2951, elements_type: PG::TextDecoder::String.new))
          map.add_coder(PG::TextDecoder::Array.new(oid: 1016, elements_type: PG::TextDecoder::Integer.new))
          map
        end
      end
    end
  end
end
