# frozen_string_literal: true

require "bcrypt"

module Locentra
  module Infrastructure
    # Hashing de senhas com bcrypt. O limite de 72 bytes é aplicado pela política de senha do
    # domínio antes de chegar aqui; senhas maiores são rejeitadas, nunca truncadas.
    class PasswordHasher
      def initialize(cost: BCrypt::Engine::DEFAULT_COST)
        @cost = cost
        @dummy = BCrypt::Password.create("locentra-dummy-password", cost: cost).to_s
      end

      def hash(password)
        raise ArgumentError, "senha acima de 72 bytes" if password.bytesize > Domain::Identity::PasswordPolicy::MAX_BYTES

        BCrypt::Password.create(password, cost: @cost).to_s
      end

      def verify(password, digest)
        return false if password.bytesize > Domain::Identity::PasswordPolicy::MAX_BYTES

        BCrypt::Password.new(digest).is_password?(password)
      rescue BCrypt::Errors::InvalidHash
        false
      end

      def dummy_digest = @dummy
    end

    # Limitação de taxa por janela fixa, persistida no PostgreSQL para valer entre processos.
    # Executa em transação própria: tentativas contam mesmo se a operação principal falhar.
    class RateLimiter
      Result = Data.define(:allowed, :remaining, :retry_after)

      def initialize(transactor:, clock:)
        @transactor = transactor
        @clock = clock
      end

      def hit(key, limit:, window_seconds:)
        now = @clock.now
        window_start = Time.at(now.to_i - (now.to_i % window_seconds)).utc
        hits = @transactor.call do |tx|
          tx.query_value(<<~SQL, [key.to_s[0, 200], window_start])
            INSERT INTO rate_limits (bucket, window_start, hits) VALUES ($1, $2, 1)
            ON CONFLICT (bucket, window_start) DO UPDATE SET hits = rate_limits.hits + 1
            RETURNING hits
          SQL
        end
        retry_after = (window_start.to_i + window_seconds) - now.to_i
        Result.new(allowed: hits <= limit, remaining: [limit - hits, 0].max, retry_after: retry_after)
      end

      def purge(before)
        @transactor.call { |tx| tx.execute("DELETE FROM rate_limits WHERE window_start < $1", [before]) }
      end
    end
  end
end
