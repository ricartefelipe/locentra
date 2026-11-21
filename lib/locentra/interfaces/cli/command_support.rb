# frozen_string_literal: true

require "date"

module Locentra
  module Interfaces
    module CLI
      # Resultado de um comando: dados para `--json`, linhas para a saída humana e código de saída.
      Result = Data.define(:data, :lines, :exit_code) do
        def self.ok(data, lines) = new(data: data, lines: lines, exit_code: ExitCodes::OK)
      end

      # Apoio comum às classes de comandos: acesso aos casos de uso, organização do ator (para o fuso
      # de exibição e as filiais) e leitura de instantes informados nas opções.
      module CommandSupport
        OFFSET = /(Z|[+-]\d{2}:\d{2})\z/
        DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/

        private

        def uc(name) = @system.use_cases[name]

        # Organização e filiais do ator (não exige permissão além da credencial válida).
        def organization = @organization ||= uc(:get_organization).call(@actor)
        def zone = organization[:organization].time_zone

        # Instante em ISO 8601 com fuso, data local (início do dia) ou data e hora locais da organização.
        def instant(text, field)
          value = text.to_s.strip
          return Domain::Period.parse_instant(value, field) if value.match?(OFFSET)
          return zone.start_of_day(Date.iso8601(value)) if value.match?(DATE_ONLY)

          zone.parse_local(value)
        rescue Date::Error
          raise Domain::ValidationError.field(field, "data inexistente")
        rescue Domain::ValidationError => e
          raise e if e.errors.key?(field)

          raise Domain::ValidationError.field(field, "#{e.errors.values.flatten.join("; ")} (fuso #{zone.identifier})")
        end

        def pagination(page)
          { "limit" => page.limit, "offset" => page.offset, "total" => page.total, "next_offset" => page.next_offset }
        end

        # Rodapé das listagens paginadas, com a dica da próxima página.
        def shown_line(page)
          shown = "Exibindo #{page.offset + 1}–#{page.offset + page.items.size} de #{page.total} (horários em #{zone.identifier})."
          page.next_offset ? "#{shown} Próxima página: --deslocamento #{page.next_offset}." : shown
        end
      end
    end
  end
end
