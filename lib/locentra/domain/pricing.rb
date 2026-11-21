# frozen_string_literal: true

module Locentra
  module Domain
    # Precificação de locações. Semântica documentada em docs/PRECIFICACAO.md.
    #
    # - Hora: minutos cobráveis arredondados para cima em múltiplos de `rounding_minutes`, com
    #   tolerância `grace_minutes` sobre o excedente; limitado ao valor de uma diária, se houver.
    # - Diária 24 h (`rolling_24h`): blocos de 24 horas contados a partir da retirada.
    # - Dia de calendário (`calendar_day`): cada data local (fuso da organização) tocada pelo
    #   período conta um dia, independentemente da hora.
    # - Semana: blocos de 7 dias; o restante é cobrado em diárias, limitado a uma semana adicional.
    module Pricing
      DAILY_MODES = { "rolling_24h" => "Diária de 24 horas", "calendar_day" => "Dia de calendário" }.freeze
      DAY = 86_400

      module_function

      def integer!(value, field, min: 0, max: Money::MAX_CENTS, allow_nil: true)
        return nil if allow_nil && (value.nil? || value.to_s.strip.empty?)

        number = value.is_a?(Integer) ? value : Integer(value.to_s, 10)
        raise ValidationError.field(field, "entre #{min} e #{max}") unless number.between?(min, max)

        number
      rescue ArgumentError, TypeError
        raise ValidationError.field(field, "número inteiro")
      end

      # Tabela de preços de um produto (armazenada como snapshot JSON).
      PriceTable = Data.define(:hourly_cents, :daily_cents, :weekly_cents, :daily_mode, :minimum_minutes, :rounding_minutes,
                               :grace_minutes, :late_fee_multiplier_bps, :quantity_tiers) do
        def self.from_h(hash)
          data = (hash || {}).transform_keys(&:to_s)
          new(hourly_cents: Pricing.integer!(data["hourly_cents"], "preco_hora"),
              daily_cents: Pricing.integer!(data["daily_cents"], "preco_diaria"),
              weekly_cents: Pricing.integer!(data["weekly_cents"], "preco_semana"),
              daily_mode: daily_mode(data),
              minimum_minutes: Pricing.integer!(data["minimum_minutes"], "periodo_minimo", max: 43_200) || 0,
              rounding_minutes: rounding(data),
              grace_minutes: Pricing.integer!(data["grace_minutes"], "tolerancia", max: 240) || 0,
              late_fee_multiplier_bps: Pricing.integer!(data["late_fee_multiplier_bps"], "multa_atraso", max: 50_000) || 10_000,
              quantity_tiers: tiers(data))
        end

        def self.tiers(data)
          list = Array(data["quantity_tiers"]).map do |tier|
            tier = tier.transform_keys(&:to_s)
            { "min_quantity" => Pricing.integer!(tier["min_quantity"], "faixa_quantidade", min: 2, max: 100_000, allow_nil: false),
              "discount_bps" => Pricing.integer!(tier["discount_bps"], "faixa_desconto", min: 1, max: 9000, allow_nil: false) }
          end
          mins = list.map { |t| t["min_quantity"] }
          raise ValidationError.field("faixas", "quantidades mínimas repetidas") if mins.uniq.size != mins.size

          list.sort_by { |t| t["min_quantity"] }.freeze
        end

        def self.daily_mode(data)
          mode = (data["daily_mode"] || "rolling_24h").to_s
          raise ValidationError.field("modalidade_diaria", "inválida") unless DAILY_MODES.key?(mode)

          mode
        end

        def self.rounding(data)
          value = Pricing.integer!(data["rounding_minutes"], "arredondamento", min: 1, max: 1440) || 60
          raise ValidationError.field("arredondamento", "use 15, 30 ou 60 minutos") unless [15, 30, 60].include?(value)

          value
        end

        def priced? = [hourly_cents, daily_cents, weekly_cents].any?

        def to_h
          { "hourly_cents" => hourly_cents, "daily_cents" => daily_cents, "weekly_cents" => weekly_cents, "daily_mode" => daily_mode,
            "minimum_minutes" => minimum_minutes, "rounding_minutes" => rounding_minutes, "grace_minutes" => grace_minutes,
            "late_fee_multiplier_bps" => late_fee_multiplier_bps, "quantity_tiers" => quantity_tiers }.compact
        end

        def tier_discount_bps(quantity)
          quantity_tiers.select { |t| quantity >= t["min_quantity"] }.map { |t| t["discount_bps"] }.max || 0
        end
      end

      # Normalização usada pelo catálogo.
      class Rules
        def normalize(hash)
          table = PriceTable.from_h(hash)
          raise ValidationError.field("precos", "informe ao menos um preço (hora, diária ou semana)") if !hash.to_h.empty? && !table.priced?

          table.to_h
        end
      end

      # Preço de uma unidade de produto para um período, com descrição das unidades cobradas.
      Quote = Data.define(:amount, :units, :description)

      module Calculator
        module_function

        def unit_price(table, period, zone)
          raise ValidationError.field("precos", "produto sem tabela de preços") unless table.priced?

          billable = [period.duration_seconds, table.minimum_minutes * 60].max
          return hourly(table, billable) if table.hourly_cents && (billable < DAY || (table.daily_cents.nil? && table.weekly_cents.nil?))

          days = billable_days(table, period, billable, zone)
          daily_or_weekly(table, days)
        end

        def billable_days(table, period, billable, zone)
          grace = table.grace_minutes * 60
          if table.daily_mode == "calendar_day"
            dates = zone.calendar_dates(period)
            last_start = zone.start_of_day(dates.last)
            dates.pop if dates.size > 1 && period.ends_at.to_i - last_start.to_i <= grace
            [dates.size, ceil_div(table.minimum_minutes * 60, DAY)].max
          else
            [ceil_div([billable - grace, 1].max, DAY), 1].max
          end
        end

        def hourly(table, billable_seconds)
          minutes = ceil_div(billable_seconds, 60)
          step = table.rounding_minutes
          blocks, remainder = minutes.divmod(step)
          blocks += 1 if remainder > table.grace_minutes || blocks.zero?
          charged = blocks * step
          amount = Money.new(table.hourly_cents) * Rational(charged, 60)
          if table.daily_cents && amount.cents > table.daily_cents
            return Quote.new(amount: Money.new(table.daily_cents), units: { "days" => 1 }, description: "1 diária (teto do valor por hora)")
          end

          Quote.new(amount: amount, units: { "minutes" => charged }, description: hours_label(charged))
        end

        def daily_or_weekly(table, days)
          if table.weekly_cents && table.daily_cents
            weeks, rest = days.divmod(7)
            rest_amount = [rest * table.daily_cents, table.weekly_cents].min
            amount = Money.new((weeks * table.weekly_cents) + rest_amount)
            Quote.new(amount: amount, units: { "days" => days, "weeks" => weeks, "rest_days" => rest },
                      description: week_label(weeks, rest, table, rest_amount == table.weekly_cents && rest.positive?))
          elsif table.weekly_cents
            weeks = ceil_div(days, 7)
            Quote.new(amount: Money.new(weeks * table.weekly_cents), units: { "weeks" => weeks },
                      description: plural(weeks, "semana", "semanas"))
          elsif table.daily_cents
            label = if table.daily_mode == "calendar_day"
                      plural(days, "dia de calendário",
                             "dias de calendário")
                    else
                      plural(days, "diária (24 h)", "diárias (24 h)")
                    end
            Quote.new(amount: Money.new(days * table.daily_cents), units: { "days" => days }, description: label)
          else
            hours = days * 24 * 60
            Quote.new(amount: Money.new(table.hourly_cents) * Rational(hours, 60), units: { "minutes" => hours },
                      description: hours_label(hours))
          end
        end

        def ceil_div(value, divisor) = -(-value / divisor)

        def plural(count, one, many) = "#{count} #{count == 1 ? one : many}"

        def hours_label(minutes)
          hours, mins = minutes.divmod(60)
          mins.zero? ? plural(hours, "hora", "horas") : "#{hours}h#{format("%02d", mins)}"
        end

        def week_label(weeks, rest, _table, capped)
          parts = []
          parts << plural(weeks, "semana", "semanas") if weeks.positive?
          parts << (capped ? "1 semana adicional (teto)" : plural(rest, "diária", "diárias")) if rest.positive?
          parts.join(" + ")
        end
      end

      # Linha precificada: preço unitário do período × quantidade, faixa por quantidade e condição
      # negociada do cliente aplicadas nesta ordem, com arredondamento por etapa.
      module Line
        module_function

        def price(table:, period:, zone:, quantity:, negotiated_bps: 0)
          quote = Calculator.unit_price(table, period, zone)
          gross = quote.amount * quantity
          tier_bps = table.tier_discount_bps(quantity)
          after_tier = gross - gross.percent(tier_bps)
          negotiated = after_tier.percent(negotiated_bps)
          total = after_tier - negotiated
          {
            "table" => table.to_h, "description" => quote.description, "units" => quote.units, "quantity" => quantity,
            "unit_amount_cents" => quote.amount.cents, "gross_cents" => gross.cents, "tier_discount_bps" => tier_bps,
            "tier_discount_cents" => (gross - after_tier).cents, "negotiated_discount_bps" => negotiated_bps,
            "negotiated_discount_cents" => negotiated.cents, "total_cents" => total.cents
          }
        end
      end

      COUPON_REJECTIONS = { "inactive" => "cupom desativado", "expired" => "cupom expirado", "scheduled" => "cupom ainda não está vigente",
                            "exhausted" => "cupom esgotado" }.freeze

      # Cupom de desconto aplicado sobre o subtotal. `redemptions` são os usos ativos (contador legado
      # da 1.0.0 mais os usos ativos do livro), calculados pelo repositório; `legacy_redemptions` é o
      # contador congelado e `total_redemptions`, todos os usos já registrados (legado e livro).
      Coupon = Data.define(:code, :kind, :value, :valid_from, :valid_until, :max_redemptions, :redemptions, :min_subtotal_cents, :active,
                           :id, :organization_id, :description, :created_by, :created_at, :updated_at, :deactivated_at,
                           :lock_version, :total_redemptions, :legacy_redemptions) do
        def initialize(id: nil, organization_id: nil, description: nil, created_by: nil, created_at: nil, updated_at: nil,
                       deactivated_at: nil, lock_version: 1, total_redemptions: nil, legacy_redemptions: 0, **)
          super
        end

        # Precedência: desativado > expirado > agendado > esgotado > vigente. Vigência semiaberta [início, fim).
        def status(now)
          if !active then "inactive"
          elsif valid_until && valid_until <= now then "expired"
          elsif valid_from && valid_from > now then "scheduled"
          elsif max_redemptions && redemptions >= max_redemptions then "exhausted"
          else "active"
          end
        end

        def rejection(subtotal, now)
          reason = COUPON_REJECTIONS[status(now)]
          return reason if reason
          return nil if subtotal.cents >= min_subtotal_cents.to_i

          "subtotal abaixo do mínimo do cupom (#{Money.new(min_subtotal_cents.to_i).format_brl})"
        end

        def applicable?(subtotal, now) = rejection(subtotal, now).nil?

        def remaining = max_redemptions && [max_redemptions - redemptions, 0].max

        # Texto único de usos para web, CLI e testes: "3 de 100" ou "3 (sem limite)".
        def usage_text
          used = Pricing.count_label(redemptions)
          max_redemptions ? "#{used} de #{Pricing.count_label(max_redemptions)}" : "#{used} (sem limite)"
        end

        def discount(subtotal)
          amount = kind == "percent" ? subtotal.percent(value) : Money.new(value)
          amount.min(subtotal)
        end

        def to_snapshot
          { "id" => id, "code" => code, "kind" => kind, "value" => value, "description" => description,
            "valid_from" => valid_from&.getutc&.iso8601, "valid_until" => valid_until&.getutc&.iso8601 }
        end
      end

      # Inteiro com separador de milhar: 1000000 → "1.000.000".
      def count_label(number) = number.to_s.reverse.scan(/\d{1,3}/).join(".").reverse

      # Composição do total: subtotal das linhas, cupom, desconto manual autorizado e tarifas.
      module Totals
        module_function

        def compose(lines:, fees: [], coupon: nil, manual_discount_bps: 0, discount_limit_bps: 0, now: nil, deposit: Money.zero)
          if manual_discount_bps.positive? && manual_discount_bps > discount_limit_bps
            raise AccessDenied, "desconto manual acima do limite autorizado para o papel (#{Percent.label(discount_limit_bps)})"
          end
          raise ValidationError.field("desconto", "entre 0 e 100%") unless manual_discount_bps.between?(0, 10_000)

          subtotal = Money.new(lines.sum { |l| l.fetch("total_cents") })
          coupon_discount = Money.zero
          if coupon
            reason = coupon.rejection(subtotal, now)
            raise ValidationError.field("cupom", reason) if reason

            coupon_discount = coupon.discount(subtotal)
          end
          after_coupon = subtotal - coupon_discount
          manual = after_coupon.percent(manual_discount_bps)
          fee_total = Money.new(fees.sum { |f| f.fetch("amount_cents") })
          total = after_coupon - manual + fee_total
          {
            "subtotal_cents" => subtotal.cents, "coupon_code" => coupon&.code, "coupon_discount_cents" => coupon_discount.cents,
            "manual_discount_bps" => manual_discount_bps, "manual_discount_cents" => manual.cents, "fees" => fees,
            "fees_cents" => fee_total.cents, "total_cents" => total.cents, "deposit_cents" => deposit.cents
          }
        end

        def fee!(description, amount)
          raise ValidationError.field("tarifa", "valor deve ser positivo") unless amount.positive?

          { "description" => Organizations::Text.required(description, "descricao_tarifa", max: 120), "amount_cents" => amount.cents }
        end
      end

      # Multa por atraso: tempo excedente após a tolerância, cobrado pela tabela do snapshot com o
      # multiplicador configurado (padrão 100%).
      module LateFee
        module_function

        def calculate(table:, scheduled_end:, returned_at:, quantity:, zone:)
          late_seconds = returned_at.to_i - scheduled_end.to_i - (table.grace_minutes * 60)
          return Money.zero unless late_seconds.positive?

          late = Period.new(scheduled_end, scheduled_end + late_seconds)
          no_minimum = table.with(minimum_minutes: 0, grace_minutes: 0)
          base = Calculator.unit_price(no_minimum, late, zone).amount * quantity
          base.percent(table.late_fee_multiplier_bps)
        end
      end

      # Ajuste de extensão: diferença entre o preço do novo período e o valor original, sempre
      # calculada com o snapshot da tabela contratada.
      module Extension
        module_function

        def adjustment(line_snapshot:, new_period:, zone:)
          table = PriceTable.from_h(line_snapshot.fetch("table"))
          repriced = Line.price(table: table, period: new_period, zone: zone, quantity: line_snapshot.fetch("quantity"),
                                negotiated_bps: line_snapshot.fetch("negotiated_discount_bps", 0))
          delta = repriced.fetch("total_cents") - line_snapshot.fetch("total_cents")
          [Money.new([delta, 0].max), repriced]
        end
      end
    end
  end
end
