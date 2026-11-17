# frozen_string_literal: true

require "securerandom"

module Locentra
  module Domain
    # Relógio do sistema. Componentes recebem um relógio por construtor para que testes
    # possam controlar o tempo sem alterar Time globalmente.
    class SystemClock
      def now
        Time.at(Time.now.to_i).utc
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # Gerador de identificadores. UUIDv7 preserva ordenação temporal nos índices.
    class IdGenerator
      def uuid
        SecureRandom.uuid_v7
      end

      # Token opaco de alta entropia (256 bits) codificado em base64 url-safe.
      def token(bytes = 32)
        SecureRandom.urlsafe_base64(bytes)
      end
    end

    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # Valida e normaliza identificadores recebidos de fora do sistema.
    module Identifier
      module_function

      def parse(value, field = "id")
        text = value.to_s.strip.downcase
        raise ValidationError.field(field, "identificador inválido") unless text.match?(UUID_PATTERN)

        text
      end

      def valid?(value)
        value.to_s.match?(UUID_PATTERN)
      end
    end
  end
end
