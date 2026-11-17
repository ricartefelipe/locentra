# frozen_string_literal: true

module Locentra
  module Domain
    # Raiz das exceções de negócio. Exceções de infraestrutura nunca herdam daqui.
    class Error < StandardError; end

    # Dados de entrada inválidos. Carrega erros por campo para a interface.
    class ValidationError < Error
      attr_reader :errors

      def initialize(errors, message = nil)
        @errors = errors.is_a?(Hash) ? errors.transform_keys(&:to_s).freeze : { "base" => [errors.to_s] }.freeze
        super(message || @errors.map { |field, messages| "#{field}: #{Array(messages).join(", ")}" }.join("; "))
      end

      def self.field(field, message)
        new({ field.to_s => [message] })
      end
    end

    # Transição de estado não permitida pela máquina de estados da entidade.
    class InvalidTransition < Error
      attr_reader :entity, :from, :to

      def initialize(entity, from, to)
        @entity = entity
        @from = from
        @to = to
        super("Transição inválida em #{entity}: #{from} -> #{to}")
      end
    end

    # Um invariante do domínio seria violado pela operação.
    class InvariantViolation < Error; end

    # Recurso inexistente ou fora do escopo do tenant. O mesmo erro é usado nos dois casos
    # para não revelar a existência de recursos de outras organizações.
    class NotFound < Error
      def initialize(resource = "recurso")
        super("#{resource} não encontrado")
      end
    end

    # Conflito com o estado atual (concorrência, unicidade, chave de idempotência).
    class Conflict < Error
      attr_reader :code

      def initialize(message, code: "conflict")
        @code = code
        super(message)
      end
    end

    # Falta de disponibilidade. `shortages` descreve cada produto sem capacidade suficiente.
    class Unavailable < Conflict
      attr_reader :shortages

      def initialize(shortages, message = "Disponibilidade insuficiente para o período solicitado")
        @shortages = shortages.freeze
        super(message, code: "unavailable")
      end
    end

    # Reserva temporária vencida no momento da operação.
    class HoldExpired < Conflict
      def initialize(message = "A reserva temporária expirou")
        super(message, code: "hold_expired")
      end
    end

    # Identidade sem permissão para a operação no recurso.
    class AccessDenied < Error
      def initialize(message = "Acesso negado")
        super
      end
    end

    # Limite contratado do plano da organização foi atingido.
    class PlanLimitExceeded < Error
      attr_reader :limit

      def initialize(limit, message)
        @limit = limit
        super(message)
      end
    end
  end
end
