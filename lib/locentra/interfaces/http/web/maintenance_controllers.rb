# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        class InspectionsController < Controller
          include OperationsForms

          def index(ctx, errors: {}, status: 200)
            render(ctx, "operations/inspections", title: "Inspeções", status: status, errors: errors,
                                                  pending: uc(:list_inspections).call(ctx.actor),
                                                  decided: uc(:list_inspections).call(ctx.actor, status: "decided", limit: 30))
          end

          def approve(ctx)
            uc(:approve_inspection).call(ctx.actor, ctx.param(:id), notes: ctx.form["observacoes"])
            redirect(ctx, "/operacao/inspecoes", notice: "Inspeção aprovada; item liberado para novas reservas.")
          rescue *FORM_ERRORS => e
            index(ctx, errors: errors_of(e), status: status_of(e))
          end

          def reject(ctx)
            result = uc(:reject_inspection).call(ctx.actor, ctx.param(:id), notes: ctx.form["motivo"], description: ctx.form["servico"])
            redirect(ctx, "/manutencao/#{result[:order].id}", notice: "Inspeção reprovada; ordem #{result[:order].code} aberta.")
          rescue *FORM_ERRORS => e
            index(ctx, errors: errors_of(e), status: status_of(e))
          end
        end

        # Avarias e faltas: revisão, evidências (anexos) e cobrança aprovada.
        class DamageReportsController < Controller
          include OperationsForms

          def index(ctx)
            render(ctx, "operations/damage_reports", title: "Avarias e faltas", open: uc(:list_damage_reports).call(ctx.actor),
                                                     decided: uc(:list_damage_reports).call(ctx.actor, filter: "decided"))
          end

          def create(ctx)
            f = ctx.form
            report = uc(:create_damage_report).call(ctx.actor, return_line_id: f["item"], description: f["descricao"], severity: f["severidade"].to_s,
                                                               estimated_cost: money_param(f["custo"]))
            redirect(ctx, "/operacao/avarias/#{report.id}", notice: "Avaria #{report.code} registrada. Anexe as evidências para aprovação.")
          rescue *FORM_ERRORS => e
            redirect(ctx, "/operacao/inspecoes", alert: "Avaria não registrada: #{e.message}")
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:get_damage_report).call(ctx.actor, ctx.param(:id))
            render(ctx, "operations/damage_report", title: "Avaria #{data[:report].code}", status: status, data: data, errors: errors)
          end

          def update(ctx)
            f = ctx.form
            uc(:revise_damage_report).call(ctx.actor, ctx.param(:id), description: f["descricao"], severity: f["severidade"].to_s,
                                                                      estimated_cost: money_param(f["custo"]))
            redirect(ctx, "/operacao/avarias/#{ctx.param(:id)}", notice: "Registro atualizado.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end

          def approve(ctx)
            report = uc(:approve_damage_charge).call(ctx.actor, ctx.param(:id), amount: optional_money(ctx.form["valor"]), notes: ctx.form["observacoes"])
            redirect(ctx, "/operacao/avarias/#{ctx.param(:id)}", notice: "Cobrança de #{report.charged.format_brl} aprovada e lançada na reserva.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end

          def dismiss(ctx)
            uc(:dismiss_damage_report).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/operacao/avarias/#{ctx.param(:id)}", notice: "Registro descartado sem cobrança.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end
        end

        class MaintenanceController < Controller
          include OperationsForms

          def index(ctx, errors: {}, status: 200, values: nil)
            render(ctx, "maintenance/index", title: "Manutenção", status: status, errors: errors, values: values || ctx.rack.GET,
                                             active: uc(:list_maintenance_orders).call(ctx.actor),
                                             closed: uc(:list_maintenance_orders).call(ctx.actor, filter: "closed"),
                                             branches: uc(:get_organization).call(ctx.actor)[:branches],
                                             products: uc(:list_products).call(ctx.actor, tracking: "bulk", limit: 100).items)
          end

          def create(ctx)
            f = ctx.form
            order = uc(:open_maintenance_order).call(ctx.actor, description: f["descricao"], asset_tag: blank(f["patrimonio"]),
                                                                product_id: f["produto_id"], branch_id: f["filial_id"], quantity: f["quantidade"])
            redirect(ctx, "/manutencao/#{order.id}", notice: "Ordem #{order.code} aberta; o item está indisponível até a conclusão.")
          rescue *FORM_ERRORS => e
            index(ctx, errors: errors_of(e), status: status_of(e), values: f)
          rescue Domain::NotFound => e
            index(ctx, errors: { "base" => [e.message.capitalize] }, status: 404, values: f)
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:get_maintenance_order).call(ctx.actor, ctx.param(:id))
            render(ctx, "maintenance/show", title: "Ordem #{data[:order].code}", status: status, data: data, errors: errors)
          end

          def start(ctx)
            uc(:start_maintenance).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/manutencao/#{ctx.param(:id)}", notice: "Manutenção iniciada.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end

          def complete(ctx)
            f = ctx.form
            order = uc(:complete_maintenance).call(ctx.actor, ctx.param(:id), cost: money_param(f["custo"]), requires_inspection: f["inspecao"] == "1",
                                                                              notes: f["observacoes"])
            outcome = order.requires_inspection ? "o item segue para inspeção" : "o item está disponível"
            redirect(ctx, "/manutencao/#{ctx.param(:id)}", notice: "Manutenção concluída; #{outcome}.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end

          def cancel(ctx)
            uc(:cancel_maintenance).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/manutencao/#{ctx.param(:id)}", notice: "Ordem cancelada.")
          rescue *FORM_ERRORS => e
            show(ctx, errors: errors_of(e), status: status_of(e))
          end
        end

        class TransfersController < Controller
          include OperationsForms

          def index(ctx, errors: {}, status: 200, values: nil)
            render(ctx, "transfers/index", title: "Transferências entre filiais", status: status, errors: errors, values: values || ctx.rack.GET,
                                           active: uc(:list_transfers).call(ctx.actor), closed: uc(:list_transfers).call(ctx.actor, filter: "closed"),
                                           branches: uc(:get_organization).call(ctx.actor)[:branches],
                                           products: uc(:list_products).call(ctx.actor, tracking: "bulk", limit: 100).items)
          end

          def create(ctx)
            f = ctx.form
            transfer = uc(:request_transfer).call(ctx.actor, to_branch_id: f["destino_id"], asset_tag: blank(f["patrimonio"]), product_id: f["produto_id"],
                                                             from_branch_id: f["origem_id"], quantity: f["quantidade"], notes: f["observacoes"])
            redirect(ctx, "/transferencias", notice: "Transferência #{transfer.code} solicitada.")
          rescue *FORM_ERRORS => e
            index(ctx, errors: errors_of(e), status: status_of(e), values: f)
          rescue Domain::NotFound => e
            index(ctx, errors: { "base" => [e.message.capitalize] }, status: 404, values: f)
          end

          def dispatch_transfer(ctx) = transition(ctx, :dispatch_transfer, "Saída registrada; item em trânsito.")
          def receive(ctx) = transition(ctx, :receive_transfer, "Recebimento registrado na filial de destino.")

          def cancel(ctx)
            uc(:cancel_transfer).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/transferencias", notice: "Transferência cancelada.")
          rescue *FORM_ERRORS => e
            index(ctx, errors: errors_of(e), status: status_of(e))
          end

          private

          def transition(ctx, use_case, notice)
            uc(use_case).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/transferencias", notice: notice)
          rescue *FORM_ERRORS => e
            index(ctx, errors: errors_of(e), status: status_of(e))
          end
        end
      end
    end
  end
end
