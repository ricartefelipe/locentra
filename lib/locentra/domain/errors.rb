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

      # Rótulos das situações por entidade, resolvidos ao montar a mensagem (as entidades já estão
      # carregadas). Alvos que não são situações (por exemplo, "aditivo") aparecem como recebidos.
      LABELS = {
        "reserva" => -> { Reservations::STATUSES }, "orçamento" => -> { Quotes::STATUSES }, "contrato" => -> { Contracts::STATUSES },
        "ativo" => -> { Catalog::ASSET_STATUSES }, "pagamento" => -> { Finance::PAYMENT_STATUSES },
        "reembolso" => -> { Finance::REFUND_STATUSES }, "inspeção" => -> { Maintenance::INSPECTION_STATUSES },
        "ordem de manutenção" => -> { Maintenance::ORDER_STATUSES }, "registro de avaria" => -> { Maintenance::DAMAGE_STATUSES },
        "transferência" => -> { Transfers::STATUSES }, "alerta" => -> { Alerts::STATUSES },
        "convite do portal" => -> { Portal::INVITATION_STATUSES }, "retirada" => -> { Fulfillment::PICKUP_STATUSES },
        "condição negociada" => -> { Pricing::AGREEMENT_STATUSES }
      }.freeze

      def initialize(entity, from, to)
        @entity = entity
        @from = from
        @to = to
        labels = self.class.labels_for(entity)
        super("Transição inválida em #{entity}: #{labels.fetch(from.to_s, from)} → #{labels.fetch(to.to_s, to)}")
      end

      def self.labels_for(entity)
        LABELS.fetch(entity, -> { {} }).call
      rescue NameError
        {}
      end
    end

    # Um invariante do domínio seria violado pela operação.
    class InvariantViolation < Error; end

    # Recurso inexistente ou fora do escopo do tenant. O mesmo erro é usado nos dois casos
    # para não revelar a existência de recursos de outras organizações.
    class NotFound < Error
      def initialize(resource = "recurso", feminine: false)
        super("#{resource} não encontrad#{feminine ? "a" : "o"}")
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
