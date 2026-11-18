# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Contratos: lista, emissão a partir da reserva, detalhe com documentos, aditivos e aceite,
        # registro de aceite eletrônico simples, aditivo de extensão, cancelamento com prévia da multa
        # e encerramento.
        class ContractsController < Controller
          def index(ctx)
            page = uc(:list_contracts).call(ctx.actor, status: blank(ctx.query("situacao")), search: ctx.query("busca"),
                                                       limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "contracts/index", title: "Contratos", page: page, filter_status: ctx.query("situacao").to_s, search: ctx.query("busca").to_s)
          end

          def create(ctx)
            reservation_id = Domain::Identifier.parse(ctx.form["reserva_id"], "reserva")
            contract = uc(:issue_contract).call(ctx.actor, reservation_id, conditions: ctx.form["condicoes"])
            redirect(ctx, "/contratos/#{contract.id}", notice: "Contrato #{contract.code} emitido. Registre o aceite eletrônico simples do cliente.")
          rescue Domain::Conflict => e
            redirect(ctx, "/reservas/#{reservation_id}", alert: e.message)
          end

          def show(ctx, errors: {}, status: 200, shortages: [])
            data = uc(:get_contract).call(ctx.actor, ctx.param(:id))
            history = @system.uow.run(ctx.actor, "contracts.read") do |tx, _|
              @system.repos[:audit].for_resource(tx, "contract", data[:contract].id)
            end
            render(ctx, "contracts/show", title: "Contrato #{data[:contract].code}", status: status, data: data, history: history, errors: errors,
                                          shortages: shortages, now: @system.clock.now)
          end

          def accept(ctx)
            f = ctx.form
            uc(:accept_contract).call(ctx.actor, ctx.param(:id), name: f["nome"], document: f["documento"], user_agent: ctx.user_agent,
                                                                 confirmed: f["declaracao"] == "1")
            redirect(ctx, "/contratos/#{ctx.param(:id)}", notice: "Aceite eletrônico simples registrado.")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def amend(ctx)
            result = uc(:amend_contract).call(ctx.actor, ctx.param(:id), ends_at: local_time(ctx, ctx.form["fim"], "fim"),
                                                                         description: ctx.form["descricao"])
            redirect(ctx, "/contratos/#{ctx.param(:id)}",
                     notice: "Aditivo #{result[:amendment]["number"]} registrado (diferença #{result[:adjustment].format_brl}); " \
                             "documento versão #{result[:contract].current_document_version} gerado.")
          rescue Domain::Unavailable => e
            show(ctx, errors: { "base" => ["Aditivo recusado: #{e.message}. Nenhuma alteração foi feita."] }, status: 409, shortages: e.shortages)
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def cancel(ctx)
            result = uc(:cancel_contract).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/contratos/#{ctx.param(:id)}", notice: "Contrato cancelado. Multa aplicada: #{result[:preview].fee.format_brl}.")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def close(ctx)
            uc(:close_contract).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/contratos/#{ctx.param(:id)}", notice: "Contrato encerrado.")
          rescue Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value

          def errors_of(error) = error.is_a?(Domain::ValidationError) ? error.errors : { "base" => [error.message] }
        end
      end
    end
  end
end
