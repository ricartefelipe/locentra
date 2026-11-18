# frozen_string_literal: true

module Locentra
  module Interfaces
    module CLI
      # Filtro aplicado a toda a saída da CLI (stdout, stderr e log): remove a credencial em uso,
      # qualquer token de credencial e senhas em URLs ou parâmetros de conexão com o banco.
      module Redactor
        TOKEN = /lcn_[0-9a-f]{32}_[A-Za-z0-9_-]{43}/
        URL_PASSWORD = %r{(\b[a-z][a-z0-9+.-]*://[^/\s:@]*):[^@\s/]*@}i
        CONNINFO_PASSWORD = /\bpassword\s*=\s*('[^']*'|\S+)/i
        MIN_SECRET_LENGTH = 8
        MASK = "[omitido]"

        module_function

        def scrub(text, secrets = [])
          clean = text.to_s
          secrets.each { |secret| clean = clean.gsub(secret, MASK) if secret.length >= MIN_SECRET_LENGTH }
          clean.gsub(TOKEN, "lcn_#{MASK}").gsub(URL_PASSWORD, "\\1:#{MASK}@").gsub(CONNINFO_PASSWORD, "password=#{MASK}")
        end
      end

      # Escrita com redação. Os segredos conhecidos (a credencial lida) são registrados assim que
      # obtidos, antes de qualquer saída que possa repeti-los.
      class SafeOutput
        def initialize(io)
          @io = io
          @secrets = []
        end

        def protect(secret)
          @secrets << secret.to_s unless secret.to_s.empty?
        end

        def puts(text = "")
          @io.puts(Redactor.scrub(text, @secrets))
        end

        def flush = @io.flush
      end

      # Formatação da saída humana em português. Valores vindos do banco passam por `clean`:
      # caracteres de controle (sequências de escape de terminal, quebras de linha) são trocados por
      # espaço, para que dados cadastrados não alterem o terminal nem forjem linhas da saída.
      module Formatting
        module_function

        def clean(value)
          value.nil? ? "—" : value.to_s.gsub(/[[:cntrl:]]/, " ")
        end

        def truncate(value, width)
          text = clean(value)
          text.length > width ? "#{text[0, width - 1]}…" : text
        end

        def time(value, zone)
          value ? zone.format_local(value) : "—"
        end

        def money(cents) = cents.nil? ? "—" : Domain::Money.new(cents).format_brl

        def period(period, zone)
          "#{time(period.starts_at, zone)} → #{time(period.ends_at, zone)} (#{zone.identifier})"
        end

        def yes_no(value) = value ? "sim" : "não"

        # Tabela em colunas alinhadas, com linha separadora após o cabeçalho.
        def table(headers, rows)
          cells = rows.map { |row| row.map { |value| clean(value) } }
          widths = headers.each_index.map { |i| ([headers[i]] + cells.map { |row| row[i] }).map(&:length).max }
          render = ->(row) { row.each_with_index.map { |value, i| value.ljust(widths[i]) }.join("  ").rstrip }
          [render.call(headers), widths.map { |w| "-" * w }.join("  "), *cells.map(&render)]
        end
      end

      # Representação JSON estável: chaves fixas por recurso, instantes em ISO 8601 UTC e valores
      # monetários como em `Money#to_h` (centavos, moeda e texto formatado), como na API v1.
      module Serializers
        module_function

        def time(value) = value&.utc&.iso8601
        def money(cents) = cents.nil? ? nil : Domain::Money.new(cents).to_h

        def organization(org)
          { "id" => org.id, "name" => org.name, "slug" => org.slug, "time_zone" => org.timezone }
        end

        def branch(branch)
          branch && { "id" => branch.id, "code" => branch.code, "name" => branch.name }
        end

        def credential(row)
          row && { "id" => row["id"], "name" => row["name"], "kind" => row["kind"], "created_at" => time(row["created_at"]),
                   "expires_at" => time(row["expires_at"]), "last_used_at" => time(row["last_used_at"]) }
        end

        def reservation(reservation)
          { "id" => reservation.id, "code" => reservation.code, "status" => reservation.status, "status_label" => reservation.status_label,
            "source" => reservation.source, "customer_id" => reservation.customer_id, "branch_id" => reservation.branch_id,
            "period" => reservation.period.to_h, "hold_expires_at" => time(reservation.hold_expires_at),
            "total" => reservation.total.to_h, "deposit" => reservation.deposit.to_h, "version" => reservation.version }
        end

        def allocation_period(row) = { "starts_at" => time(row["starts_at"]), "ends_at" => time(row["ends_at"]) }
      end
    end
  end
end
