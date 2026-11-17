# frozen_string_literal: true

require "bigdecimal"

module Locentra
  module Domain
    # Valor monetário representado em centavos inteiros. Nunca utiliza Float.
    #
    # Arredondamento padrão: meio para cima (ROUND_HALF_UP), aplicado somente quando uma
    # operação produz frações de centavo (percentuais, rateios proporcionais).
    class Money
      include Comparable

      SUPPORTED_CURRENCIES = %w[BRL].freeze
      MAX_CENTS = 999_999_999_999 # teto defensivo: 9.999.999.999,99
      DECIMAL_PATTERN = /\A-?\d{1,13}(?:[.,]\d{1,2})?\z/

      attr_reader :cents, :currency

      def self.zero(currency = "BRL")
        new(0, currency)
      end

      # Aceita "1234.56", "1234,56" ou "1.234,56". Rejeita mais de duas casas decimais.
      def self.parse(value, currency = "BRL")
        text = value.to_s.strip
        text = text.delete(".").tr(",", ".") if text.match?(/\A-?\d{1,3}(?:\.\d{3})+,\d{1,2}\z/)
        raise ValidationError.field("valor", "formato monetário inválido") unless text.match?(DECIMAL_PATTERN)

        decimal = BigDecimal(text.tr(",", "."))
        new((decimal * 100).to_i, currency)
      end

      def self.sum(values, currency = "BRL")
        values.sum(zero(currency))
      end

      def initialize(cents, currency = "BRL")
        raise ArgumentError, "centavos devem ser Integer" unless cents.is_a?(Integer)
        raise ArgumentError, "moeda não suportada: #{currency}" unless SUPPORTED_CURRENCIES.include?(currency)
        raise ValidationError.field("valor", "fora do limite permitido") if cents.abs > MAX_CENTS

        @cents = cents
        @currency = currency
        freeze
      end

      def +(other)
        same_currency!(other)
        Money.new(cents + other.cents, currency)
      end

      def -(other)
        same_currency!(other)
        Money.new(cents - other.cents, currency)
      end

      def -@
        Money.new(-cents, currency)
      end

      # Multiplica por um fator inteiro ou racional. Fatores Float são rejeitados.
      def *(other)
        case other
        when Integer then Money.new(cents * other, currency)
        when Rational, BigDecimal then Money.new(self.class.round_half_up(Rational(cents) * Rational(other)), currency)
        else raise ArgumentError, "fator inválido para dinheiro: #{other.class}"
        end
      end

      # Aplica percentual expresso em pontos-base (1% = 100 bps).
      def percent(basis_points)
        raise ArgumentError, "pontos-base devem ser Integer" unless basis_points.is_a?(Integer)

        self * Rational(basis_points, 10_000)
      end

      # Rateia o valor proporcionalmente aos pesos, preservando a soma exata (maior resto).
      def allocate(weights)
        validate_weights!(weights)
        total_weight = weights.sum
        return weights.map { Money.zero(currency) } if total_weight.zero?

        sign = cents.negative? ? -1 : 1
        magnitude = cents.abs
        shares = weights.map { |w| Rational(magnitude * w, total_weight) }
        floors = shares.map(&:floor)
        remainder = magnitude - floors.sum
        order = shares.each_with_index.sort_by { |share, index| [-(share - share.floor), index] }.map(&:last)
        order.first(remainder).each { |index| floors[index] += 1 }
        floors.map { |value| Money.new(sign * value, currency) }
      end

      def <=>(other)
        return nil unless other.is_a?(Money) && other.currency == currency

        cents <=> other.cents
      end

      def eql?(other)
        other.is_a?(Money) && cents == other.cents && currency == other.currency
      end
      alias == eql?

      def hash
        [cents, currency].hash
      end

      def zero? = cents.zero?
      def positive? = cents.positive?
      def negative? = cents.negative?

      def abs
        Money.new(cents.abs, currency)
      end

      def min(other) = [self, other].min
      def max(other) = [self, other].max

      # Representação decimal exata com ponto: "1234.56".
      def to_decimal_string
        sign = cents.negative? ? "-" : ""
        whole, fraction = cents.abs.divmod(100)
        format("%<sign>s%<whole>d.%<fraction>02d", sign: sign, whole: whole, fraction: fraction)
      end

      # Formato brasileiro para exibição: "R$ 1.234,56".
      def format_brl
        sign = cents.negative? ? "-" : ""
        whole, fraction = cents.abs.divmod(100)
        grouped = whole.to_s.reverse.scan(/\d{1,3}/).join(".").reverse
        "#{sign}R$ #{grouped},#{format("%02d", fraction)}"
      end
      alias to_s format_brl

      def to_h
        { "amount_cents" => cents, "currency" => currency, "formatted" => format_brl }
      end

      def inspect
        "#<Money #{to_decimal_string} #{currency}>"
      end

      def self.round_half_up(rational)
        value = Rational(rational)
        rounded = (value.abs + Rational(1, 2)).floor
        value.negative? ? -rounded : rounded
      end

      private

      def validate_weights!(weights)
        raise ArgumentError, "pesos vazios" if weights.empty?
        raise ArgumentError, "pesos devem ser inteiros não negativos" unless weights.all? { |w| w.is_a?(Integer) && w >= 0 }
      end

      def same_currency!(other)
        raise ArgumentError, "operação exige Money" unless other.is_a?(Money)
        raise ArgumentError, "moedas diferentes: #{currency} e #{other.currency}" unless other.currency == currency
      end
    end
  end
end
