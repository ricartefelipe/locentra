# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Conversões de formulário e mensagens comuns às telas de operação.
        module OperationsForms
          FORM_ERRORS = [Domain::ValidationError, Domain::Conflict, Domain::InvalidTransition].freeze

          private

          def errors_of(error)
            case error
            when Domain::ValidationError then error.errors
            when Domain::Unavailable
              available = error.shortages.filter_map { |s| s["available"] }.min
              { "base" => ["#{error.message}#{" (disponível: #{available})" if available}."] }
            else { "base" => [error.message] }
            end
          end

          def status_of(error) = error.is_a?(Domain::ValidationError) ? 422 : 409

          # Campos indexados pelo identificador da linha: nome[<id>]=valor.
          def keyed(value) = value.is_a?(Hash) ? value : {}

          def blank(value) = value.to_s.strip.empty? ? nil : value.to_s.strip

          def optional_money(value) = blank(value) && Domain::Money.parse(value)

          def back_path(ctx, fallback)
            target = ctx.form["voltar"].to_s
            Controller.local_path?(target) ? target : fallback
          end
        end

        # Painel da operação e resolução de alertas.
        class OperationsController < Controller
          include OperationsForms

          def show(ctx, errors: {}, status: 200)
            data = uc(:operations_board).call(ctx.actor)
            render(ctx, "operations/board", title: "Retiradas e devoluções", status: status, data: data, errors: errors)
          end

          def resolve_alert(ctx)
            uc(:resolve_alert).call(ctx.actor, ctx.param(:id), resolution: ctx.form["decisao"])
            redirect(ctx, back_path(ctx, "/operacao"), notice: "Alerta resolvido; decisão registrada.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end
        end

        # Separação, conferência e entrega.
        class PickupsController < Controller
          include OperationsForms

          def start(ctx)
            pickup = uc(:start_pickup).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/operacao/retiradas/#{pickup.id}", notice: "Separação em andamento. Confira os itens antes da entrega.")
          rescue *FORM_ERRORS => e
            redirect(ctx, "/reservas/#{Domain::Identifier.parse(ctx.param(:id))}", alert: "Retirada não iniciada: #{e.message}")
          end

          def show(ctx, errors: {}, status: 200, values: {})
            data = uc(:get_pickup).call(ctx.actor, ctx.param(:id))
            render(ctx, "operations/pickup", title: "Retirada da reserva #{data[:reservation].code}", status: status, data: data, errors: errors,
                                             values: values)
          end

          def check(ctx)
            f = ctx.form
            entries = keyed(f["patrimonio"]).filter_map { |id, tag| { line_id: id, tag: tag } if blank(tag) } +
                      keyed(f["quantidade"]).filter_map { |id, qty| { line_id: id, quantity: qty } if blank(qty) }
            uc(:check_pickup).call(ctx.actor, ctx.param(:id), entries)
            redirect(ctx, "/operacao/retiradas/#{ctx.param(:id)}", notice: "Conferência registrada.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e), values: f)
          end

          def deliver(ctx)
            choice = ctx.form["retirante"].to_s
            picker = if choice == "cliente"
                       { kind: "customer" }
                     else
                       { kind: choice.empty? ? "" : "contact", contact_id: choice }
                     end
            pickup = uc(:deliver_pickup).call(ctx.actor, ctx.param(:id), picker: picker, notes: ctx.form["observacoes"])
            redirect(ctx, "/reservas/#{pickup.reservation_id}", notice: "Retirada registrada para #{pickup.picker.name}. Reserva em andamento.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end

          def cancel(ctx)
            pickup = uc(:cancel_pickup).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/reservas/#{pickup.reservation_id}", notice: "Separação cancelada; a reserva continua confirmada.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end
        end

        # Devolução total ou parcial e comprovante.
        class ReturnsController < Controller
          include OperationsForms

          def new(ctx, errors: {}, status: 200, values: {})
            data = uc(:return_form).call(ctx.actor, ctx.param(:id))
            render(ctx, "operations/return_form", title: "Devolução da reserva #{data[:reservation].code}", status: status, data: data,
                                                  errors: errors, values: values)
          end

          def create(ctx)
            f = ctx.form
            receipt = uc(:register_return).call(ctx.actor, ctx.param(:id), entries: entries_from(f), notes: f["notas"])
            notice = receipt["completes_reservation"] ? "Devolução concluída; reserva encerrada." : "Devolução parcial registrada."
            notice += " Multa por atraso: #{Domain::Money.new(receipt["late_fee_cents"]).format_brl}." if receipt["late_fee_cents"].positive?
            redirect(ctx, "/operacao/devolucoes/#{receipt["id"]}", notice: notice)
          rescue *FORM_ERRORS => e
            new(ctx, errors: errors_of(e), status: status_of(e), values: f)
          end

          def show(ctx)
            data = uc(:get_return).call(ctx.actor, ctx.param(:id))
            render(ctx, "operations/return", title: "Devolução da reserva #{data[:return]["reservation_code"]}", data: data)
          end

          private

          def entries_from(form)
            quantities = keyed(form["quantidade"])
            inspections = keyed(form["inspecao"])
            notes = keyed(form["observacoes"])
            keyed(form["resultado"]).filter_map do |line_id, outcome|
              next unless blank(outcome)

              { pickup_line_id: line_id, outcome: outcome, quantity: blank(quantities[line_id]) || 1,
                requires_inspection: inspections[line_id] == "1", notes: notes[line_id] }
            end
          end
        end
      end
    end
  end
end
