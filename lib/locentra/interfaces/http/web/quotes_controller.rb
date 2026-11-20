# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Orçamentos: lista, criação, detalhe com versões, envio, aprovação, rejeição, nova versão e
        # conversão em reserva.
        class QuotesController < Controller
          DEFAULT_VALIDITY_DAYS = 7

          def index(ctx)
            page = uc(:list_quotes).call(ctx.actor, status: blank(ctx.query("situacao")), search: ctx.query("busca"),
                                                    limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "quotes/index", title: "Orçamentos", page: page, filter_status: ctx.query("situacao").to_s, search: ctx.query("busca").to_s,
                                        now: @system.clock.now)
          end

          def new(ctx, errors: {}, status: 200, values: nil)
            render_form(ctx, "quotes/new", title: "Novo orçamento", status: status, errors: errors,
                                           values: values || defaults(ctx).merge(ctx.rack.GET.slice("cliente_id")))
          end

          def create(ctx)
            quote = uc(:create_quote).call(ctx.actor, input_from(ctx, customer: true))
            redirect(ctx, "/orcamentos/#{quote.id}", notice: "Orçamento #{quote.code} criado em rascunho (versão 1).")
          rescue Domain::ValidationError, Domain::NotFound, Domain::AccessDenied => e
            new(ctx, errors: errors_of(e), status: 422, values: ctx.form)
          end

          def show(ctx, errors: {}, status: 200, shortages: [])
            data = uc(:get_quote).call(ctx.actor, ctx.param(:id))
            selected = data[:versions].find { |v| v.number.to_s == ctx.query("versao").to_s } || data[:current]
            extras = @system.uow.run(ctx.actor, "quotes.read") do |tx, _|
              { history: @system.repos[:audit].for_resource(tx, "quote", data[:quote].id),
                attachments: @system.repos[:attachments].for_owner(tx, "quote", data[:quote].id) }
            end
            render(ctx, "quotes/show", title: "Orçamento #{data[:quote].code}", status: status, data: data, selected: selected, errors: errors,
                                       shortages: shortages, now: @system.clock.now, **extras)
          end

          def revision(ctx, errors: {}, status: 200, values: nil)
            data = uc(:get_quote).call(ctx.actor, ctx.param(:id))
            unless data[:quote].revisable?
              return redirect(ctx, "/orcamentos/#{data[:quote].id}", alert: "Orçamento #{data[:quote].status_label.downcase} não aceita nova versão.")
            end

            render_form(ctx, "quotes/revise", title: "Nova versão do orçamento #{data[:quote].code}", status: status, errors: errors, data: data,
                                              values: values || values_from(ctx, data[:quote], data[:current]))
          end

          def revise(ctx)
            quote = uc(:revise_quote).call(ctx.actor, ctx.param(:id), input_from(ctx, customer: false))
            redirect(ctx, "/orcamentos/#{quote.id}", notice: "Versão #{quote.current_version} criada. Envie o orçamento novamente ao cliente.")
          rescue Domain::ValidationError, Domain::NotFound, Domain::AccessDenied, Domain::InvalidTransition => e
            revision(ctx, errors: errors_of(e), status: 422, values: ctx.form)
          end

          def send_to_customer(ctx)
            quote = uc(:send_quote).call(ctx.actor, ctx.param(:id))
            notice = if quote.hold_reservation_id
                       "Orçamento enviado com bloqueio temporário de #{quote.hold_minutes} minutos."
                     else
                       "Orçamento enviado. Ele não garante disponibilidade até a conversão em reserva."
                     end
            redirect(ctx, "/orcamentos/#{quote.id}", notice: notice)
          rescue Domain::Unavailable => e
            show(ctx, errors: { "base" => [e.message] }, status: 409, shortages: e.shortages)
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::AccessDenied => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def approve(ctx)
            uc(:approve_quote).call(ctx.actor, ctx.param(:id), version: ctx.form["versao"], approver_name: ctx.form["aprovado_por"])
            redirect(ctx, "/orcamentos/#{ctx.param(:id)}", notice: "Aprovação da versão #{ctx.form["versao"]} registrada.")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def reject(ctx)
            uc(:reject_quote).call(ctx.actor, ctx.param(:id), version: ctx.form["versao"], reason: ctx.form["motivo"])
            redirect(ctx, "/orcamentos/#{ctx.param(:id)}", notice: "Rejeição registrada.")
          rescue Domain::ValidationError, Domain::InvalidTransition => e
            show(ctx, errors: errors_of(e), status: 422)
          rescue Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: 409)
          end

          def convert(ctx)
            result = uc(:convert_quote).call(ctx.actor, ctx.param(:id))
            prefix = result.created ? "Orçamento convertido" : "Orçamento já convertido"
            redirect(ctx, "/reservas/#{result.reservation.id}", notice: "#{prefix} na reserva #{result.reservation.code}.")
          rescue Domain::Unavailable => e
            show(ctx, errors: { "base" => [e.message] }, status: 409, shortages: e.shortages)
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::AccessDenied, Domain::HoldExpired => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          private

          def render_form(ctx, template, title:, status:, errors:, values:, data: nil)
            org = uc(:get_organization).call(ctx.actor)
            customers = data ? [] : uc(:list_customers).call(ctx.actor, status: "active", limit: 100).items
            products = uc(:list_products).call(ctx.actor, limit: 100).items.select(&:active)
            render(ctx, template, title: title, status: status, branches: org[:branches], customers: customers, products: products, values: values,
                                  errors: errors, data: data, hold_minutes: org[:organization].hold_minutes)
          end

          def defaults(ctx)
            validity = @system.clock.now + (DEFAULT_VALIDITY_DAYS * 86_400)
            { "politica_bloqueio" => "none", "validade" => ctx.time_zone.format_local(validity, "%Y-%m-%dT%H:%M") }
          end

          def values_from(ctx, quote, version)
            fmt = ->(time) { ctx.time_zone.format_local(time, "%Y-%m-%dT%H:%M") }
            { "filial_id" => version.branch_id, "inicio" => fmt.call(version.period.starts_at), "fim" => fmt.call(version.period.ends_at),
              "validade" => fmt.call(version.valid_until), "produto" => version.items.map { |i| i["product_id"] },
              "quantidade" => version.items.map { |i| i["quantity"].to_s }, "condicoes" => version.terms.to_s,
              "desconto" => percent_text(version.manual_discount_bps), "politica_bloqueio" => quote.hold_policy,
              "validade_bloqueio" => quote.hold_minutes.to_s }
          end

          def input_from(ctx, customer:)
            f = ctx.form
            input = { branch_id: f["filial_id"], period: period_from(ctx, f["inicio"], f["fim"]), lines: lines_from(f["produto"], f["quantidade"]),
                      valid_until: local_time(ctx, f["validade"], "validade"), terms: f["condicoes"], manual_discount_bps: discount_bps(f["desconto"]),
                      hold_policy: f["politica_bloqueio"].to_s, hold_minutes: blank(f["validade_bloqueio"]) }
            input[:customer_id] = f["cliente_id"] if customer
            input.compact
          end

          def blank(value) = value.to_s.empty? ? nil : value

          def errors_of(error) = error.is_a?(Domain::ValidationError) ? error.errors : { "base" => [error.message] }

          def discount_bps(value) = percent_bps(value, "desconto")

          def percent_text(bps) = bps.zero? ? "" : Domain::Percent.value(bps)
        end
      end
    end
  end
end
