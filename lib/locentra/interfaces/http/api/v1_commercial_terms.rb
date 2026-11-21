# frozen_string_literal: true

require_relative "../../commercial_terms_serializers"
require_relative "v1"

module Locentra
  module Interfaces
    module HTTP
      module API
        # Condições comerciais na API v1: cupons, tarifas adicionais e condições negociadas por cliente.
        #
        # Toda mutação exige `Idempotency-Key` e roda na mesma transação da chave. As rotas de mutação
        # aceitam somente o identificador (UUID): assim cada recurso tem um único escopo de idempotência.
        # As consultas de cupom e de tarifa aceitam também o código. Números são inteiros do JSON
        # (pontos-base e centavos) e instantes usam ISO 8601 com fuso; os erros de formato são reunidos
        # por campo, com os mesmos nomes de campo das validações do domínio.
        class CommercialTermsV1Controller < V1Controller
          CS = CommercialTermsSerializers
          P = Domain::Pricing
          # Campos que não mudam depois do cadastro: chave da API => campo do erro.
          IMMUTABLE_COUPON = { "code" => "codigo", "kind" => "tipo", "discount_bps" => "valor", "discount_cents" => "valor" }.freeze
          DISCOUNT_KEYS = { "percent" => %w[discount_bps discount_cents], "fixed" => %w[discount_cents discount_bps] }.freeze

          # Cupons ---------------------------------------------------------------------------------

          def coupons(ctx)
            page = uc(:list_coupons).call(ctx.actor, status: ctx.query("status"), search: ctx.query("q"), sort: ctx.query("sort") || "code",
                                                     limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |row| CS.coupon(row[:coupon], row[:status]) })
          end

          def coupon(ctx)
            data = uc(:get_coupon).call(ctx.actor, ctx.param(:id))
            json(200, CS.coupon(data[:coupon], data[:status]))
          end

          def create_coupon(ctx)
            data = ctx.json
            attrs = coupon_input(data)
            idempotent(ctx, "coupons.write", "POST /api/v1/coupons", data, location: ->(body) { "/api/v1/coupons/#{body["id"]}" }) do |tx, actor|
              [201, coupon_body(uc(:create_coupon).call(actor, attrs, tx: tx))]
            end
          end

          # Chave presente altera o campo; `null` limpa (no subtotal mínimo, vale 0). Sem mudança, devolve
          # o cupom como está, sem auditoria.
          def update_coupon(ctx)
            data = ctx.json
            id = resource_id(ctx)
            attrs, version = coupon_patch(data)
            idempotent(ctx, "coupons.write", "PATCH /api/v1/coupons/#{id}", data) do |tx, actor|
              [200, coupon_body(uc(:update_coupon).call(actor, id, attrs, lock_version: version, tx: tx).record)]
            end
          end

          def deactivate_coupon(ctx) = toggle_coupon(ctx, false, "deactivate")
          def reactivate_coupon(ctx) = toggle_coupon(ctx, true, "reactivate")

          def coupon_redemptions(ctx)
            page = uc(:list_coupon_redemptions).call(ctx.actor, ctx.param(:id), limit: ctx.query("limit"), offset: ctx.query("offset"))
            reservations = ctx.can?("reservations.read")
            customers = Application::Reservations::ListReservations.customer_names?(ctx.actor)
            json(200, S.page(page) { |item| CS.coupon_redemption(item, reservations: reservations, customers: customers) })
          end

          # Tarifas adicionais ----------------------------------------------------------------------

          def fees(ctx)
            page = uc(:list_fees).call(ctx.actor, status: ctx.query("status"), search: ctx.query("q"), sort: ctx.query("sort") || "name",
                                                  limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |fee| CS.fee(fee) })
          end

          def fee(ctx)
            json(200, CS.fee(uc(:get_fee).call(ctx.actor, ctx.param(:id))[:fee]))
          end

          def create_fee(ctx)
            data = ctx.json
            attrs = fee_input(data)
            idempotent(ctx, "fees.write", "POST /api/v1/fees", data, location: ->(body) { "/api/v1/fees/#{body["id"]}" }) do |tx, actor|
              [201, CS.fee(uc(:create_fee).call(actor, attrs, tx: tx))]
            end
          end

          def update_fee(ctx)
            data = ctx.json
            id = resource_id(ctx)
            attrs, version = fee_patch(data)
            idempotent(ctx, "fees.write", "PATCH /api/v1/fees/#{id}", data) do |tx, actor|
              [200, CS.fee(uc(:update_fee).call(actor, id, attrs, lock_version: version, tx: tx).record)]
            end
          end

          def deactivate_fee(ctx) = toggle_fee(ctx, false, "deactivate")
          def reactivate_fee(ctx) = toggle_fee(ctx, true, "reactivate")

          # Condições negociadas ----------------------------------------------------------------------

          def price_agreements(ctx)
            page = uc(:list_price_agreements).call(ctx.actor, ctx.param(:id), limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |row| CS.price_agreement(row[:agreement], row[:status], product: row[:product]) })
          end

          def create_price_agreement(ctx)
            data = ctx.json
            customer_id = Domain::Identifier.parse(ctx.param(:id), "cliente")
            attrs = agreement_input(data)
            idempotent(ctx, "price_agreements.write", "POST /api/v1/customers/#{customer_id}/price-agreements", data) do |tx, actor|
              [201, agreement_body(uc(:create_price_agreement).call(actor, customer_id, attrs, tx: tx))]
            end
          end

          # Encerramento único: imediato (sem `effective_at`) ou agendado.
          def end_price_agreement(ctx)
            data = ctx.json
            id = ctx.param(:id).to_s.downcase
            reason, at = collect do |check|
              [check.call("motivo") { strict_text(data, "reason", "motivo") }, check.call("encerrar_em") { api_instant(data, "effective_at", "encerrar_em") }]
            end
            idempotent(ctx, "price_agreements.write", "POST /api/v1/price-agreements/#{id}/end", data) do |tx, actor|
              [200, agreement_body(uc(:end_price_agreement).call(actor, id, reason: reason, at: at, tx: tx))]
            end
          end

          private

          def now = @system.clock.now

          def coupon_body(coupon) = CS.coupon(coupon, coupon.status(now))

          def agreement_body(agreement) = CS.price_agreement(agreement, agreement.status(now))

          def collect(&) = P::Input.collect(&)

          # Mutações aceitam somente o identificador: o código vale nas consultas.
          def resource_id(ctx)
            id = ctx.param(:id).to_s.downcase
            return id if Domain::Identifier.valid?(id)

            raise Domain::ValidationError.field("id", "use o identificador (UUID) nas alterações; o código é aceito somente nas consultas")
          end

          # Campos presentes no corpo do PATCH e versão do controle otimista (opcional), com os erros de
          # formato reunidos. O bloco preenche `attrs` somente com as chaves enviadas.
          def patch_input(data)
            collect do |check|
              attrs = {}
              yield check, attrs
              [attrs, check.call("lock_version") { strict_integer(data, "lock_version", "lock_version", min: 1) }]
            end
          end

          def toggle_coupon(ctx, active, action)
            id = resource_id(ctx)
            idempotent(ctx, "coupons.write", "POST /api/v1/coupons/#{id}/#{action}", {}) do |tx, actor|
              [200, coupon_body(uc(:set_coupon_active).call(actor, id, active: active, tx: tx).record)]
            end
          end

          def toggle_fee(ctx, active, action)
            id = resource_id(ctx)
            idempotent(ctx, "fees.write", "POST /api/v1/fees/#{id}/#{action}", {}) do |tx, actor|
              [200, CS.fee(uc(:set_fee_active).call(actor, id, active: active, tx: tx).record)]
            end
          end

          def coupon_input(data)
            collect do |check|
              { code: check.call("codigo") { strict_text(data, "code", "codigo") }, kind: data["kind"].to_s,
                value: check.call("valor") { coupon_value(data) },
                description: check.call("descricao") { strict_text(data, "description", "descricao") },
                valid_from: check.call("valido_de") { api_instant(data, "valid_from", "valido_de") },
                valid_until: check.call("valido_ate") { api_instant(data, "valid_until", "valido_ate") },
                max_redemptions: check.call("maximo_usos") { strict_integer(data, "max_redemptions", "maximo_usos") },
                min_subtotal_cents: check.call("subtotal_minimo") { strict_integer(data, "min_subtotal_cents", "subtotal_minimo") } }
            end
          end

          # Exatamente um entre `discount_bps` (percent) e `discount_cents` (fixed), conforme o tipo. Tipo
          # inválido fica para a validação do domínio.
          def coupon_value(data)
            expected, other = DISCOUNT_KEYS[data["kind"].to_s]
            return nil unless expected
            if data[expected].nil? || !data[other].nil?
              raise Domain::ValidationError.field("valor", "o tipo #{data["kind"]} exige #{expected} (e não aceita #{other})")
            end

            strict_integer(data, expected, "valor", allow_nil: false)
          end

          def coupon_patch(data)
            patch_input(data) do |check, attrs|
              IMMUTABLE_COUPON.each { |key, field| check.call(field) { immutable!(data, key, field) } }
              attrs[:description] = check.call("descricao") { strict_text(data, "description", "descricao") } if data.key?("description")
              { "valid_from" => "valido_de", "valid_until" => "valido_ate" }.each do |key, field|
                attrs[key.to_sym] = check.call(field) { api_instant(data, key, field) } if data.key?(key)
              end
              { "max_redemptions" => "maximo_usos", "min_subtotal_cents" => "subtotal_minimo" }.each do |key, field|
                attrs[key.to_sym] = check.call(field) { strict_integer(data, key, field) } if data.key?(key)
              end
            end
          end

          def immutable!(data, key, field)
            raise Domain::ValidationError.field(field, "#{key} não pode ser alterado") if data.key?(key)
          end

          def fee_input(data)
            collect do |check|
              { code: check.call("codigo") { strict_text(data, "code", "codigo") }, name: check.call("nome") { strict_text(data, "name", "nome") },
                description: check.call("descricao") { strict_text(data, "description", "descricao") },
                default_amount: check.call("valor_padrao") { fee_amount(data) } }
            end
          end

          def fee_patch(data)
            patch_input(data) do |check, attrs|
              check.call("codigo") { immutable!(data, "code", "codigo") }
              attrs[:name] = check.call("nome") { strict_text(data, "name", "nome") } if data.key?("name")
              attrs[:description] = check.call("descricao") { strict_text(data, "description", "descricao") } if data.key?("description")
              attrs[:default_amount] = check.call("valor_padrao") { fee_amount(data) } if data.key?("default_amount_cents")
            end
          end

          # O valor padrão ausente ou nulo fica para a validação do domínio ("valor positivo").
          def fee_amount(data)
            cents = strict_integer(data, "default_amount_cents", "valor_padrao", max: Domain::Money::MAX_CENTS)
            cents && Domain::Money.new([cents, 0].max)
          end

          # `product_id` nulo ou ausente cadastra a condição geral; pela API o produto é sempre o identificador.
          def agreement_input(data)
            collect do |check|
              { product: check.call("produto") { data["product_id"].nil? ? nil : Domain::Identifier.parse(data["product_id"], "produto") },
                discount_bps: check.call("desconto") { strict_integer(data, "discount_bps", "desconto") },
                valid_from: check.call("valido_de") { api_instant(data, "valid_from", "valido_de") },
                valid_until: check.call("valido_ate") { api_instant(data, "valid_until", "valido_ate") },
                notes: check.call("observacoes") { strict_text(data, "notes", "observacoes") } }
            end
          end
        end
      end
    end
  end
end
