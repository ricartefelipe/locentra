# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Apoio comum aos cadastros de condições comerciais: conversão dos campos de formulário reunindo
        # os erros de formato por campo e tradução de conflitos para a tela.
        module CommercialTermsForms
          private

          def blank(value) = value.to_s.strip.empty? ? nil : value.to_s.strip

          # Executa as conversões de cada campo e reúne as mensagens num único ValidationError.
          def collect(&) = Domain::Pricing::Input.collect(&)

          def stale?(error) = %w[stale_coupon stale_fee].include?(error.code)

          # Código já usado vira erro no campo; os demais conflitos aparecem no resumo.
          def conflict_errors(error)
            %w[coupon_code_taken fee_code_taken].include?(error.code) ? { "codigo" => [error.message] } : { "base" => [error.message] }
          end
        end

        # Cupons: lista com filtros, cadastro, detalhe com usos e histórico, edição dos campos editáveis
        # com controle otimista, desativação, reativação e exclusão (somente de cupom nunca usado).
        class CouponsController < Controller
          include CommercialTermsForms

          USES_PER_PAGE = 25

          def index(ctx)
            filters = %w[busca situacao ordem].to_h { |name| [name, ctx.query(name).to_s] }
            page = uc(:list_coupons).call(ctx.actor, status: blank(filters["situacao"]), search: filters["busca"],
                                                     sort: blank(filters["ordem"]) || "code", limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "coupons/index", title: "Cupons", page: page, filters: filters)
          end

          def new(ctx, errors: {}, status: 200, values: { "tipo" => "percent" })
            render(ctx, "coupons/new", title: "Novo cupom", status: status, values: values, errors: errors)
          end

          def create(ctx)
            coupon = uc(:create_coupon).call(ctx.actor, creation_attrs(ctx))
            redirect(ctx, "/cupons/#{coupon.id}", notice: "Cupom #{coupon.code} cadastrado.")
          rescue Domain::ValidationError => e
            new(ctx, errors: e.errors, status: 422, values: ctx.form)
          rescue Domain::Conflict => e
            new(ctx, errors: conflict_errors(e), status: 409, values: ctx.form)
          end

          # `values` são os dados enviados por uma edição recusada; sem eles o formulário mostra os
          # valores atuais (inclusive depois de uma edição concorrente).
          def show(ctx, errors: {}, status: 200, values: nil)
            data = uc(:get_coupon).call(ctx.actor, ctx.param(:id))
            redemptions = uc(:list_coupon_redemptions).call(ctx.actor, data[:coupon].id, limit: USES_PER_PAGE, offset: ctx.query("inicio_usos"))
            render(ctx, "coupons/show", title: "Cupom #{data[:coupon].code}", status: status, data: data, redemptions: redemptions, errors: errors,
                                        values: values)
          end

          def update(ctx)
            current = uc(:get_coupon).call(ctx.actor, ctx.param(:id))[:coupon]
            result = uc(:update_coupon).call(ctx.actor, current.id, revision_attrs(ctx, current), lock_version: ctx.form["versao"])
            redirect(ctx, "/cupons/#{result.record.id}", notice: result.changed ? "Cupom atualizado." : "Nenhuma alteração a salvar.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422, values: ctx.form)
          rescue Domain::Conflict => e
            show(ctx, errors: { "base" => [e.message] }, status: 409, values: stale?(e) ? nil : ctx.form)
          end

          def deactivate(ctx) = toggle(ctx, false, "Cupom desativado. Reservas já registradas não mudam.")
          def reactivate(ctx) = toggle(ctx, true, "Cupom reativado.")

          def destroy(ctx)
            uc(:delete_coupon).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/cupons", notice: "Cupom excluído.")
          rescue Domain::Conflict => e
            show(ctx, errors: { "base" => [e.message] }, status: 409)
          end

          private

          def toggle(ctx, active, notice)
            result = uc(:set_coupon_active).call(ctx.actor, ctx.param(:id), active: active)
            redirect(ctx, "/cupons/#{result.record.id}", notice: result.changed ? notice : "Nenhuma alteração a salvar.")
          end

          def creation_attrs(ctx)
            f = ctx.form
            collect do |check|
              { code: f["codigo"], kind: f["tipo"].to_s, value: check.call("valor") { discount_value(f["tipo"], f["valor"]) },
                description: f["descricao"] }.merge(editable_attrs(ctx, check))
            end
          end

          def revision_attrs(ctx, current)
            collect { |check| { description: ctx.form["descricao"] }.merge(editable_attrs(ctx, check, current)) }
          end

          def editable_attrs(ctx, check, current = nil)
            f = ctx.form
            { valid_from: check.call("valido_de") { instant(ctx, "valido_de", current&.valid_from) },
              valid_until: check.call("valido_ate") { instant(ctx, "valido_ate", current&.valid_until) },
              max_redemptions: blank(f["maximo_usos"]),
              min_subtotal_cents: check.call("subtotal_minimo") { money_param(f["subtotal_minimo"], "subtotal_minimo") } }
          end

          # O campo datetime-local não tem segundos: na edição, o instante atual é mantido quando o valor
          # enviado é o mesmo minuto (salvar sem mexer na vigência não a altera).
          def instant(ctx, field, current)
            parsed = optional_local_time(ctx, ctx.form[field], field)
            current && parsed && parsed.to_i == current.to_i - (current.to_i % 60) ? current : parsed
          end

          # Percentual em pontos-base ou valor fixo em centavos, conforme o tipo; tipo inválido e valor em
          # branco ficam para a validação do domínio.
          def discount_value(kind, value)
            case kind.to_s
            when "percent" then Domain::Percent.parse(value, "valor")
            when "fixed" then blank(value) && money!(blank(value), "valor")
            end
          end
        end
      end
    end
  end
end
