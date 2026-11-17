# frozen_string_literal: true

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

          def page(page, &)
            { "data" => page.items.map(&), "pagination" => { "limit" => page.limit, "offset" => page.offset, "total" => page.total,
                                                             "next_offset" => page.next_offset } }
          end
        end

        class V1Controller < Controller
          S = Serializers

          def availability(ctx)
            ids = ctx.query("product_ids").to_s.split(",").map(&:strip).reject(&:empty?)
            period = Domain::Period.parse(ctx.query("starts_at"), ctx.query("ends_at"))
            rows = uc(:check_availability).call(ctx.actor, branch_id: ctx.query("branch_id"), period: period, product_ids: ids.empty? ? nil : ids)
            json(200, { "period" => period.to_h, "data" => rows.map do |row|
              { "product_id" => row["product"].id, "sku" => row["product"].sku, "tracking" => row["product"].tracking,
                "available" => row["available"], "total" => row["total"] }
            end })
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

          # Criação idempotente: exige Idempotency-Key.
          def create_reservation(ctx)
            data = ctx.json
            idempotent(ctx, "reservations.write", "POST /api/v1/reservations", data) do |tx, actor|
              lines = Array(data["items"]).map { |i| Domain::Reservations::Line.build(product_id: i.to_h["product_id"], quantity: i.to_h["quantity"]) }
              reservation = uc(:create_reservation).call(actor, {
                customer_id: data["customer_id"], branch_id: data["branch_id"], period: api_period(data),
                lines: lines, mode: (data["mode"] || "hold").to_s, hold_minutes: data["hold_minutes"],
                notes: data["notes"], coupon_code: data["coupon_code"], source: "api"
              }.compact, tx: tx)
              [201, S.reservation(reservation)]
            end
          end

          def confirm_reservation(ctx)
            idempotent(ctx, "reservations.write", "POST /api/v1/reservations/#{ctx.param(:id)}/confirm", {}) do |tx, actor|
              [200, S.reservation(uc(:confirm_reservation).call(actor, ctx.param(:id), tx: tx))]
            end
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

          def idempotent(ctx, permission, scope, payload, &)
            fingerprint = Application::Idempotency.fingerprint(ctx.verb, ctx.path, payload)
            result = uc(:idempotency).call(ctx.actor, permission: permission, scope: scope, key: ctx.env["HTTP_IDEMPOTENCY_KEY"],
                                                      fingerprint: fingerprint, &)
            json(result.status, result.body, result.replayed ? { "idempotent-replayed" => "true" } : {})
          end
        end
      end
    end
  end
end
