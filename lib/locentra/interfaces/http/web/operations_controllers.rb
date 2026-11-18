# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        class CatalogController < Controller
          def index(ctx)
            page = uc(:list_products).call(ctx.actor, search: ctx.query("busca"), tracking: blank(ctx.query("tipo")),
                                                      limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "catalog/index", title: "Produtos e kits", page: page, search: ctx.query("busca").to_s, tracking: ctx.query("tipo").to_s)
          end

          def new(ctx)
            render(ctx, "catalog/new", title: "Novo produto", values: { "rastreamento" => "serialized", "modalidade_diaria" => "rolling_24h" }, errors: {})
          end

          def create(ctx)
            f = ctx.form
            product = uc(:create_product).call(ctx.actor, {
                                                 sku: f["sku"], name: f["nome"], tracking: f["rastreamento"], description: f["descricao"],
                                                 category: f["categoria"], buffer_before_minutes: f["preparacao_antes"].to_s,
                                                 buffer_after_minutes: f["preparacao_depois"].to_s, deposit: money_param(f["caucao"]),
                                                 replacement_cost: money_param(f["custo_reposicao"]), pricing: pricing_from(f)
                                               })
            redirect(ctx, "/produtos/#{product.id}", notice: "Produto cadastrado.")
          rescue Domain::ValidationError, Domain::Conflict => e
            render(ctx, "catalog/new", title: "Novo produto", status: 422, values: f, errors: errors_of(e))
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:get_product).call(ctx.actor, ctx.param(:id))
            org = uc(:get_organization).call(ctx.actor)
            components = data[:product].kit? ? uc(:list_products).call(ctx.actor, limit: 100).items.reject(&:kit?) : []
            render(ctx, "catalog/show", title: data[:product].name, status: status, data: data, branches: org[:branches],
                                        candidates: components, errors: errors)
          end

          def update_pricing(ctx)
            uc(:update_product_pricing).call(ctx.actor, ctx.param(:id), pricing: pricing_from(ctx.form), deposit: money_param(ctx.form["caucao"]))
            redirect(ctx, "/produtos/#{ctx.param(:id)}", notice: "Tabela de preços atualizada. Reservas existentes mantêm o preço contratado.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422)
          end

          def update_components(ctx)
            list = Array(ctx.form["componente"]).zip(Array(ctx.form["quantidade"])).filter_map do |id, qty|
              { product_id: id, quantity: qty } unless id.to_s.empty? || qty.to_s.strip.empty?
            end
            uc(:set_kit_components).call(ctx.actor, ctx.param(:id), list)
            redirect(ctx, "/produtos/#{ctx.param(:id)}", notice: "Composição do kit atualizada.")
          rescue Domain::ValidationError, Domain::NotFound => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def register_asset(ctx)
            f = ctx.form
            uc(:register_asset).call(ctx.actor, { product_id: ctx.param(:id), branch_id: f["filial_id"], tag: f["patrimonio"],
                                                  serial_number: f["numero_serie"], condition: f["condicao"].to_s,
                                                  acquisition_cost: money_param(f["custo_aquisicao"]), acquired_on: date_param(f["data_aquisicao"]) })
            redirect(ctx, "/produtos/#{ctx.param(:id)}", notice: "Ativo cadastrado.")
          rescue Domain::ValidationError, Domain::Conflict, Domain::PlanLimitExceeded => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def adjust_stock(ctx)
            f = ctx.form
            uc(:adjust_stock).call(ctx.actor, product_id: ctx.param(:id), branch_id: f["filial_id"], quantity: f["quantidade"].to_s,
                                              kind: f["movimento"].to_s, reason: f["motivo"])
            redirect(ctx, "/produtos/#{ctx.param(:id)}", notice: "Estoque atualizado.")
          rescue Domain::ValidationError, Domain::Conflict, Domain::PlanLimitExceeded => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          def assets(ctx)
            list = @system.uow.run(ctx.actor, "catalog.read") do |tx, _|
              @system.repos[:catalog].search_assets(tx, status: blank(ctx.query("situacao")))
            end
            render(ctx, "catalog/assets", title: "Ativos", assets: list, filter_status: ctx.query("situacao").to_s)
          end

          def asset(ctx, errors: {}, status: 200)
            data = uc(:get_asset).call(ctx.actor, ctx.param(:id))
            render(ctx, "catalog/asset", title: "Ativo #{data[:asset].tag}", status: status, data: data, errors: errors)
          end

          def change_asset_status(ctx)
            f = ctx.form
            until_time = f["indisponivel_ate"].to_s.empty? ? nil : local_time(ctx, f["indisponivel_ate"], "indisponivel_ate")
            uc(:change_asset_status).call(ctx.actor, ctx.param(:id), status: f["situacao"].to_s, reason: f["motivo"], unavailable_until: until_time)
            redirect(ctx, "/ativos/#{ctx.param(:id)}", notice: "Situação atualizada.")
          rescue Domain::ValidationError, Domain::Conflict, Domain::InvalidTransition => e
            asset(ctx, errors: errors_of(e), status: 422)
          end

          def block_asset(ctx)
            f = ctx.form
            uc(:block_availability).call(ctx.actor, asset_id: ctx.param(:id), period: period_from(ctx, f["inicio"], f["fim"]), reason: f["motivo"])
            redirect(ctx, "/ativos/#{ctx.param(:id)}", notice: "Bloqueio registrado.")
          rescue Domain::ValidationError, Domain::Unavailable => e
            asset(ctx, errors: errors_of(e), status: 422)
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value

          def errors_of(error)
            case error
            when Domain::ValidationError then error.errors
            when Domain::Unavailable then { "base" => ["Período indisponível: já existe alocação ou bloqueio."] }
            else { "base" => [error.message] }
            end
          end

          def date_param(value)
            value.to_s.empty? ? nil : Date.iso8601(value.to_s)
          rescue Date::Error
            raise Domain::ValidationError.field("data_aquisicao", "data inválida")
          end

          def cents(value)
            text = value.to_s.strip
            text.empty? ? nil : Domain::Money.parse(text).cents
          end

          def pricing_from(form)
            tiers = Array(form["faixa_minimo"]).zip(Array(form["faixa_desconto"])).filter_map do |min, pct|
              next if min.to_s.strip.empty? || pct.to_s.strip.empty?

              { "min_quantity" => min.to_s.strip, "discount_bps" => (BigDecimal(pct.to_s.tr(",", ".")) * 100).to_i }
            rescue ArgumentError
              raise Domain::ValidationError.field("faixas", "percentual inválido")
            end
            {
              "hourly_cents" => cents(form["preco_hora"]), "daily_cents" => cents(form["preco_diaria"]), "weekly_cents" => cents(form["preco_semana"]),
              "daily_mode" => form["modalidade_diaria"].to_s.empty? ? "rolling_24h" : form["modalidade_diaria"],
              "minimum_minutes" => form["periodo_minimo"].to_s.strip, "rounding_minutes" => form["arredondamento"].to_s.strip,
              "grace_minutes" => form["tolerancia"].to_s.strip, "quantity_tiers" => tiers
            }.reject { |_, v| v.nil? || v == "" }
          end
        end

        class AvailabilityController < Controller
          def calendar(ctx)
            org = uc(:get_organization).call(ctx.actor)
            branch = org[:branches].find { |b| b.id == ctx.query("filial") } || org[:branches].first
            start = parse_date(ctx.query("inicio")) || ctx.time_zone.local_date(@system.clock.now)
            days = (ctx.query("dias") || "7").to_s
            data = uc(:calendar).call(ctx.actor, branch_id: branch.id, start_date: start, days: days)
            render(ctx, "availability/calendar", title: "Disponibilidade", data: data, branches: org[:branches], branch: branch, start: start,
                                                 days: Integer(days, 10))
          end

          def check(ctx)
            org = uc(:get_organization).call(ctx.actor)
            products = uc(:list_products).call(ctx.actor, limit: 100).items
            result = nil
            errors = {}
            if ctx.query("inicio").to_s != ""
              begin
                result = uc(:check_availability).call(ctx.actor, branch_id: ctx.query("filial"),
                                                                 period: period_from(ctx, ctx.query("inicio"), ctx.query("fim")))
              rescue Domain::ValidationError => e
                errors = e.errors
              end
            end
            render(ctx, "availability/check", title: "Consultar disponibilidade", branches: org[:branches], products: products, result: result,
                                              values: ctx.rack.GET, errors: errors)
          end

          private

          def parse_date(value)
            value.to_s.empty? ? nil : Date.iso8601(value.to_s)
          rescue Date::Error
            nil
          end
        end

        class ReservationsController < Controller
          def index(ctx)
            page = uc(:list_reservations).call(ctx.actor, status: blank(ctx.query("situacao")), search: ctx.query("busca"),
                                                          sort: ctx.query("ordem") || "-starts_at", limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "reservations/index", title: "Reservas", page: page, filter_status: ctx.query("situacao").to_s, search: ctx.query("busca").to_s)
          end

          def new(ctx, errors: {}, status: 200, shortages: [])
            org = uc(:get_organization).call(ctx.actor)
            customers = uc(:list_customers).call(ctx.actor, status: "active", limit: 100).items
            products = uc(:list_products).call(ctx.actor, limit: 100).items.select(&:active)
            render(ctx, "reservations/new", title: "Nova reserva", status: status, branches: org[:branches], customers: customers, products: products,
                                            values: ctx.get? ? ctx.rack.GET : ctx.form, errors: errors, shortages: shortages,
                                            hold_minutes: org[:organization].hold_minutes)
          end

          def create(ctx)
            f = ctx.form
            reservation = uc(:create_reservation).call(ctx.actor, {
              customer_id: f["cliente_id"], branch_id: f["filial_id"], period: period_from(ctx, f["inicio"], f["fim"]),
              lines: lines_from(f["produto"], f["quantidade"]), mode: f["modo"].to_s,
              hold_minutes: f["validade_bloqueio"].to_s.empty? ? nil : f["validade_bloqueio"],
              notes: f["observacoes"], coupon_code: f["cupom"],
              manual_discount_bps: discount_bps(f["desconto"])
            }.compact)
            redirect(ctx, "/reservas/#{reservation.id}", notice: "Reserva #{reservation.code} registrada (#{reservation.status_label}).")
          rescue Domain::Unavailable => e
            new(ctx, errors: { "base" => [e.message] }, status: 409, shortages: e.shortages)
          rescue Domain::ValidationError, Domain::NotFound, Domain::AccessDenied => e
            new(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          def show(ctx, errors: {}, status: 200, shortages: [])
            data = uc(:get_reservation).call(ctx.actor, ctx.param(:id))
            customer = uc(:get_customer).call(ctx.actor, data[:reservation].customer_id)[:customer]
            history = @system.uow.run(ctx.actor, "reservations.read") do |tx, _|
              @system.repos[:audit].for_resource(tx, "reservation", data[:reservation].id)
            end
            operations = uc(:reservation_operations).call(ctx.actor, data[:reservation].id)
            links = uc(:reservation_links).call(ctx.actor, data[:reservation].id)
            finance = ctx.can?("finance.read") ? uc(:finance).reservation(ctx.actor, data[:reservation].id) : nil
            render(ctx, "reservations/show", title: "Reserva #{data[:reservation].code}", status: status, data: data, customer: customer,
                                             history: history, errors: errors, shortages: shortages, now: @system.clock.now,
                                             operations: operations, links: links, finance: finance)
          end

          def confirm(ctx)
            reservation = uc(:confirm_reservation).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/reservas/#{reservation.id}", notice: "Reserva confirmada com disponibilidade revalidada.")
          rescue Domain::Unavailable => e
            show(ctx, errors: { "base" => ["Confirmação recusada: #{e.message}"] }, status: 409, shortages: e.shortages)
          rescue Domain::HoldExpired
            redirect(ctx, "/reservas/#{ctx.param(:id)}", alert: "O bloqueio temporário expirou; a reserva não pode ser confirmada.")
          rescue Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: { "base" => [e.message] }, status: 422)
          end

          def cancel(ctx)
            uc(:cancel_reservation).call(ctx.actor, ctx.param(:id), reason: ctx.form["motivo"])
            redirect(ctx, "/reservas/#{ctx.param(:id)}", notice: "Reserva cancelada.")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          def reschedule(ctx)
            uc(:reschedule_reservation).call(ctx.actor, ctx.param(:id), period: period_from(ctx, ctx.form["inicio"], ctx.form["fim"]))
            redirect(ctx, "/reservas/#{ctx.param(:id)}", notice: "Reserva reagendada.")
          rescue Domain::Unavailable => e
            show(ctx, errors: { "base" => ["Reagendamento recusado: período indisponível. A reserva permanece no período original."] }, status: 409,
                      shortages: e.shortages)
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          def extend_period(ctx)
            result = uc(:extend_reservation).call(ctx.actor, ctx.param(:id), ends_at: local_time(ctx, ctx.form["fim"], "fim"))
            redirect(ctx, "/reservas/#{ctx.param(:id)}", notice: "Reserva estendida. Ajuste registrado: #{result[:adjustment].format_brl}.")
          rescue Domain::Unavailable => e
            show(ctx, errors: { "base" => ["Extensão recusada: #{e.message}."] }, status: 409, shortages: e.shortages)
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value

          def discount_bps(value)
            text = value.to_s.strip.tr(",", ".")
            return 0 if text.empty?

            (BigDecimal(text) * 100).to_i
          rescue ArgumentError
            raise Domain::ValidationError.field("desconto", "percentual inválido")
          end
        end
      end
    end
  end
end
