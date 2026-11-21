# frozen_string_literal: true

require_relative "v1"

module Locentra
  module Interfaces
    module HTTP
      module API
        # Serialização explícita dos contratos na API v1. O cliente aparece pelo identificador; os dados do
        # aceite expostos são o instante, o nome declarado e o canal (documento, IP, navegador e snapshot dos
        # dados do documento ficam de fora).
        module ContractSerializers
          module_function

          def time(value) = value&.utc&.iso8601
          def money(cents) = Domain::Money.new(cents).to_h

          def summary(row) = contract(row[:contract], row[:reservation_code])

          def contract(contract, reservation_code)
            { "id" => contract.id, "code" => contract.code, "status" => contract.status, "reservation_id" => contract.reservation_id,
              "reservation_code" => reservation_code, "customer_id" => contract.customer_id, "quote_id" => contract.quote_id,
              "current_document_version" => contract.current_document_version, "issued_at" => time(contract.issued_at),
              "activated_at" => time(contract.activated_at), "closed_at" => time(contract.closed_at), "cancelled_at" => time(contract.cancelled_at) }
          end

          def detail(data)
            contract = data[:contract]
            fee = contract.cancellation_fee_cents
            contract(contract, data[:reservation].code).merge(
              "cancellation_reason" => contract.cancellation_reason, "cancellation_fee" => fee && money(fee),
              "contracted_total" => contract.contracted_total.to_h, "current_total" => data[:current_total].to_h,
              "time_zone" => contract.time_zone_identifier, "cancellation_policy" => contract.cancellation_policy,
              "documents" => data[:documents].map { |row| document(contract, row) },
              "amendments" => data[:amendments].map { |row| amendment(row) }, "cancellation_preview" => data[:preview] && preview(data[:preview])
            )
          end

          def document(contract, row)
            { "version" => row["version"], "reason" => row["reason"], "sha256" => row["sha256"], "byte_size" => row["byte_size"],
              "filename" => row["filename"], "generated_at" => time(row["generated_at"]), "accepted_at" => time(row["accepted_at"]),
              "accepted_by_name" => row["accepted_by_name"], "accepted_via" => row["accepted_via"],
              "download_path" => "/api/v1/contracts/#{contract.id}/documents/#{row["version"]}" }
          end

          def amendment(row)
            { "number" => row["number"], "kind" => row["kind"], "description" => row["description"], "changes" => row["changes"],
              "amount_delta" => money(row["amount_delta_cents"]), "document_version" => row["document_version"], "created_at" => time(row["created_at"]) }
          end

          def preview(preview)
            { "fee_bps" => preview.fee_bps, "fee" => preview.fee.to_h, "base" => preview.base.to_h, "hours_before" => preview.hours_before }
          end
        end

        # Contratos na API v1: lista, detalhe, emissão a partir da reserva confirmada, PDF de cada versão do
        # documento, aditivo de extensão e cancelamento com a política do contrato. Escopos: `contracts.read`
        # nas leituras e `contracts.write` nas mutações; o aditivo exige também `reservations.write` e o
        # cancelamento, `reservations.cancel`. Aceite eletrônico e encerramento ficam fora da API.
        class ContractsV1Controller < V1Controller
          CS = ContractSerializers

          def contracts(ctx)
            page = uc(:list_contracts).call(ctx.actor, status: ctx.query("status"), customer_id: ctx.query("customer_id"), search: ctx.query("q"),
                                                       limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |row| CS.summary(row) })
          end

          def contract(ctx)
            json(200, CS.detail(uc(:get_contract).call(ctx.actor, path_id(ctx))))
          end

          # Emissão idempotente pela reserva: 201 quando o contrato é emitido agora e 200 quando a reserva já
          # tinha contrato (o mesmo), com Location nos dois casos.
          def create_contract(ctx)
            data = ctx.json
            conditions = collect { |check| check.call("condicoes") { strict_text(data, "conditions", "condicoes") } }
            location = ->(body) { "/api/v1/contracts/#{body["id"]}" }
            idempotent(ctx, "contracts.write", "POST /api/v1/contracts", data, location: location) do |tx, actor|
              result = uc(:issue_contract).issue(actor, data["reservation_id"], conditions: conditions, tx: tx)
              [result.created ? 201 : 200, detail(actor, result.contract.id, tx)]
            end
          end

          # PDF de uma versão do documento, com o SHA-256 gravado na emissão em `Repr-Digest` (RFC 9530).
          def contract_document(ctx)
            file = uc(:document_file).call(ctx.actor, path_id(ctx), ctx.param(:version))
            digest = [[file[:document]["sha256"]].pack("H*")].pack("m0")
            [200, { "content-type" => file[:content_type], "content-disposition" => content_disposition(file[:filename], "attachment"),
                    "content-length" => file[:bytes].bytesize.to_s, "cache-control" => "private, no-store", "x-content-type-options" => "nosniff",
                    "content-security-policy" => "default-src 'none'; sandbox", "repr-digest" => "sha-256=:#{digest}:" }, [file[:bytes]]]
          end

          # Aditivo de extensão: nova versão do documento e diferença de valor. Extensão que invade outra
          # reserva responde 409 `unavailable` com `shortages`, sem aditivo.
          def amend_contract(ctx)
            id = path_id(ctx)
            data = ctx.json
            ends_at, description = collect do |check|
              [check.call("fim") { required_instant(data, "ends_at", "fim") }, check.call("descricao") { strict_text(data, "description", "descricao") }]
            end
            idempotent(ctx, "contracts.write", "POST /api/v1/contracts/#{id}/amendments", data,
                       location: ->(_) { "/api/v1/contracts/#{id}" }) do |tx, actor|
              result = uc(:amend_contract).call(actor, id, ends_at: ends_at, description: description, tx: tx)
              body = detail(actor, id, tx)
              [201, { "contract" => body, "amendment" => body["amendments"].find { |row| row["number"] == result[:amendment]["number"] } }]
            end
          end

          def cancel_contract(ctx)
            id = path_id(ctx)
            data = ctx.json
            reason = collect { |check| check.call("motivo") { strict_text(data, "reason", "motivo") } }
            idempotent(ctx, "contracts.write", "POST /api/v1/contracts/#{id}/cancel", data) do |tx, actor|
              result = uc(:cancel_contract).call(actor, id, reason: reason, tx: tx)
              [200, { "contract" => detail(actor, id, tx), "cancellation" => CS.preview(result[:preview]) }]
            end
          end

          private

          def detail(actor, id, tx) = CS.detail(uc(:get_contract).call(actor, id, tx: tx))

          def required_instant(data, key, field)
            api_instant(data, key, field) || raise(Domain::ValidationError.field(field, "obrigatório"))
          end
        end
      end
    end
  end
end
