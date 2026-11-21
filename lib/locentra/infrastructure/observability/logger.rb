# frozen_string_literal: true

require "json"
require "logger"

module Locentra
  module Infrastructure
    module Observability
      # Logger estruturado (JSON por linha) com redação de campos sensíveis: valores de chaves com nome
      # sensível são substituídos, e senhas em URLs (postgres://usuario:senha@...) ou em parâmetros de
      # conexão (password=...) são mascaradas em qualquer texto, inclusive mensagens de erro.
      class StructuredLogger
        LEVELS = { "debug" => 0, "info" => 1, "warn" => 2, "error" => 3 }.freeze
        SENSITIVE = /pass(word)?|senha|token|secret|segredo|authorization|cookie|csrf|api[_-]?key|card|cvv|(?:\A|_)pan(?:_|\z)|access[_-]?token/i
        URL_PASSWORD = %r{(\b[a-z][a-z0-9+.-]*://[^/\s:@]*):[^@\s/]*@}i
        CONNINFO_PASSWORD = /\bpassword\s*=\s*('[^']*'|\S+)/i
        REDACTED = "[REDACTED]"

        def initialize(io: $stdout, level: "info", base: {})
          @io = io
          @level = LEVELS.fetch(level.to_s, 1)
          @base = base
          @mutex = Thread::Mutex.new
        end

        def debug(fields) = log("debug", fields)
        def info(fields) = log("info", fields)
        def warn(fields) = log("warn", fields)
        def error(fields) = log("error", fields)

        def with(fields)
          StructuredLogger.new(io: @io, level: LEVELS.key(@level), base: @base.merge(fields))
        end

        def self.redact(value, key = nil)
          return REDACTED if key&.to_s&.match?(SENSITIVE)

          case value
          when Hash then value.to_h { |k, v| [k, redact(v, k)] }
          when Array then value.map { |v| redact(v) }
          when String then scrub(value.length > 4000 ? "#{value[0, 4000]}…" : value)
          else value
          end
        end

        def self.scrub(text)
          return text unless text.include?("@") || text.match?(/password/i)

          text.gsub(URL_PASSWORD, "\\1:#{REDACTED}@").gsub(CONNINFO_PASSWORD, "password=#{REDACTED}")
        end

        private

        def log(level, fields)
          return if LEVELS.fetch(level) < @level

          payload = { "ts" => Time.now.utc.iso8601(3), "level" => level }.merge(self.class.redact(@base.merge(fields)))
          write(JSON.generate(payload))
        rescue StandardError => e
          write(JSON.generate("level" => "error", "event" => "log.failure", "error" => e.class.name))
        end

        # Cada linha é descarregada na hora: fora de um terminal (contêiner, pipe, arquivo) o Ruby acumula a saída
        # em buffer, e o log do worker só apareceria quando o buffer enchesse ou o processo terminasse.
        def write(line)
          @mutex.synchronize do
            @io.puts(line)
            @io.flush
          end
        end
      end

      # Registro de métricas em memória do processo, exposto no formato texto do Prometheus (0.0.4),
      # com linhas HELP/TYPE por família.
      #
      # Rótulos restritos a valores de baixa cardinalidade (rota modelo, método, situação, tipo de
      # tarefa, provedor, código de conflito): nomes fora de ALLOWED_LABELS são descartados e valores
      # com formato de identificador (UUID ou sequência hexadecimal longa) são substituídos por
      # "redacted". Identificadores de organizações, clientes ou reservas nunca viram série temporal.
      class Metrics
        BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10].freeze
        ALLOWED_LABELS = %w[method route status pool reason kind outcome provider queue code].freeze
        IDENTIFIER = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|\h{16,}/
        REDACTED_LABEL = "redacted"
        HELP = {
          "http_requests_total" => "Requisições HTTP por método, rota modelo e status",
          "http_request_duration_seconds" => "Latência das requisições HTTP por rota modelo",
          "db_pool_wait_seconds" => "Espera por conexão do pool de banco",
          "db_pool_timeouts_total" => "Esperas por conexão do pool que excederam o tempo limite",
          "db_transaction_retries_total" => "Transações repetidas por deadlock ou falha de serialização",
          "domain_conflicts_total" => "Operações recusadas por conflito com o estado atual, por código (disponibilidade, concorrência)",
          "jobs_queue_size" => "Tarefas por fila e situação (agregado gravado pelo worker)",
          "jobs_oldest_age_seconds" => "Idade da tarefa mais antiga já liberada para execução, por fila e situação",
          "jobs_queue_stats_age_seconds" => "Tempo desde a última atualização dos agregados da fila pelo worker",
          "metrics_collect_success" => "1 se a última coleta das métricas derivadas do banco teve sucesso, 0 caso contrário",
          "jobs_retries_total" => "Reagendamentos de tarefas após falha, somados entre todos os workers",
          "jobs_dead_total" => "Tarefas encerradas sem novas tentativas (falha permanente), somadas entre todos os workers",
          "job_duration_seconds" => "Duração da execução de tarefas no processo do worker",
          "external_calls_total" => "Chamadas a sistemas externos por provedor, operação e desfecho",
          "external_call_duration_seconds" => "Duração das chamadas a sistemas externos por provedor e operação",
          "webhook_deliveries_total" =>
            "Entregas de webhook por desfecho (entregue, falha, retida por pausa, liberada), somadas entre todos os workers",
          "webhook_endpoint_pauses_total" => "Pausas automáticas de endpoints de webhook por falhas consecutivas",
          "retention_purged_total" => "Registros removidos pela retenção, por tipo de registro"
        }.freeze

        def initialize
          @mutex = Thread::Mutex.new
          @counters = Hash.new(0)
          @histograms = {}
          @gauges = {}
        end

        def increment(name, by = 1, **labels)
          key = [name, normalize(labels)]
          @mutex.synchronize { @counters[key] += by }
        end

        # Contador cujo total é mantido fora do processo (por exemplo, somado no banco por todos os
        # workers): o valor informado substitui o anterior.
        def set_counter(name, value, **labels)
          key = [name, normalize(labels)]
          @mutex.synchronize { @counters[key] = value }
        end

        def observe(name, value, **labels)
          key = [name, normalize(labels)]
          @mutex.synchronize do
            histogram = (@histograms[key] ||= { buckets: Array.new(BUCKETS.size, 0), sum: 0.0, count: 0 })
            BUCKETS.each_with_index { |bound, i| histogram[:buckets][i] += 1 if value <= bound }
            histogram[:sum] += value
            histogram[:count] += 1
          end
        end

        def gauge(name, value, **labels)
          @mutex.synchronize { @gauges[[name, normalize(labels)]] = value }
        end

        # Substitui todas as séries de um gauge: séries que deixaram de existir não continuam expostas
        # com o último valor. `series` é uma lista de pares [valor, rótulos].
        def replace_gauges(name, series)
          entries = series.map { |value, labels| [[name, normalize(labels)], value] }
          @mutex.synchronize do
            @gauges.delete_if { |(gauge_name, _), _| gauge_name == name }
            entries.each { |key, value| @gauges[key] = value }
          end
        end

        def counter_value(name, **labels)
          @mutex.synchronize { @counters[[name, normalize(labels)]] }
        end

        def render
          lines = []
          @mutex.synchronize do
            families(@counters, "counter", lines) { |name, labels, value| lines << sample(name, labels, value) }
            families(@gauges, "gauge", lines) { |name, labels, value| lines << sample(name, labels, value) }
            families(@histograms, "histogram", lines) { |name, labels, histogram| histogram_lines(lines, name, labels, histogram) }
          end
          "#{lines.join("\n")}\n"
        end

        private

        # Séries agrupadas por nome, com HELP/TYPE antes das amostras de cada família.
        def families(store, type, lines)
          store.group_by { |(name, _), _| name }.sort_by(&:first).each do |name, series|
            lines << "# HELP locentra_#{name} #{HELP[name]}" if HELP.key?(name)
            lines << "# TYPE locentra_#{name} #{type}"
            series.sort_by { |(_, labels), _| labels.to_a }.each { |(_, labels), value| yield name, labels, value }
          end
        end

        def histogram_lines(lines, name, labels, histogram)
          BUCKETS.each_with_index do |bound, i|
            lines << sample("#{name}_bucket", labels.merge("le" => bound.to_s), histogram[:buckets][i])
          end
          lines << sample("#{name}_bucket", labels.merge("le" => "+Inf"), histogram[:count])
          lines << sample("#{name}_sum", labels, histogram[:sum].round(6))
          lines << sample("#{name}_count", labels, histogram[:count])
        end

        def sample(name, labels, value) = "locentra_#{name}#{format_labels(labels)} #{value}"

        def normalize(labels)
          labels.to_h { |k, v| [k.to_s, label_value(v)] }.slice(*ALLOWED_LABELS).sort.to_h
        end

        def label_value(value)
          text = value.to_s
          text.match?(IDENTIFIER) ? REDACTED_LABEL : text[0, 80]
        end

        def format_labels(labels)
          return "" if labels.empty?

          "{#{labels.map { |k, v| "#{k}=\"#{v.gsub(/["\\\n]/) { |c| c == "\n" ? '\\n' : "\\#{c}" }}\"" }.join(",")}}"
        end
      end
    end
  end
end
