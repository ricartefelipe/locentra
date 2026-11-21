# frozen_string_literal: true

require "date"
require "tzinfo"

module Locentra
  module Domain
    # Fuso horário IANA da organização, usado para regras de calendário local.
    #
    # Política para horários locais:
    # - inexistentes (salto do horário de verão) são rejeitados com erro de validação;
    # - ambíguos (retorno do horário de verão) resolvem para a primeira ocorrência,
    #   ou seja, o instante UTC mais cedo.
    class TimeZone
      attr_reader :identifier

      LOCAL_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\z/

      # Fuso registrado num snapshot (por exemplo, o fuso com que uma reserva foi precificada); sem o
      # identificador, o fuso informado como alternativa (normalmente o atual da organização).
      def self.snapshot_or(identifier, fallback)
        identifier.to_s.empty? ? fallback : new(identifier)
      end

      def initialize(identifier)
        @identifier = identifier.to_s
        @zone = TZInfo::Timezone.get(@identifier)
        freeze
      rescue TZInfo::InvalidTimezoneIdentifier
        raise ValidationError.field("fuso_horario", "identificador IANA inválido")
      end

      # Converte data/hora local (sem offset) para instante UTC.
      def local_to_utc(year, month, day, hour = 0, minute = 0, second = 0)
        local = Time.utc(year, month, day, hour, minute, second)
        raise ValidationError.field("data", "data inexistente") unless local.year == year && local.month == month && local.day == day

        @zone.local_to_utc(local) { |periods| earliest(periods) }.utc
      rescue TZInfo::PeriodNotFound
        raise ValidationError.field("horario", "horário inexistente no fuso #{identifier} (mudança de horário)")
      rescue ArgumentError
        raise ValidationError.field("data", "data inválida")
      end

      # Interpreta "2026-03-01T08:00" (sem offset) no fuso da organização.
      def parse_local(text)
        match = LOCAL_PATTERN.match(text.to_s.strip)
        raise ValidationError.field("data_hora", "use o formato AAAA-MM-DDTHH:MM") unless match

        parts = match.captures.map { |value| value&.to_i }
        local_to_utc(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5] || 0)
      end

      def local_date(instant)
        local = @zone.to_local(instant)
        Date.new(local.year, local.month, local.day)
      end

      def to_local(instant)
        @zone.to_local(instant)
      end

      def utc_offset(instant)
        @zone.period_for(instant).utc_total_offset
      end

      # Instante UTC do início do dia local. Se a meia-noite não existir (salto de horário),
      # retorna o primeiro instante válido do dia.
      def start_of_day(date)
        (0..23).each do |hour|
          return @zone.local_to_utc(Time.utc(date.year, date.month, date.day, hour)) { |periods| earliest(periods) }.utc
        rescue TZInfo::PeriodNotFound
          next
        end
        raise InvariantViolation, "dia sem horário válido em #{identifier}"
      end

      # Datas locais tocadas pelo intervalo semiaberto [início, fim).
      def calendar_dates(period)
        first = local_date(period.starts_at)
        last = local_date(period.ends_at - 1)
        (first..last).to_a
      end

      def format_local(instant, pattern = "%d/%m/%Y %H:%M")
        to_local(instant).strftime(pattern)
      end

      def ==(other)
        other.is_a?(TimeZone) && other.identifier == identifier
      end

      private

      # Entre períodos candidatos de um horário ambíguo, o de maior offset produz o
      # instante UTC mais cedo (utc = local - offset).
      def earliest(periods)
        periods.max_by(&:utc_total_offset)
      end
    end
  end
end
