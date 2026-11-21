# frozen_string_literal: true

require_relative "v1"

module Locentra
  module Interfaces
    module HTTP
      module API
        # Serialização explícita da operação na API v1: retirada, devolução, inspeções e alertas. Retirantes
        # aparecem pelo nome (o documento não é exposto) e os autorizados do cliente, somente com
        # `customers.read`.
        module OperationsSerializers
          module_function

          def time(value) = value&.utc&.iso8601
          def money(cents) = Domain::Money.new(cents).to_h
          def reservation_link(reservation) = { "id" => reservation.id, "code" => reservation.code, "status" => reservation.status }

          def pickup(data, pickers:)
            pickup = data[:pickup]
            picker = pickup.picker
            { "id" => pickup.id, "status" => pickup.status, "reservation" => reservation_link(data[:reservation]), "branch_id" => pickup.branch_id,
              "picker" => picker && { "kind" => picker.kind, "contact_id" => picker.contact_id, "name" => picker.name }, "notes" => pickup.notes,
              "started_at" => time(pickup.started_at), "delivered_at" => time(pickup.delivered_at), "cancelled_at" => time(pickup.cancelled_at),
              "version" => pickup.version, "lines" => data[:lines].map { |row| pickup_line(row) },
              "authorized_pickers" => pickers ? data[:pickers].map { |contact| { "contact_id" => contact.id, "name" => contact.name } } : nil }
          end

          def pickup_line(row)
            { "id" => row["id"], "status" => row["status"], "product_id" => row["product_id"], "sku" => row["sku"],
              "reservation_item_id" => row["reservation_item_id"], "asset_id" => row["asset_id"], "tag" => row["tag"],
              "allocated_asset_id" => row["allocated_asset_id"], "allocated_tag" => row["allocated_tag"], "expected_quantity" => row["expected_quantity"],
              "checked_quantity" => row["checked_quantity"], "delivered_quantity" => row["delivered_quantity"],
              "returned_quantity" => row["returned_quantity"], "missing_quantity" => row["missing_quantity"], "release_reason" => row["release_reason"] }
          end

          def return_items(data)
            lines = data[:lines].map do |row|
              pickup_line(row).merge("pending_quantity" => row["delivered_quantity"] - row["returned_quantity"] - row["missing_quantity"])
            end
            returns = data[:returns].map do |row|
              { "id" => row["id"], "returned_at" => time(row["returned_at"]), "late_fee" => money(row["late_fee_cents"]),
                "completes_reservation" => row["completes_reservation"], "lines" => row["lines"] }
            end
            { "reservation" => reservation_link(data[:reservation]), "pickup_id" => data[:pickup]&.id, "lines" => lines, "returns" => returns }
          end

          def return_detail(data)
            row = data[:return]
            lines = data[:lines].map do |line|
              line.slice("id", "pickup_line_id", "outcome", "quantity", "requires_inspection", "notes", "asset_id", "stock_pool_id", "sku", "tag",
                         "damage_report_id", "damage_report_code")
            end
            fees = data[:late_fees].map do |fee|
              { "reservation_item_id" => fee["reservation_item_id"], "amount" => money(fee["amount_cents"]), "quantity" => fee["details"]["quantity"] }
            end
            { "id" => row["id"], "reservation_id" => row["reservation_id"], "reservation_code" => row["reservation_code"], "pickup_id" => row["pickup_id"],
              "returned_at" => time(row["returned_at"]), "late_fee" => money(row["late_fee_cents"]), "completes_reservation" => row["completes_reservation"],
              "notes" => row["notes"], "lines" => lines, "late_fees" => fees }
          end

          INSPECTION_KEYS = %w[id status reason product_id branch_id asset_id stock_pool_id quantity reservation_id return_line_id
                               maintenance_order_id decision_notes].freeze

          # Mesmo formato para a linha da lista (Hash) e para o objeto de domínio da decisão.
          def inspection(item)
            row = item.is_a?(Hash) ? item : item.to_h.transform_keys(&:to_s)
            row.slice(*INSPECTION_KEYS).merge("created_at" => time(row["created_at"]), "decided_at" => time(row["decided_at"]))
          end

          def alert(alert)
            { "id" => alert.id, "kind" => alert.kind, "status" => alert.status, "reservation_id" => alert.reservation_id,
              "related_reservation_id" => alert.related_reservation_id, "asset_id" => alert.asset_id, "stock_pool_id" => alert.stock_pool_id,
              "details" => alert.details, "created_at" => time(alert.created_at), "resolved_at" => time(alert.resolved_at),
              "resolution" => alert.resolution }
          end
        end

        # Operação na API v1: separação, conferência, entrega e cancelamento da retirada; itens a devolver,
        # registro e detalhe da devolução; inspeções e alertas operacionais. Escopos: `fulfillment.write`
        # (retirada, devolução e alertas), `inspections.write` (decisão das inspeções) e `reservations.read`
        # nas leituras. Toda mutação exige `Idempotency-Key`.
        class OperationsV1Controller < V1Controller
          OS = OperationsSerializers
          CHECK_FORMAT = "informe os itens como uma lista de objetos com line_id e tag (ativo) ou quantity (estoque)"
          RETURN_FORMAT = "informe os itens como uma lista de objetos com pickup_line_id e outcome"

          # Retirada -------------------------------------------------------------------------------------

          # 201 quando a separação é criada agora; 200 quando já havia separação em andamento (a mesma).
          def start_pickup(ctx)
            id = path_id(ctx)
            idempotent(ctx, "fulfillment.write", "POST /api/v1/reservations/#{id}/pickups", ctx.json,
                       location: ->(body) { "/api/v1/pickups/#{body["id"]}" }) do |tx, actor|
              result = uc(:start_pickup).open(actor, id, tx: tx)
              [result.created ? 201 : 200, pickup_body(ctx, actor, result.pickup.id, tx)]
            end
          end

          def pickup(ctx)
            json(200, OS.pickup(uc(:get_pickup).call(ctx.actor, path_id(ctx)), pickers: ctx.can?("customers.read")))
          end

          def check_pickup(ctx)
            id = path_id(ctx)
            data = ctx.json
            entries = check_entries(data)
            idempotent(ctx, "fulfillment.write", "POST /api/v1/pickups/#{id}/check", data) do |tx, actor|
              uc(:check_pickup).call(actor, id, entries, tx: tx)
              [200, pickup_body(ctx, actor, id, tx)]
            end
          end

          # Retirante: `{ "kind": "customer" }` (cliente pessoa física) ou `{ "kind": "contact", "contact_id": ... }`
          # (contato autorizado). Segunda entrega responde 409 `already_picked_up`.
          def deliver_pickup(ctx)
            id = path_id(ctx)
            data = ctx.json
            picker, notes = collect do |check|
              [check.call("retirante") { picker_input(data) }, check.call("observacoes") { strict_text(data, "notes", "observacoes") }]
            end
            idempotent(ctx, "fulfillment.write", "POST /api/v1/pickups/#{id}/deliver", data) do |tx, actor|
              uc(:deliver_pickup).call(actor, id, picker: picker, notes: notes, tx: tx)
              [200, pickup_body(ctx, actor, id, tx)]
            end
          end

          def cancel_pickup(ctx)
            id = path_id(ctx)
            data = ctx.json
            reason = collect { |check| check.call("motivo") { strict_text(data, "reason", "motivo") } }
            idempotent(ctx, "fulfillment.write", "POST /api/v1/pickups/#{id}/cancel", data) do |tx, actor|
              uc(:cancel_pickup).call(actor, id, reason: reason, tx: tx)
              [200, pickup_body(ctx, actor, id, tx)]
            end
          end

          # Devolução ------------------------------------------------------------------------------------

          def return_items(ctx)
            json(200, OS.return_items(uc(:return_form).call(ctx.actor, path_id(ctx))))
          end

          def create_return(ctx)
            id = path_id(ctx)
            data = ctx.json
            entries, notes = collect do |check|
              [check.call("itens") { return_entries(data) }, check.call("observacoes") { strict_text(data, "notes", "observacoes") }]
            end
            idempotent(ctx, "fulfillment.write", "POST /api/v1/reservations/#{id}/returns", data,
                       location: ->(body) { "/api/v1/returns/#{body["id"]}" }) do |tx, actor|
              row = uc(:register_return).call(actor, id, entries: entries, notes: notes, tx: tx)
              [201, OS.return_detail(uc(:get_return).call(actor, row["id"], tx: tx, permission: "fulfillment.write"))]
            end
          end

          def return_detail(ctx)
            json(200, OS.return_detail(uc(:get_return).call(ctx.actor, path_id(ctx))))
          end

          # Inspeções ------------------------------------------------------------------------------------

          def inspections(ctx)
            page = uc(:search_inspections).call(ctx.actor, status: ctx.query("status") || "pending", limit: ctx.query("limit"),
                                                           offset: ctx.query("offset"))
            json(200, S.page(page) { |row| OS.inspection(row) })
          end

          def approve_inspection(ctx)
            id = path_id(ctx)
            data = ctx.json
            notes = collect { |check| check.call("observacoes") { strict_text(data, "notes", "observacoes") } }
            idempotent(ctx, "inspections.write", "POST /api/v1/inspections/#{id}/approve", data) do |tx, actor|
              [200, OS.inspection(uc(:approve_inspection).call(actor, id, notes: notes, tx: tx))]
            end
          end

          # Reprovação: abre ordem de manutenção e mantém o item indisponível.
          def reject_inspection(ctx)
            id = path_id(ctx)
            data = ctx.json
            notes, description = collect do |check|
              [check.call("motivo") { strict_text(data, "notes", "motivo") }, check.call("descricao") { strict_text(data, "description", "descricao") }]
            end
            idempotent(ctx, "inspections.write", "POST /api/v1/inspections/#{id}/reject", data) do |tx, actor|
              result = uc(:reject_inspection).call(actor, id, notes: notes, description: description, tx: tx)
              [200, { "inspection" => OS.inspection(result[:inspection]),
                      "maintenance_order" => { "id" => result[:order].id, "code" => result[:order].code } }]
            end
          end

          # Alertas --------------------------------------------------------------------------------------

          def alerts(ctx)
            page = uc(:list_alerts).call(ctx.actor, status: ctx.query("status") || "open", kind: ctx.query("kind"),
                                                    reservation_id: ctx.query("reservation_id"), limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |alert| OS.alert(alert) })
          end

          # A decisão registrada usa o campo `decisao` do domínio (de 3 a 1000 caracteres).
          def resolve_alert(ctx)
            id = path_id(ctx)
            data = ctx.json
            resolution = collect { |check| check.call("decisao") { strict_text(data, "resolution", "decisao") } }
            idempotent(ctx, "fulfillment.write", "POST /api/v1/alerts/#{id}/resolve", data) do |tx, actor|
              [200, OS.alert(uc(:resolve_alert).call(actor, id, resolution: resolution, tx: tx))]
            end
          end

          private

          # Detalhes lidos na transação da mutação, que já conferiu `fulfillment.write`: não exigem também
          # `reservations.read`.
          def pickup_body(ctx, actor, id, tx)
            OS.pickup(uc(:get_pickup).call(actor, id, tx: tx, permission: "fulfillment.write"), pickers: ctx.can?("customers.read"))
          end

          # Conferência: `tag` para ativos e `quantity` (inteiro) para estoque, com os erros de formato reunidos.
          def check_entries(data)
            items = object_list(data, "items", "itens", CHECK_FORMAT)
            collect do |check|
              items.map do |item|
                if item.key?("tag")
                  { line_id: item["line_id"], tag: check.call("patrimonio") { strict_text(item, "tag", "patrimonio") } }
                else
                  { line_id: item["line_id"], quantity: check.call("quantidade") { strict_integer(item, "quantity", "quantidade", allow_nil: false) } }
                end
              end
            end
          end

          def picker_input(data)
            picker = data["picker"]
            raise Domain::ValidationError.field("retirante", "informe quem está retirando: kind customer ou contact") unless picker.is_a?(Hash)

            { kind: strict_text(picker, "kind", "retirante").to_s, contact_id: picker["contact_id"] }
          end

          # Itens da devolução com formatos estritos; a lista vazia segue para a regra do domínio (`itens`).
          def return_entries(data)
            items = object_list(data, "entries", "itens", RETURN_FORMAT)
            collect do |check|
              items.map do |item|
                entry = { pickup_line_id: item["pickup_line_id"], outcome: check.call("resultado") { strict_text(item, "outcome", "resultado") },
                          requires_inspection: check.call("inspecao") { strict_boolean(item, "requires_inspection", "inspecao") } || false,
                          notes: check.call("observacoes") { strict_text(item, "notes", "observacoes") } }
                entry[:quantity] = check.call("quantidade") { strict_integer(item, "quantity", "quantidade", allow_nil: false) } unless item["quantity"].nil?
                entry
              end
            end
          end
        end
      end
    end
  end
end
