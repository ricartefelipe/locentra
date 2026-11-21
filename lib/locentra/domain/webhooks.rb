# frozen_string_literal: true

module Locentra
  module Domain
    # Webhooks enviados às integrações dos clientes.
    module Webhooks
      # Pausa automática do endpoint: falhas consecutivas e tempo mínimo desde a primeira.
      #
      # As duas condições são exigidas: uma queda curta de um destino com muito tráfego não pausa o
      # endpoint, e um destino pouco usado que falha há horas (uma entrega faz até 10 tentativas em cerca
      # de 3 h) é pausado. Qualquer sucesso zera a sequência, exceto com o endpoint já pausado, quando só a
      # reativação a zera.
      module Circuit
        FAILURE_THRESHOLD = 20
        MIN_FAILING_SECONDS = 3600

        def self.trip?(consecutive_failures:, failing_since:, now:)
          consecutive_failures >= FAILURE_THRESHOLD && !failing_since.nil? && (now - failing_since) >= MIN_FAILING_SECONDS
        end
      end
    end
  end
end
