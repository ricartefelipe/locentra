# frozen_string_literal: true

require "date"
require "time"

module Locentra
  module Domain
    # Intervalo de tempo semiaberto [início, fim) em UTC, com precisão de segundos.
    #
    # Dois períodos adjacentes (fim de um igual ao início do outro) não se sobrepõem.
    # Frações de segundo são descartadas na construção para que comparações, chaves de
    # idempotência e representações no PostgreSQL sejam estáveis.
    class Period
      attr_reader :starts_at, :ends_at

      MAX_DURATION_SECONDS = 366 * 24 * 3600 * 3

      def self.parse(starts_at, ends_at)
        new(parse_instant(starts_at, "inicio"), parse_instant(ends_at, "fim"))
      end

      def self.parse_instant(value, field)
        return value if value.is_a?(Time)
        raise ValidationError.field(field, "obrigatório") if value.nil? || value.to_s.strip.empty?
        unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})\z/)
          raise ValidationError.field(field, "use ISO 8601 com fuso (ex.: 2026-03-01T08:00:00Z)")
        end

        year, month, day = value.to_s[0, 10].split("-").map(&:to_i)
        raise ValidationError.field(field, "data inexistente") unless Date.valid_date?(year, month, day)

        text = value.to_s.sub(/\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(Z|[+-])/, '\\1:00\\2')
        Time.iso8601(text)
      rescue ArgumentError
        raise ValidationError.field(field, "instante inválido")
      end

      def initialize(starts_at, ends_at)
        raise ArgumentError, "início deve ser Time" unless starts_at.is_a?(Time)
        raise ArgumentError, "fim deve ser Time" unless ends_at.is_a?(Time)

        @starts_at = Time.at(starts_at.to_i).utc
        @ends_at = Time.at(ends_at.to_i).utc
        raise ValidationError.field("periodo", "o fim deve ser posterior ao início") unless @ends_at > @starts_at
        raise ValidationError.field("periodo", "duração acima do limite permitido") if duration_seconds > MAX_DURATION_SECONDS

        freeze
      end

      def duration_seconds
        ends_at.to_i - starts_at.to_i
      end

      def overlaps?(other)
        starts_at < other.ends_at && other.starts_at < ends_at
      end

      def cover?(other)
        starts_at <= other.starts_at && other.ends_at <= ends_at
      end

      def include?(instant)
        starts_at <= instant && instant < ends_at
      end

      def intersection(other)
        return nil unless overlaps?(other)

        Period.new([starts_at, other.starts_at].max, [ends_at, other.ends_at].min)
      end

      # Expande o período pelos tempos de preparação anterior e posterior (em segundos).
      def expand(before: 0, after: 0)
        raise ArgumentError, "expansões não podem ser negativas" if before.negative? || after.negative?

        Period.new(starts_at - before, ends_at + after)
      end

      def with_end(new_end)
        Period.new(starts_at, new_end)
      end

      def ==(other)
        other.is_a?(Period) && starts_at == other.starts_at && ends_at == other.ends_at
      end
      alias eql? ==

      def hash
        [starts_at.to_i, ends_at.to_i].hash
      end

      # Literal tstzrange do PostgreSQL com limites [inclusivo, exclusivo).
      def to_pg_range
        "[#{starts_at.iso8601},#{ends_at.iso8601})"
      end

      def to_h
        { "starts_at" => starts_at.iso8601, "ends_at" => ends_at.iso8601 }
      end

      def to_s
        "[#{starts_at.iso8601}, #{ends_at.iso8601})"
      end
      alias inspect to_s
    end
  end
end
