# frozen_string_literal: true

require_relative "../../organization_serializers"

module Locentra
  module Interfaces
    module HTTP
      module API
        # Serialização explícita dos recursos expostos pela API v1.
        module Serializers
          module_function

          def money(value) = value.to_h

          def customer(customer)
            { "id" => customer.id, "kind" => customer.kind, "name" => customer.name, "document" => customer.formatted_document,
              "email" => customer.email, "phone" => customer.phone, "status" => customer.status }
          end

          def product(product)
            { "id" => product.id, "sku" => product.sku, "name" => product.name, "tracking" => product.tracking, "category" => product.category,
              "buffer_before_minutes" => product.buffer_before_minutes, "buffer_after_minutes" => product.buffer_after_minutes,
              "deposit" => money(product.deposit), "pricing" => product.pricing, "active" => product.active }
          end

          def reservation(reservation)
            { "id" => reservation.id, "code" => reservation.code, "status" => reservation.status, "source" => reservation.source,
              "customer_id" => reservation.customer_id, "branch_id" => reservation.branch_id, "period" => reservation.period.to_h,
              "hold_expires_at" => reservation.hold_expires_at&.iso8601, "total" => money(reservation.total),
              "deposit" => money(reservation.deposit), "version" => reservation.version }
          end

          # Detalhe da reserva: itens com snapshot de preço, alocações ativas, ajustes e a política de
          # cancelamento congelada na criação.
          def reservation_details(data)
            items = data[:items].map do |i|
              { "product_id" => i["product_id"], "sku" => i["sku"], "quantity" => i["quantity"], "pricing" => i["pricing"] }
            end
            assets = data[:allocations][:assets].select { |a| a["active"] }.map { |a| { "asset_id" => a["asset_id"], "tag" => a["tag"] } }
            stock = data[:allocations][:stock].select { |s| s["active"] }.map { |s| { "product_id" => s["product_id"], "quantity" => s["quantity"] } }
            reservation(data[:reservation]).merge("items" => items, "allocations" => { "assets" => assets, "stock" => stock },
                                                  "pricing" => data[:pricing][:summary], "adjustments" => data[:pricing][:adjustments],
                                                  "cancellation_policy" => data[:cancellation_policy])
          end

          def page(page, &)
            { "data" => page.items.map(&), "pagination" => { "limit" => page.limit, "offset" => page.offset, "total" => page.total,
                                                             "next_offset" => page.next_offset } }
          end
        end

        class V1Controller < Controller
          S = Serializers
          FEES_FORMAT = "deve ser uma lista de objetos com fee_id ou description e amount_cents"

          def availability(ctx)
            ids = ctx.query("product_ids").to_s.split(",").map(&:strip).reject(&:empty?)
            period = Domain::Period.parse(ctx.query("starts_at"), ctx.query("ends_at"))
            rows = uc(:check_availability).call(ctx.actor, branch_id: ctx.query("branch_id"), period: period, product_ids: ids.empty? ? nil : ids)
            json(200, { "period" => period.to_h, "data" => rows.map do |row|
              { "product_id" => row["product"].id, "sku" => row["product"].sku, "tracking" => row["product"].tracking,
                "available" => row["available"], "total" => row["total"] }
            end })
          end

          # Organização do token (escopo `organization.read`): configurações e filiais. Não há alteração pela
          # API: a troca de fuso exige confirmação humana na interface web.
          def organization(ctx)
            data = uc(:read_organization).call(ctx.actor)
            json(200, OrganizationSerializers.organization(data[:organization], data[:branches]))
          end

          def customers(ctx)
            page = uc(:list_customers).call(ctx.actor, search: ctx.query("q"), status: ctx.query("status"), limit: ctx.query("limit"),
                                                       offset: ctx.query("offset"), sort: ctx.query("sort") || "name")
            json(200, S.page(page) { |c| S.customer(c) })
          end

          def create_customer(ctx)
            data = ctx.json
            customer = uc(:create_customer).call(ctx.actor, { kind: data["kind"].to_s, name: data["name"], document: data["document"],
                                                              email: data["email"], phone: data["phone"], trade_name: data["trade_name"] })
            json(201, S.customer(customer), "location" => "/api/v1/customers/#{customer.id}")
          end

          def customer(ctx)
            json(200, S.customer(uc(:get_customer).call(ctx.actor, ctx.param(:id))[:customer]))
          end

          def products(ctx)
            page = uc(:list_products).call(ctx.actor, search: ctx.query("q"), tracking: ctx.query("tracking"), limit: ctx.query("limit"),
                                                      offset: ctx.query("offset"))
            json(200, S.page(page) { |p| S.product(p) })
          end

          def reservations(ctx)
            page = uc(:list_reservations).call(ctx.actor, status: ctx.query("status"), customer_id: ctx.query("customer_id"),
                                                          sort: ctx.query("sort") || "-starts_at", limit: ctx.query("limit"), offset: ctx.query("offset"))
            json(200, S.page(page) { |row| S.reservation(row[:reservation]) })
          end

          def reservation(ctx)
            data = uc(:get_reservation).call(ctx.actor, ctx.param(:id))
            json(200, S.reservation_details(data))
          end

          # Criação idempotente: exige Idempotency-Key. Tarifas (`fees`): do catálogo pelo valor padrão com
          # `reservations.write`; valor diferente do padrão e tarifa avulsa exigem `fees.override`.
          def create_reservation(ctx)
            data = ctx.json
            lines = api_lines(data["items"])
            fees = api_fees(data["fees"])
            idempotent(ctx, "reservations.write", "POST /api/v1/reservations", data) do |tx, actor|
              reservation = uc(:create_reservation).call(actor, {
                customer_id: data["customer_id"], branch_id: data["branch_id"], period: api_period(data),
                lines: lines, fees: fees, mode: (data["mode"] || "hold").to_s, hold_minutes: data["hold_minutes"],
                notes: data["notes"], coupon_code: data["coupon_code"], source: "api"
              }.compact, tx: tx)
              [201, S.reservation(reservation)]
            end
          end

          # Bloqueio vencido: a transação composta com a idempotência é desfeita junto com a expiração
          # gravada nela; a confirmação isolada grava a expiração (com evento e auditoria) e responde 409.
          def confirm_reservation(ctx)
            idempotent(ctx, "reservations.write", "POST /api/v1/reservations/#{ctx.param(:id)}/confirm", {}) do |tx, actor|
              [200, S.reservation(uc(:confirm_reservation).call(actor, ctx.param(:id), tx: tx))]
            end
          rescue Domain::HoldExpired
            uc(:confirm_reservation).call(ctx.actor, ctx.param(:id))
          end

          def cancel_reservation(ctx)
            data = ctx.json
            idempotent(ctx, "reservations.cancel", "POST /api/v1/reservations/#{ctx.param(:id)}/cancel", data) do |tx, actor|
              [200, S.reservation(uc(:cancel_reservation).call(actor, ctx.param(:id), reason: data["reason"], tx: tx))]
            end
          end

          def openapi(_ctx)
            [200, { "content-type" => "application/yaml; charset=utf-8", "cache-control" => "public, max-age=300" },
             [File.read(File.join(App::ROOT, "docs/openapi.yaml"))]]
          end

          private

          # `items` precisa ser uma lista de objetos; outro formato é erro de validação (422).
          def api_lines(items)
            list = items.nil? ? [] : items
            raise Domain::ValidationError.field("items", "deve ser uma lista de objetos com product_id e quantity") unless list.is_a?(Array) && list.all?(Hash)

            list.map { |i| Domain::Reservations::Line.build(product_id: i["product_id"], quantity: i["quantity"]) }
          end

          # Tarifas da reserva: `{ fee_id, amount_cents? }` (catálogo; sem valor vale o padrão) ou
          # `{ description, amount_cents }` (avulsa). Chave nula vale como ausente; `fee_id` e `description`
          # juntos (como na entrada do catálogo de `pricing.fees`) são ambíguos. Outro formato é erro de
          # validação (422).
          def api_fees(fees)
            list = fees.nil? ? [] : fees
            raise Domain::ValidationError.field("fees", FEES_FORMAT) unless list.is_a?(Array) && list.all?(Hash)

            list.map { |item| api_fee(item) }
          end

          def api_fee(item)
            catalog = !item["fee_id"].nil?
            raise Domain::ValidationError.field("fees", FEES_FORMAT) unless catalog ^ !item["description"].nil?

            cents = strict_integer(item, "amount_cents", "tarifas", min: 1, max: Domain::Money::MAX_CENTS, allow_nil: catalog)
            amount = cents && Domain::Money.new(cents)
            return Domain::Pricing::FeeRequest.catalog(fee_id: item["fee_id"], amount: amount) if catalog

            Domain::Pricing::FeeRequest.custom(description: strict_text(item, "description", "tarifas"), amount: amount)
          end

          # Inteiro do JSON: somente Integer é aceito. Números com casas decimais, textos numéricos e
          # booleanos são recusados (nada é convertido nem arredondado em silêncio).
          def strict_integer(data, key, field, min: nil, max: nil, allow_nil: true)
            value = data[key]
            return nil if value.nil? && allow_nil
            raise Domain::ValidationError.field(field, "informe um número inteiro") unless value.is_a?(Integer)
            raise Domain::ValidationError.field(field, "mínimo #{min}") if min && value < min
            raise Domain::ValidationError.field(field, "máximo #{max}") if max && value > max

            value
          end

          # Texto do JSON: somente String ou null.
          def strict_text(data, key, field)
            value = data[key]
            raise Domain::ValidationError.field(field, "informe um texto") unless value.nil? || value.is_a?(String)

            value
          end

          # Instante opcional do JSON: ISO 8601 com fuso ou null.
          def api_instant(data, key, field)
            value = data[key]
            return nil if value.nil?
            raise Domain::ValidationError.field(field, "use ISO 8601 com fuso (ex.: 2026-03-01T08:00:00Z)") unless value.is_a?(String) && !value.strip.empty?

            Domain::Period.parse_instant(value, field)
          end

          # `location`, quando informado, recebe o corpo da resposta e devolve o endereço do recurso criado.
          def idempotent(ctx, permission, scope, payload, location: nil, &)
            fingerprint = Application::Idempotency.fingerprint(ctx.verb, ctx.path, payload)
            result = uc(:idempotency).call(ctx.actor, permission: permission, scope: scope, key: ctx.env["HTTP_IDEMPOTENCY_KEY"],
                                                      fingerprint: fingerprint, &)
            headers = result.replayed ? { "idempotent-replayed" => "true" } : {}
            headers["location"] = location.call(result.body) if location
            json(result.status, result.body, headers)
          end
        end
      end
    end
  end
end
