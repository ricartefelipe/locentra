# frozen_string_literal: true

require "json"
require "logger"

module Locentra
  module Infrastructure
    module Observability
      # Logger estruturado (JSON por linha) com redação de campos sensíveis.
      class StructuredLogger
        LEVELS = { "debug" => 0, "info" => 1, "warn" => 2, "error" => 3 }.freeze
        SENSITIVE = /pass(word)?|senha|token|secret|segredo|authorization|cookie|csrf|api[_-]?key|card|cvv|pan|access[_-]?token/i
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
          when String then value.length > 4000 ? "#{value[0, 4000]}…" : value
          else value
          end
        end

        private

        def log(level, fields)
          return if LEVELS.fetch(level) < @level

          payload = { "ts" => Time.now.utc.iso8601(3), "level" => level }.merge(self.class.redact(@base.merge(fields)))
          line = JSON.generate(payload)
          @mutex.synchronize { @io.puts(line) }
        rescue StandardError => e
          @mutex.synchronize { @io.puts(JSON.generate("level" => "error", "event" => "log.failure", "error" => e.class.name)) }
        end
      end

      # Registro de métricas em memória do processo, exposto no formato texto do Prometheus.
      # Labels são restritos a valores de baixa cardinalidade (rota modelo, método, status, tipo).
      class Metrics
        BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10].freeze
        ALLOWED_LABELS = %w[method route status pool reason kind outcome provider queue code].freeze

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

        def counter_value(name, **labels)
          @mutex.synchronize { @counters[[name, normalize(labels)]] }
        end

        def render
          lines = []
          @mutex.synchronize do
            counters = @counters.sort_by { |k, _| k.to_s }
            counters.each { |(name, labels), value| lines << "locentra_#{name}#{format_labels(labels)} #{value}" }
            @gauges.sort_by { |k, _| k.to_s }.each { |(name, labels), value| lines << "locentra_#{name}#{format_labels(labels)} #{value}" }
            @histograms.sort_by { |k, _| k.to_s }.each do |(name, labels), h|
              BUCKETS.each_with_index do |bound, i|
                lines << "locentra_#{name}_bucket#{format_labels(labels.merge("le" => bound.to_s))} #{h[:buckets][i]}"
              end
              lines << "locentra_#{name}_bucket#{format_labels(labels.merge("le" => "+Inf"))} #{h[:count]}"
              lines << "locentra_#{name}_sum#{format_labels(labels)} #{h[:sum].round(6)}"
              lines << "locentra_#{name}_count#{format_labels(labels)} #{h[:count]}"
            end
          end
          "#{lines.join("\n")}\n"
        end

        private

        def normalize(labels)
          labels.to_h { |k, v| [k.to_s, v.to_s[0, 80]] }.slice(*ALLOWED_LABELS).sort.to_h
        end

        def format_labels(labels)
          return "" if labels.empty?

          "{#{labels.map { |k, v| "#{k}=\"#{v.gsub(/["\\\n]/) { |c| c == "\n" ? '\\n' : "\\#{c}" }}\"" }.join(",")}}"
        end
      end
    end
  end
end
