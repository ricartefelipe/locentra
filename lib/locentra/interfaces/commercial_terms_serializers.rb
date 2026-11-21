# frozen_string_literal: true

module Locentra
  module Interfaces
    # Representação JSON das condições comerciais, compartilhada pela API v1 e pela CLI (`--json`): os
    # dois canais devolvem os mesmos campos. Instantes em ISO 8601 UTC, valores monetários como em
    # `Money#to_h` e percentuais em pontos-base inteiros.
    module CommercialTermsSerializers
      module_function

      def time(value) = value&.getutc&.iso8601

      def money(cents) = Domain::Money.new(cents.to_i).to_h

      # `redemptions` são os usos ativos (contador legado mais usos ativos do livro); `status` é a
      # situação no instante da consulta. O desconto vem em `discount_bps` (percentual) ou `discount`
      # (valor fixo), conforme `kind`.
      def coupon(coupon, status)
        percent = coupon.kind == "percent"
        { "id" => coupon.id, "code" => coupon.code, "description" => coupon.description, "kind" => coupon.kind,
          "discount_bps" => percent ? coupon.value : nil, "discount" => percent ? nil : money(coupon.value),
          "valid_from" => time(coupon.valid_from), "valid_until" => time(coupon.valid_until),
          "max_redemptions" => coupon.max_redemptions, "redemptions" => coupon.redemptions,
          "total_redemptions" => coupon.total_redemptions, "remaining" => coupon.remaining,
          "min_subtotal" => money(coupon.min_subtotal_cents), "active" => coupon.active, "status" => status,
          "lock_version" => coupon.lock_version, "created_at" => time(coupon.created_at), "updated_at" => time(coupon.updated_at) }
      end

      # Uso de cupom. Os dados da reserva exigem `reservations.read` e o nome do cliente,
      # `customers.read`: sem o escopo, as chaves são omitidas.
      def coupon_redemption(item, reservations:, customers:)
        data = { "id" => item[:id] }
        data.update("reservation_id" => item[:reservation_id], "reservation_code" => item[:reservation_code]) if reservations
        data["customer_name"] = item[:customer_name] if customers
        data.merge("subtotal" => item[:subtotal].to_h, "discount" => item[:discount].to_h, "redeemed_at" => time(item[:redeemed_at]),
                   "state" => item[:state], "released_at" => time(item[:released_at]))
      end

      def fee(fee)
        { "id" => fee.id, "code" => fee.code, "name" => fee.name, "description" => fee.description,
          "default_amount" => fee.default_amount.to_h, "active" => fee.active, "status" => fee.status, "lock_version" => fee.lock_version,
          "created_at" => time(fee.created_at), "updated_at" => time(fee.updated_at) }
      end

      # `product` (SKU e nome) é informado pelas listagens quando o ator tem `catalog.read`; nos demais
      # casos a chave é omitida e `product_id` identifica o produto.
      def price_agreement(agreement, status, product: nil)
        data = { "id" => agreement.id, "customer_id" => agreement.customer_id, "scope" => agreement.scope, "product_id" => agreement.product_id }
        data["product"] = { "sku" => product[:sku], "name" => product[:name] } if product
        data.merge("discount_bps" => agreement.discount_bps, "valid_from" => time(agreement.valid_from),
                   "valid_until" => time(agreement.valid_until), "notes" => agreement.notes, "ended_at" => time(agreement.ended_at),
                   "end_reason" => agreement.end_reason, "status" => status, "created_at" => time(agreement.created_at))
      end
    end
  end
end
