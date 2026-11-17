# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module API
        # Serialização explícita dos recursos financeiros da API v1.
        module FinanceSerializers
          module_function

          def payment(payment)
            { "id" => payment.id, "purpose" => payment.purpose, "receivable_id" => payment.receivable_id, "deposit_id" => payment.deposit_id,
              "reservation_id" => payment.reservation_id, "customer_id" => payment.customer_id, "method" => payment.payment_method,
              "provider" => payment.provider, "status" => payment.status, "amount" => payment.amount.to_h,
              "external_reference" => payment.external_reference, "provider_payment_id" => payment.provider_payment_id,
              "requires_review" => payment.requires_review, "review_reason" => payment.review_reason, "paid_at" => payment.paid_at&.iso8601,
              "confirmed_at" => payment.confirmed_at&.iso8601 }
          end

          def refund(refund)
            { "id" => refund.id, "payment_id" => refund.payment_id, "status" => refund.status, "amount" => refund.amount.to_h, "reason" => refund.reason,
              "confirmed_at" => refund.confirmed_at&.iso8601 }
          end
        end

        # Pagamentos manuais e reembolsos com Idempotency-Key (mesma transação da operação).
        class FinanceV1Controller < V1Controller
          FS = FinanceSerializers

          def create_payment(ctx)
            data = ctx.json
            purpose = data["deposit_id"] ? "deposit" : "receivable"
            permission = purpose == "deposit" ? "deposits.manage" : "finance.write"
            idempotent(ctx, permission, "POST /api/v1/payments", data) do |tx, actor|
              payment = uc(:register_payment).call(actor, {
                                                     purpose: purpose, receivable_id: data["receivable_id"], deposit_id: data["deposit_id"],
                                                     method: data["method"].to_s, amount: Domain::Finance::Amount.cents!(data["amount_cents"], "amount_cents"),
                                                     paid_at: data["paid_at"] && Domain::Period.parse_instant(data["paid_at"], "paid_at"), notes: data["notes"]
                                                   }, tx: tx)
              [201, FS.payment(payment)]
            end
          end

          def payment(ctx)
            data = uc(:finance).payment(ctx.actor, ctx.param(:id))
            json(200, FS.payment(data[:payment]).merge("refunds" => data[:refunds].map { |row| FS.refund(row[:refund]) },
                                                       "refundable" => data[:eligible].to_h))
          end

          def create_refund(ctx)
            data = ctx.json
            idempotent(ctx, "finance.refund", "POST /api/v1/payments/#{ctx.param(:id)}/refunds", data) do |tx, actor|
              refund = uc(:request_refund).call(actor, ctx.param(:id), amount: Domain::Finance::Amount.cents!(data["amount_cents"], "amount_cents"),
                                                                       reason: data["reason"], tx: tx)
              [201, FS.refund(refund)]
            end
          end
        end
      end
    end
  end
end
