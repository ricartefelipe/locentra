# frozen_string_literal: true

module Locentra
  module Application
    # Registro das chamadas a sistemas externos (provedores de pagamento, webhooks enviados).
    #
    # Cada chamada gera uma linha de log `external.call` com serviço, operação, desfecho, duração, a
    # organização e o `correlation_id` (o request_id da requisição que originou a operação, levado
    # pelo ator ou pela tarefa), e alimenta as métricas `external_calls_total{provider,kind,outcome}` e
    # `external_call_duration_seconds{provider,kind}`. Rótulos de métricas são de baixa cardinalidade:
    # identificadores vão somente para o log (`details`).
    #
    # Portas: `logger` com `info`/`warn`, `metrics` com `increment`/`observe` e `clock` com `monotonic`
    # (duração das chamadas).
    class ExternalCalls
      def initialize(logger:, metrics:, clock: Domain::SystemClock.new)
        @logger = logger
        @metrics = metrics
        @clock = clock
      end

      # `outcome` classifica um resultado sem exceção (padrão "ok"); `errors` associa classes de
      # exceção a desfechos (padrão "error"). A exceção da chamada é sempre propagada ao chamador.
      def track(service:, operation:, organization_id:, correlation_id:, outcome: nil, errors: {}, details: {})
        context = details.merge(organization_id: organization_id, correlation_id: correlation_id)
        started = monotonic
        begin
          result = yield
        rescue StandardError => e
          label = errors.find { |klass, _| e.is_a?(klass) }&.last || "error"
          record(service, operation, label, started, context.merge(error: "#{e.class.name}: #{e.message}"[0, 300]))
          raise
        end
        record(service, operation, outcome ? outcome.call(result) : "ok", started, context)
        result
      end

      private

      def record(service, operation, outcome, started, fields)
        duration = monotonic - started
        @metrics.increment("external_calls_total", provider: service, kind: operation, outcome: outcome)
        @metrics.observe("external_call_duration_seconds", duration, provider: service, kind: operation)
        entry = { event: "external.call", service: service, operation: operation, outcome: outcome, duration_ms: (duration * 1000).round(1) }
        outcome == "ok" ? @logger.info(entry.merge(fields)) : @logger.warn(entry.merge(fields))
      end

      def monotonic = @clock.monotonic
    end
  end
end
