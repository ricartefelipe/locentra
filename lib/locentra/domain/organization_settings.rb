# frozen_string_literal: true

module Locentra
  module Domain
    module Organizations
      # Configurações da organização gravadas em `organizations.settings`: validade padrão do bloqueio
      # temporário e política de cancelamento. Só se gravam chaves com valor diferente do padrão; chaves
      # desconhecidas são preservadas. O fuso horário é uma coluna própria, escolhido entre os fusos do
      # Brasil (o fuso atual é sempre aceito, mesmo fora da lista).
      module Settings
        DEFAULT_HOLD_MINUTES = 30
        # Campos acompanhados na revisão e na auditoria, na ordem de Organization#effective.
        TRACKED = %w[name timezone hold_minutes cancellation_policy].freeze

        TIME_ZONES = {
          "America/Noronha" => "Fernando de Noronha",
          "America/Belem" => "Belém (leste do PA, AP)",
          "America/Fortaleza" => "Fortaleza (CE, RN, PB, MA, PI)",
          "America/Recife" => "Recife (PE)",
          "America/Araguaina" => "Araguaína (TO)",
          "America/Maceio" => "Maceió (AL, SE)",
          "America/Bahia" => "Salvador (BA)",
          "America/Sao_Paulo" => "Brasília (SP, RJ, MG, ES, PR, SC, RS, GO, DF)",
          "America/Campo_Grande" => "Campo Grande (MS)",
          "America/Cuiaba" => "Cuiabá (MT)",
          "America/Santarem" => "Santarém (oeste do PA)",
          "America/Porto_Velho" => "Porto Velho (RO)",
          "America/Boa_Vista" => "Boa Vista (RR)",
          "America/Manaus" => "Manaus (leste do AM)",
          "America/Eirunepe" => "Eirunepé (oeste do AM)",
          "America/Rio_Branco" => "Rio Branco (AC)"
        }.freeze

        module_function

        def zone_label(identifier) = TIME_ZONES.fetch(identifier.to_s, identifier.to_s)

        # Fuso escolhido no formulário: um da lista ou o atual da organização.
        def timezone!(value, current:)
          text = value.to_s.strip
          raise ValidationError.field("fuso_horario", "obrigatório") if text.empty?
          raise ValidationError.field("fuso_horario", "escolha um fuso horário da lista") unless TIME_ZONES.key?(text) || text == current

          TimeZone.new(text).identifier
        end

        # Mesmo intervalo do motor de reservas (5 a 1440 minutos), com erro em `validade_bloqueio`.
        def hold_minutes!(value) = Reservations::Rules.hold_minutes!(value)

        # Configurações gravadas: a chave é removida quando o valor é o padrão.
        def store(settings, hold_minutes:, cancellation_policy:)
          stored = settings.to_h.dup
          if hold_minutes == DEFAULT_HOLD_MINUTES then stored.delete("hold_minutes")
          else stored["hold_minutes"] = hold_minutes
          end
          if CancellationPolicy.default?(cancellation_policy) then stored.delete("cancellation_policy")
          else stored["cancellation_policy"] = cancellation_policy
          end
          stored
        end
      end

      # Política de cancelamento: percentual retido conforme a antecedência em relação ao início. Forma
      # canônica `{"tiers" => [...]}`, ordenada por antecedência decrescente, com inteiros: de 1 a 6 faixas,
      # antecedência de 0 a 8760 horas sem repetição, uma faixa de 0 h e multa (pontos-base, 0 a 10000) que
      # não diminui à medida que a antecedência cai.
      module CancellationPolicy
        DEFAULT = {
          "tiers" => [
            { "min_hours_before" => 72, "fee_bps" => 0 },
            { "min_hours_before" => 24, "fee_bps" => 3000 },
            { "min_hours_before" => 0, "fee_bps" => 10_000 }
          ]
        }.freeze
        MAX_TIERS = 6
        MAX_HOURS_BEFORE = 8_760
        MAX_FEE_BPS = 10_000
        FIELD = "faixas_cancelamento"
        # Prefixo das mensagens de uma faixa ("faixa 2: "), usado também para marcar a linha com erro.
        LINE_PREFIX = "faixa %<number>d: "
        HOURS_TEXT = /\A\d{1,4}\z/
        # Valor já recusado na conversão do formulário (a mensagem de formato já foi registrada).
        INVALID = Object.new.freeze

        module_function

        # Política canônica a partir das faixas ou ValidationError com todas as mensagens em `faixas_cancelamento`:
        # primeiro as de cada faixa, na ordem recebida, depois as gerais.
        def build(tiers)
          entries = Array(tiers).map do |tier|
            data = tier.is_a?(Hash) ? tier : {}
            { hours: data["min_hours_before"], fee: data["fee_bps"], messages: [] }
          end
          evaluate(entries)
        end

        # Faixas em pontos-base (formato da API e de `GET /organization`): lista de objetos com
        # `min_hours_before` e `fee_bps` inteiros. Os limites e as mensagens são os de `build`; outro formato
        # é recusado antes da avaliação das faixas.
        def from_tiers(tiers)
          unless tiers.is_a?(Array) && tiers.all?(Hash)
            raise ValidationError.new({ FIELD => ["informe as faixas como uma lista de objetos com min_hours_before e fee_bps"] })
          end

          build(tiers)
        end

        # Linhas do formulário ([antecedência, multa] em texto, alinhadas). Linhas vazias são descartadas; a
        # posição N das mensagens é a da lista compactada, a mesma das linhas reexibidas com erro.
        def from_form(rows)
          filled = compact_rows(rows)
          raise ValidationError.field(FIELD, "no máximo #{MAX_TIERS} faixas") if filled.size > MAX_TIERS

          evaluate(filled.map { |hours, fee| form_entry(hours.to_s.strip, fee.to_s.strip) })
        end

        def compact_rows(rows) = Array(rows).reject { |hours, fee| hours.to_s.strip.empty? && fee.to_s.strip.empty? }

        def line_prefix(number) = format(LINE_PREFIX, number: number)

        def line_messages(messages, number)
          prefix = line_prefix(number)
          Array(messages).select { |message| message.start_with?(prefix) }
        end

        def valid?(policy)
          policy.is_a?(Hash) && build(policy["tiers"]) == policy
        rescue ValidationError
          false
        end

        def default?(policy) = canonical(policy) == DEFAULT

        # Forma canônica de uma política gravada; a que não cumpre as regras atuais é devolvida como está.
        def canonical(policy)
          policy.is_a?(Hash) ? build(policy["tiers"]) : policy
        rescue ValidationError
          policy
        end

        # Retorna a multa em pontos-base para cancelamento em `now` de uma locação iniciando em `starts_at`.
        def fee_bps(policy, starts_at:, now:)
          hours_before = Rational(starts_at.to_i - now.to_i, 3600)
          tiers = sorted(policy)
          tier = tiers.find { |candidate| hours_before >= candidate.fetch("min_hours_before") } || tiers.last
          tier.fetch("fee_bps")
        end

        # Descrição legível das faixas, da maior para a menor antecedência.
        def describe(policy)
          tiers = sorted(policy)
          if tiers.size == 1 && tiers.first.fetch("min_hours_before").zero?
            return ["em qualquer momento (antes ou após o início): multa de #{Percent.label(tiers.first.fetch("fee_bps"))} do valor contratado"]
          end

          tiers.each_with_index.map do |tier, index|
            min = tier.fetch("min_hours_before")
            upper = index.zero? ? nil : tiers[index - 1].fetch("min_hours_before")
            range = if upper.nil? then "#{min} h ou mais antes do início"
                    elsif min.zero? then "menos de #{upper} h antes do início (ou após o início)"
                    else "de #{min} h a menos de #{upper} h antes do início"
                    end
            "#{range}: multa de #{Percent.label(tier.fetch("fee_bps"))} do valor contratado"
          end
        end

        # Textos curtos de cada faixa para a tabela da pré-visualização.
        def ranges(policy)
          tiers = sorted(policy)
          return ["qualquer antecedência"] if tiers.size == 1 && tiers.first.fetch("min_hours_before").zero?

          tiers.each_with_index.map do |tier, index|
            min = tier.fetch("min_hours_before")
            upper = index.zero? ? nil : tiers[index - 1].fetch("min_hours_before")
            if upper.nil? then "#{min} h ou mais"
            elsif min.zero? then "menos de #{upper} h ou após o início"
            else "de #{min} h a menos de #{upper} h"
            end
          end
        end

        # Multa de cada faixa sobre um valor de exemplo (aritmética inteira de Money).
        def examples(policy, base: Money.new(100_000))
          ranges(policy).zip(sorted(policy)).map do |range, tier|
            { "range" => range, "fee_bps" => tier.fetch("fee_bps"), "fee" => base.percent(tier.fetch("fee_bps")) }
          end
        end

        def sorted(policy) = policy.fetch("tiers").sort_by { |tier| -tier.fetch("min_hours_before") }

        def form_entry(hours, fee)
          return { hours: INVALID, fee: INVALID, messages: ["informe antecedência e multa"] } if hours.empty? || fee.empty?

          messages = []
          hours_value = hours.match?(HOURS_TEXT) ? Integer(hours, 10) : INVALID
          messages << hours_message if hours_value.equal?(INVALID)
          fee_value = begin
            Percent.parse(fee, FIELD)
          rescue ValidationError
            messages << "multa inválida (use até duas casas decimais)"
            INVALID
          end
          { hours: hours_value, fee: fee_value, messages: messages }
        end

        def hours_message = "antecedência deve ser um número inteiro de horas entre 0 e #{MAX_HOURS_BEFORE}"

        def evaluate(entries)
          messages = entries.each_with_index.flat_map { |entry, index| entry_messages(entry).map { |text| line_prefix(index + 1) + text } }
          messages.concat(general_messages(entries))
          raise ValidationError.new({ FIELD => messages }) unless messages.empty?

          { "tiers" => entries.sort_by { |entry| -entry[:hours] }.map { |entry| { "min_hours_before" => entry[:hours], "fee_bps" => entry[:fee] } } }
        end

        def entry_messages(entry)
          messages = entry[:messages].dup
          messages << hours_message unless entry[:hours].equal?(INVALID) || hours_valid?(entry[:hours])
          messages << "multa entre 0% e 100%" unless entry[:fee].equal?(INVALID) || fee_valid?(entry[:fee])
          messages
        end

        def hours_valid?(value) = value.is_a?(Integer) && value.between?(0, MAX_HOURS_BEFORE)
        def fee_valid?(value) = value.is_a?(Integer) && value.between?(0, MAX_FEE_BPS)

        # Quantidade, repetição, faixa de 0 h e ordem das multas (as duas últimas só com todas as
        # antecedências válidas; a ordem das multas, entre as faixas inteiramente válidas).
        def general_messages(entries)
          return ["informe ao menos uma faixa"] if entries.empty?

          messages = []
          messages << "no máximo #{MAX_TIERS} faixas" if entries.size > MAX_TIERS
          hours = entries.map { |entry| entry[:hours] }.select { |value| hours_valid?(value) }
          hours.tally.select { |_, count| count > 1 }.each_key { |value| messages << "antecedência repetida: #{value} h" }
          if hours.size == entries.size && !hours.include?(0)
            messages << "inclua uma faixa de 0 h (cancelamento com menos antecedência que as demais faixas ou após o início)"
          end
          messages.concat(decreasing_fees(entries))
        end

        def decreasing_fees(entries)
          valid = entries.select { |entry| hours_valid?(entry[:hours]) && fee_valid?(entry[:fee]) }
                         .uniq { |entry| entry[:hours] }.sort_by { |entry| -entry[:hours] }
          valid.each_cons(2).filter_map do |earlier, later|
            next if later[:fee] >= earlier[:fee]

            "a multa não pode diminuir à medida que o início se aproxima (#{earlier[:hours]} h: #{Percent.label(earlier[:fee])}; " \
              "#{later[:hours]} h: #{Percent.label(later[:fee])})"
          end
        end
      end
    end
  end
end
