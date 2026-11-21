# frozen_string_literal: true

require_relative "v1"

module Locentra
  module Interfaces
    module HTTP
      module API
        # Serialização explícita dos orçamentos na API v1. O cliente aparece pelo identificador (sem nome nem
        # documento), como na reserva.
        module QuoteSerializers
          module_function

          def time(value) = value&.utc&.iso8601

          def summary(row)
            quote = row[:quote]
            { "id" => quote.id, "code" => quote.code, "status" => quote.status, "customer_id" => quote.customer_id, "branch_id" => quote.branch_id,
              "current_version" => quote.current_version, "approved_version" => quote.approved_version, "hold_policy" => quote.hold_policy,
              "valid_until" => time(row[:valid_until]), "period" => row[:period].to_h, "total" => row[:total].to_h }
          end

          def detail(data)
            quote = data[:quote]
            { "id" => quote.id, "code" => quote.code, "status" => quote.status, "customer_id" => quote.customer_id, "branch_id" => quote.branch_id,
              "current_version" => quote.current_version, "approved_version" => quote.approved_version, "hold_policy" => quote.hold_policy,
              "hold_minutes" => quote.hold_minutes, "sent_at" => time(quote.sent_at), "approved_at" => time(quote.approved_at),
              "approved_by_type" => quote.approved_by_type, "approved_by_name" => quote.approved_by_name, "rejected_at" => time(quote.rejected_at),
              "rejection_reason" => quote.rejection_reason, "expired_at" => time(quote.expired_at), "converted_at" => time(quote.converted_at),
              "lock_version" => quote.lock_version, "hold_reservation" => hold(data[:hold]), "reservation" => link(data[:reservation]),
              "versions" => data[:versions].map { |v| version(v) } }
          end

          # Itens com o snapshot de preço da linha (o mesmo formato de `reservation_items.pricing`).
          def version(version)
            items = version.items.map do |item|
              { "product_id" => item["product_id"], "sku" => item["sku"], "quantity" => item["quantity"], "pricing" => item }
            end
            { "number" => version.number, "branch_id" => version.branch_id, "period" => version.period.to_h, "valid_until" => time(version.valid_until),
              "items" => items, "pricing" => version.pricing, "terms" => version.terms, "manual_discount_bps" => version.manual_discount_bps,
              "deposit" => version.deposit.to_h, "total" => version.total.to_h, "cancellation_policy" => version.cancellation_policy,
              "created_at" => time(version.created_at), "sent_at" => time(version.sent_at) }
          end

          def hold(reservation)
            reservation && link(reservation).merge("hold_expires_at" => time(reservation.hold_expires_at))
          end

          def link(reservation) = reservation && { "id" => reservation.id, "code" => reservation.code, "status" => reservation.status }
        end

        # Orçamentos na API v1: lista, detalhe, criação, nova versão, envio, aprovação em nome do cliente,
        # rejeição e conversão em reserva. Toda mutação exige `Idempotency-Key`, roda na mesma transação da
        # chave e devolve o detalhe atualizado, lido nessa transação. Escopos: `quotes.read` nas leituras e
        # `quotes.write` nas mutações; a conversão exige também `reservations.write`, e o desconto manual por
        # credencial é recusado (limite de desconto 0 fora de usuários).
        class QuotesV1Controller < V1Controller
          QS = QuoteSerializers

          def quotes(ctx)
            page = uc(:list_quotes).call(ctx.actor, status: ctx.query("status"), customer_id: ctx.query("customer_id"), search: ctx.query("q"),
                                                    sort: ctx.query("sort") || "-created_at", limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |row| QS.summary(row) })
          end

          def quote(ctx)
            json(200, QS.detail(uc(:get_quote).call(ctx.actor, path_id(ctx))))
          end

          def create_quote(ctx)
            data = ctx.json
            input = quote_input(data, customer: true)
            idempotent(ctx, "quotes.write", "POST /api/v1/quotes", data, location: ->(body) { "/api/v1/quotes/#{body["id"]}" }) do |tx, actor|
              [201, detail(actor, uc(:create_quote).call(actor, input, tx: tx).id, tx)]
            end
          end

          # A nova versão exige o conteúdo completo (como o formulário pré-preenchido); o cliente não muda.
          def revise_quote(ctx)
            id = path_id(ctx)
            data = ctx.json
            input = quote_input(data, customer: false)
            idempotent(ctx, "quotes.write", "POST /api/v1/quotes/#{id}/versions", data, location: ->(_) { "/api/v1/quotes/#{id}" }) do |tx, actor|
              uc(:revise_quote).call(actor, id, input, tx: tx)
              [201, detail(actor, id, tx)]
            end
          end

          def send_quote(ctx)
            id = path_id(ctx)
            idempotent(ctx, "quotes.write", "POST /api/v1/quotes/#{id}/send", ctx.json) do |tx, actor|
              uc(:send_quote).call(actor, id, tx: tx)
              [200, detail(actor, id, tx)]
            end
          end

          # Aprovação em nome do cliente. Orçamento vencido: a expiração gravada na transação da chave seria
          # desfeita com ela; é registrada à parte por `record_expiration`, que só expira (nunca aprova), e a
          # resposta continua 409 `quote_expired`. A operação não é repetida fora da chave.
          def approve_quote(ctx)
            id = path_id(ctx)
            data = ctx.json
            number, name = collect do |check|
              [check.call("versao") { strict_integer(data, "version", "versao", min: 1, allow_nil: false) },
               check.call("aprovado_por") { strict_text(data, "approver_name", "aprovado_por") }]
            end
            idempotent(ctx, "quotes.write", "POST /api/v1/quotes/#{id}/approve", data) do |tx, actor|
              uc(:approve_quote).call(actor, id, version: number, approver_name: name, tx: tx)
              [200, detail(actor, id, tx)]
            end
          rescue Domain::Conflict => e
            uc(:approve_quote).record_expiration(ctx.actor, id) if e.code == "quote_expired"
            raise
          end

          def reject_quote(ctx)
            id = path_id(ctx)
            data = ctx.json
            reason, number = collect do |check|
              [check.call("motivo") { strict_text(data, "reason", "motivo") },
               check.call("versao") { strict_integer(data, "version", "versao", min: 1) }]
            end
            idempotent(ctx, "quotes.write", "POST /api/v1/quotes/#{id}/reject", data) do |tx, actor|
              uc(:reject_quote).call(actor, id, reason: reason, version: number, tx: tx)
              [200, detail(actor, id, tx)]
            end
          end

          # 201 quando a reserva é criada agora; 200 quando o orçamento já estava convertido (mesma reserva).
          def convert_quote(ctx)
            id = path_id(ctx)
            location = ->(body) { "/api/v1/reservations/#{body["reservation"]["id"]}" }
            idempotent(ctx, "quotes.write", "POST /api/v1/quotes/#{id}/convert", ctx.json, location: location) do |tx, actor|
              result = uc(:convert_quote).call(actor, id, tx: tx)
              [result.created ? 201 : 200, { "quote" => detail(actor, id, tx), "reservation" => S.reservation(result.reservation) }]
            end
          end

          private

          def detail(actor, id, tx) = QS.detail(uc(:get_quote).call(actor, id, tx: tx))

          # Conteúdo de uma versão, com os erros de formato reunidos por campo. Na criação o cliente é
          # obrigatório; na nova versão ele não pode ser enviado.
          def quote_input(data, customer:)
            collect do |check|
              input = {
                branch_id: data["branch_id"], period: check.call("periodo") { api_period(data) },
                valid_until: check.call("validade") { api_instant(data, "valid_until", "validade") },
                lines: check.call("itens") { api_lines(data["items"]) }, fees: check.call("tarifas") { api_fees(data["fees"]) },
                manual_discount_bps: check.call("desconto") { strict_integer(data, "manual_discount_bps", "desconto", min: 0, max: 10_000) || 0 },
                terms: check.call("condicoes") { strict_text(data, "terms", "condicoes") },
                hold_policy: check.call("politica_bloqueio") { strict_text(data, "hold_policy", "politica_bloqueio") },
                hold_minutes: check.call("validade_bloqueio") { strict_integer(data, "hold_minutes", "validade_bloqueio") }
              }
              customer ? input.merge(customer_id: data["customer_id"]) : input.tap { check.call("cliente") { customer_unchanged!(data) } }
            end
          end

          def customer_unchanged!(data)
            raise Domain::ValidationError.field("cliente", "o cliente não muda na nova versão") if data.key?("customer_id")
          end
        end
      end
    end
  end
end
