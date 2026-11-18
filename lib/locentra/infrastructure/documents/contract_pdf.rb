# frozen_string_literal: true

require "prawn"

module Locentra
  module Infrastructure
    module Documents
      # Gera o PDF do contrato de locação com Prawn a partir do snapshot de dados do documento
      # (termos congelados na emissão, aditivos e período vigente). Usa as fontes padrão do PDF
      # (codificação Windows-1252): caracteres fora dela são substituídos por "?".
      class ContractPdf
        Prawn::Fonts::AFM.hide_m17n_warning = true

        ENCODING = "Windows-1252"

        def render(snapshot)
          terms = snapshot.fetch("terms")
          pdf = Prawn::Document.new(page_size: "A4", margin: [48, 48, 56, 48], info: info(snapshot, terms))
          pdf.default_kerning = false
          pdf.font("Helvetica", size: 10)
          header(pdf, snapshot, terms)
          parties(pdf, terms)
          period(pdf, snapshot, terms)
          items(pdf, terms)
          values(pdf, snapshot, terms)
          amendments(pdf, snapshot)
          cancellation(pdf, terms)
          conditions(pdf, terms)
          acceptance(pdf, snapshot)
          pdf.number_pages(clean("Contrato #{snapshot.fetch("contract_code")} · versão #{snapshot.fetch("document_version")} · página <page> de <total>"),
                           at: [pdf.bounds.left, -16], width: pdf.bounds.width, align: :center, size: 8)
          pdf.render
        end

        private

        def info(snapshot, terms)
          { Title: clean("Contrato de locação #{snapshot.fetch("contract_code")} - versão #{snapshot.fetch("document_version")}"),
            Author: clean(terms.dig("organization", "name").to_s), Creator: "Locentra", Producer: "Locentra",
            CreationDate: Time.iso8601(snapshot.fetch("generated_at")) }
        end

        def header(pdf, snapshot, terms)
          pdf.text clean(terms.dig("organization", "name").to_s), size: 12, style: :bold
          pdf.text clean("Contrato de locação #{snapshot.fetch("contract_code")}"), size: 16, style: :bold
          reason = Domain::Contracts::DOCUMENT_REASONS.fetch(snapshot.fetch("reason"))
          pdf.text clean("Documento versão #{snapshot.fetch("document_version")} (#{reason}) · gerado em " \
                         "#{snapshot.fetch("generated_at_local")} (#{terms.dig("period", "timezone")})"), size: 9
          pdf.move_down 10
        end

        def section(pdf, title)
          pdf.move_down 8
          pdf.text clean(title), size: 11, style: :bold
          pdf.move_down 3
        end

        def line(pdf, text, **)
          pdf.text(clean(text), **)
        end

        def bullet(pdf, text)
          pdf.indent(12) { line(pdf, "- #{text}") }
        end

        def parties(pdf, terms)
          section(pdf, "1. Partes")
          org = terms.fetch("organization")
          line(pdf, "Locadora: #{org["name"]}#{" · CNPJ #{org["legal_document"]}" if org["legal_document"]}")
          customer = terms.fetch("customer")
          line(pdf, "Locatário: #{customer["name"]} · #{customer["kind"] == "company" ? "CNPJ" : "CPF"} #{customer["document"]}")
          contact = [customer["email"], customer["phone"]].compact.join(" · ")
          line(pdf, "Contato: #{contact}") unless contact.empty?
          line(pdf, "Endereço: #{customer["address"]}") if customer["address"]
        end

        def period(pdf, snapshot, terms)
          section(pdf, "2. Objeto e período")
          line(pdf, "Reserva #{terms.dig("reservation", "code")}#{" · filial #{terms.dig("branch", "name")}" if terms["branch"]}")
          line(pdf, "Origem: orçamento #{terms.dig("quote", "code")}, versão #{terms.dig("quote", "version")}") if terms["quote"]
          current = snapshot.fetch("current_period")
          line(pdf, "Retirada: #{current["starts_at_local"]}")
          line(pdf, "Devolução: #{current["ends_at_local"]}")
          line(pdf, "Horários no fuso #{current["timezone"]}.", size: 9)
        end

        def items(pdf, terms)
          section(pdf, "3. Itens locados")
          terms.fetch("items").each do |item|
            bullet(pdf, "#{item["quantity"]} x #{item["name"]} (#{item["sku"]}) · #{item["description"]} · #{money(item["total_cents"])}")
          end
        end

        def values(pdf, snapshot, terms)
          section(pdf, "4. Valores")
          pricing = terms.fetch("pricing")
          line(pdf, "Subtotal dos itens: #{money(pricing["subtotal_cents"])}") if pricing["subtotal_cents"]
          line(pdf, "Desconto por cupom #{pricing["coupon_code"]}: -#{money(pricing["coupon_discount_cents"])}") if pricing["coupon_code"]
          line(pdf, "Desconto manual: -#{money(pricing["manual_discount_cents"])}") if pricing["manual_discount_cents"].to_i.positive?
          Array(pricing["fees"]).each { |fee| line(pdf, "#{fee["description"]}: #{money(fee["amount_cents"])}") }
          line(pdf, "Valor da locação na emissão: #{money(terms.fetch("total_cents"))}")
          line(pdf, "Ajustes anteriores à emissão: #{money(terms.fetch("adjustments_cents"))}") if terms.fetch("adjustments_cents").positive?
          line(pdf, "Total contratado vigente: #{money(snapshot.fetch("current_total_cents"))}", style: :bold)
          line(pdf, "Caução prevista: #{money(terms.fetch("deposit_cents"))} (separada do valor da locação e devolvida após a conferência)")
        end

        def amendments(pdf, snapshot)
          section(pdf, "5. Aditivos")
          list = snapshot.fetch("amendments")
          return line(pdf, "Nenhum aditivo registrado.") if list.empty?

          list.each do |amendment|
            bullet(pdf, "Aditivo #{amendment["number"]} (documento versão #{amendment["document_version"]}): #{amendment["description"]} · " \
                        "diferença de valor #{money(amendment["amount_delta_cents"])}")
          end
        end

        def cancellation(pdf, terms)
          section(pdf, "6. Política de cancelamento")
          line(pdf, "A multa é calculada sobre o total contratado vigente, conforme a antecedência em relação ao início da locação:")
          terms.fetch("cancellation_terms").each { |text| bullet(pdf, text) }
        end

        def conditions(pdf, terms)
          section(pdf, "7. Condições gerais")
          terms.fetch("general_conditions").each { |text| bullet(pdf, text) }
          return unless terms["conditions"]

          section(pdf, "8. Condições específicas")
          line(pdf, terms["conditions"])
        end

        def acceptance(pdf, snapshot)
          section(pdf, "Aceite eletrônico simples")
          line(pdf, snapshot.fetch("acceptance_notice"))
          line(pdf, "O aceite desta versão é registrado no sistema e vinculado ao resumo SHA-256 deste arquivo, consultável na tela do contrato.")
        end

        def money(cents) = Domain::Money.new(cents.to_i).format_brl

        def clean(text)
          text.to_s.encode(ENCODING, invalid: :replace, undef: :replace, replace: "?").encode(Encoding::UTF_8)
        end
      end
    end
  end
end
