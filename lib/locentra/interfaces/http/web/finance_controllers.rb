# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Conversões e erros compartilhados pelas telas do financeiro.
        module FinanceForms
          FAILURES = [Domain::ValidationError, Domain::Conflict, Domain::InvalidTransition, Domain::PlanLimitExceeded].freeze

          private

          def blank(value) = value.to_s.strip.empty? ? nil : value.to_s.strip

          def errors_of(error) = error.is_a?(Domain::ValidationError) ? error.errors : { "base" => [error.message] }

          def date_param(value, field)
            text = blank(value)
            text && Date.iso8601(text)
          rescue Date::Error
            raise Domain::ValidationError.field(field, "data inválida")
          end

          def optional_time(ctx, value, field)
            blank(value) && local_time(ctx, value, field)
          end

          def back_to(ctx, fallback)
            target = ctx.form["voltar"].to_s
            target.start_with?("/financeiro", "/reservas") ? target : fallback
          end
        end

        class FinanceController < Controller
          include FinanceForms

          def index(ctx, errors: {}, status: 200)
            data = uc(:finance).overview(ctx.actor, status: blank(ctx.query("situacao")), limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "finance/index", title: "Financeiro", status: status, data: data, filter_status: ctx.query("situacao").to_s, errors: errors)
          end

          # A conciliação consulta o provedor fora de transação e grava o relatório.
          def reconcile(ctx)
            result = uc(:reconcile_payments).call(ctx.actor)
            return redirect(ctx, "/financeiro", alert: "Configure um provedor de pagamentos para conciliar.") if result == :no_account

            redirect(ctx, "/financeiro/conciliacao/#{result}", notice: "Conciliação concluída.")
          end

          def report(ctx)
            data = uc(:finance).report(ctx.actor, ctx.param(:id))
            render(ctx, "finance/reconciliation", title: "Conciliação", data: data)
          end

          def resolve_alert(ctx)
            uc(:resolve_finance_alert).call(ctx.actor, ctx.param(:id), resolution: ctx.form["decisao"].to_s, notes: ctx.form["observacao"])
            redirect(ctx, back_to(ctx, "/financeiro"), notice: "Decisão registrada.")
          rescue *FAILURES => e
            redirect(ctx, back_to(ctx, "/financeiro"), alert: e.message)
          end

          def provider(ctx, errors: {}, status: 200, created: nil)
            render(ctx, "finance/provider", title: "Provedor de pagamentos", status: status, accounts: uc(:finance).accounts(ctx.actor),
                                            errors: errors, created: created, base_url: @system.config.base_url)
          end

          def configure_provider(ctx)
            f = ctx.form
            created = uc(:configure_payment_account).call(ctx.actor, provider: f["provedor"].to_s, name: f["nome"], api_key: f["chave_api"],
                                                                     environment: f["ambiente"].to_s.empty? ? "sandbox" : f["ambiente"].to_s)
            provider(ctx, created: created)
          rescue *FAILURES => e
            provider(ctx, errors: errors_of(e), status: 422)
          end

          def deactivate_provider(ctx)
            uc(:deactivate_payment_account).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/financeiro/provedor", notice: "Conta do provedor desativada.")
          end
        end

        class ReceivablesController < Controller
          include FinanceForms

          def show(ctx, errors: {}, status: 200)
            data = uc(:finance).receivable(ctx.actor, ctx.param(:id))
            render(ctx, "finance/receivable", title: data[:receivable].description, status: status, data: data, errors: errors,
                                              today: ctx.time_zone.local_date(@system.clock.now))
          end

          def register_payment(ctx)
            f = ctx.form
            uc(:register_payment).call(ctx.actor, { purpose: "receivable", receivable_id: ctx.param(:id), method: f["metodo"].to_s,
                                                    amount: money_param(f["valor"]), paid_at: optional_time(ctx, f["pago_em"], "pago_em"),
                                                    notes: f["observacoes"] })
            redirect(ctx, "/financeiro/cobrancas/#{ctx.param(:id)}", notice: "Pagamento registrado.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def request_payment(ctx)
            f = ctx.form
            payment = uc(:request_payment).call(ctx.actor, { purpose: "receivable", receivable_id: ctx.param(:id), method: f["metodo"].to_s,
                                                             amount: money_param(f["valor"]), due_on: date_param(f["vencimento"], "vencimento"),
                                                             scenario: f["cenario"], notes: f["observacoes"] })
            redirect(ctx, "/financeiro/pagamentos/#{payment.id}", notice: "Cobrança enviada ao provedor em segundo plano.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def cancel(ctx)
            uc(:cancel_receivable).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/financeiro/cobrancas/#{ctx.param(:id)}", notice: "Cobrança cancelada por operação compensatória.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def sync(ctx)
            created = uc(:sync_reservation_charges).call(ctx.actor, ctx.param(:id), prepayment: ctx.form["antecipada"] == "1")
            notice = created.empty? ? "Nenhuma cobrança nova: as cobranças da reserva já estão sincronizadas." : "#{created.size} cobrança(s) criada(s)."
            redirect(ctx, "/reservas/#{ctx.param(:id)}", notice: notice)
          end

          def create_charge(ctx)
            f = ctx.form
            uc(:create_manual_charge).call(ctx.actor, ctx.param(:id), kind: f["tipo"].to_s, amount: money_param(f["valor"]), description: f["descricao"],
                                                                      due_on: date_param(f["vencimento"], "vencimento"))
            redirect(ctx, "/reservas/#{ctx.param(:id)}", notice: "Cobrança adicional registrada.")
          rescue *FAILURES => e
            redirect(ctx, "/reservas/#{ctx.param(:id)}", alert: "Cobrança não registrada: #{e.message}")
          end

          def issue_invoice(ctx)
            invoice = uc(:issue_invoice).call(ctx.actor, ctx.param(:id), notes: ctx.form["observacoes"])
            redirect(ctx, "/financeiro/faturas/#{invoice["id"]}", notice: "Fatura #{invoice["number"]} emitida.")
          rescue *FAILURES => e
            redirect(ctx, "/reservas/#{ctx.param(:id)}", alert: "Fatura não emitida: #{e.message}")
          end

          def invoice(ctx)
            invoice = uc(:finance).invoice(ctx.actor, ctx.param(:id))
            render(ctx, "finance/invoice", title: "Fatura #{invoice["number"]}", invoice: invoice)
          end
        end

        class PaymentsController < Controller
          include FinanceForms

          def show(ctx, errors: {}, status: 200)
            data = uc(:finance).payment(ctx.actor, ctx.param(:id))
            render(ctx, "finance/payment", title: "Pagamento", status: status, data: data, errors: errors)
          end

          def refund(ctx)
            uc(:request_refund).call(ctx.actor, ctx.param(:id), amount: money_param(ctx.form["valor"]), reason: ctx.form["motivo"])
            redirect(ctx, "/financeiro/pagamentos/#{ctx.param(:id)}", notice: "Reembolso registrado.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          # Simulador local: marca a cobrança como paga e emite o webhook correspondente.
          def simulate(ctx)
            result = uc(:simulate_payment).call(ctx.actor, ctx.param(:id))
            notice = result == :duplicate ? "Evento repetido descartado (já recebido)." : "Pagamento simulado; o webhook será processado em segundo plano."
            redirect(ctx, "/financeiro/pagamentos/#{ctx.param(:id)}", notice: notice)
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end
        end

        class DepositsController < Controller
          include FinanceForms

          def create(ctx)
            f = ctx.form
            amount = blank(f["valor"]) && money_param(f["valor"])
            deposit = uc(:open_deposit).call(ctx.actor, ctx.param(:id), kind: f["tipo"].to_s, amount: amount, notes: f["observacoes"])
            redirect(ctx, "/financeiro/caucoes/#{deposit.id}", notice: "Caução registrada. Registre o recebimento para retê-la.")
          rescue *FAILURES => e
            redirect(ctx, "/reservas/#{ctx.param(:id)}", alert: "Caução não registrada: #{e.message}")
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:finance).deposit(ctx.actor, ctx.param(:id))
            render(ctx, "finance/deposit", title: "Caução", status: status, data: data, errors: errors)
          end

          def receive(ctx)
            f = ctx.form
            uc(:register_payment).call(ctx.actor, { purpose: "deposit", deposit_id: ctx.param(:id), method: f["metodo"].to_s, amount: money_param(f["valor"]),
                                                    paid_at: optional_time(ctx, f["pago_em"], "pago_em"), notes: f["observacoes"] })
            redirect(ctx, "/financeiro/caucoes/#{ctx.param(:id)}", notice: "Recebimento da caução registrado.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def request_payment(ctx)
            f = ctx.form
            payment = uc(:request_payment).call(ctx.actor, { purpose: "deposit", deposit_id: ctx.param(:id), method: f["metodo"].to_s,
                                                             amount: money_param(f["valor"]), due_on: date_param(f["vencimento"], "vencimento"),
                                                             scenario: f["cenario"] })
            redirect(ctx, "/financeiro/pagamentos/#{payment.id}", notice: "Cobrança da caução enviada ao provedor em segundo plano.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def apply(ctx)
            uc(:move_deposit).apply(ctx.actor, ctx.param(:id), receivable_id: ctx.form["cobranca_id"], amount: money_param(ctx.form["valor"]))
            redirect(ctx, "/financeiro/caucoes/#{ctx.param(:id)}", notice: "Caução aplicada à cobrança.")
          rescue *FAILURES, Domain::NotFound => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def give_back(ctx)
            uc(:move_deposit).give_back(ctx.actor, ctx.param(:id), amount: money_param(ctx.form["valor"]), method: ctx.form["metodo"].to_s,
                                                                   notes: ctx.form["observacoes"])
            redirect(ctx, "/financeiro/caucoes/#{ctx.param(:id)}", notice: "Devolução da caução registrada.")
          rescue *FAILURES => e
            show(ctx, errors: errors_of(e), status: 422)
          end
        end

        # Webhook público do provedor: autenticado pelo token da conta (cabeçalho asaas-access-token),
        # persistido e deduplicado antes de qualquer processamento.
        class PaymentWebhooksController < Controller
          def receive(ctx)
            result = uc(:ingest_payment_webhook).call(ctx.param(:conta_id), token: ctx.env["HTTP_ASAAS_ACCESS_TOKEN"].to_s, body: ctx.body_bytes,
                                                                            request_id: ctx.request_id)
            json(200, { "status" => result.to_s })
          rescue Application::Finance::WebhookUnauthorized
            json(401, { "error" => { "code" => "unauthorized", "message" => "token de webhook inválido", "details" => {}, "request_id" => ctx.request_id } })
          end
        end
      end
    end
  end
end
