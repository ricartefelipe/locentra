# frozen_string_literal: true

module Locentra
  module Wiring
    # Montagem dos casos de uso de condições comerciais (cupons, tarifas adicionais e condições
    # negociadas), chamada pela raiz de composição (System). Devolve o mapa nome → caso de uso.
    module CommercialTerms
      CT = Application::CommercialTerms

      module_function

      def build(uow:, repos:, services:, clock:, ids:)
        deps = { uow: uow, repos: repos, audit: services.fetch(:audit), clock: clock, ids: ids }
        coupons(**deps).merge(fees(**deps)).merge(agreements(**deps))
      end

      def coupons(uow:, repos:, audit:, clock:, ids:)
        coupons = repos.fetch(:coupons)
        {
          create_coupon: CT::CreateCoupon.new(uow: uow, coupons: coupons, audit: audit, clock: clock, ids: ids),
          update_coupon: CT::UpdateCoupon.new(uow: uow, coupons: coupons, audit: audit, clock: clock),
          set_coupon_active: CT::SetCouponActive.new(uow: uow, coupons: coupons, audit: audit, clock: clock),
          delete_coupon: CT::DeleteCoupon.new(uow: uow, coupons: coupons, audit: audit, clock: clock),
          list_coupons: CT::ListCoupons.new(uow: uow, coupons: coupons, clock: clock),
          get_coupon: CT::GetCoupon.new(uow: uow, coupons: coupons, audit_log: repos.fetch(:audit), clock: clock),
          list_coupon_redemptions: CT::ListCouponRedemptions.new(uow: uow, coupons: coupons, clock: clock)
        }
      end

      def fees(uow:, repos:, audit:, clock:, ids:)
        fees = repos.fetch(:fees)
        {
          create_fee: CT::CreateFee.new(uow: uow, fees: fees, audit: audit, clock: clock, ids: ids),
          update_fee: CT::UpdateFee.new(uow: uow, fees: fees, audit: audit, clock: clock),
          set_fee_active: CT::SetFeeActive.new(uow: uow, fees: fees, audit: audit, clock: clock),
          list_fees: CT::ListFees.new(uow: uow, fees: fees),
          get_fee: CT::GetFee.new(uow: uow, fees: fees, audit_log: repos.fetch(:audit))
        }
      end

      def agreements(uow:, repos:, audit:, clock:, ids:)
        agreements = repos.fetch(:price_agreements)
        {
          create_price_agreement: CT::CreatePriceAgreement.new(uow: uow, agreements: agreements, customers: repos.fetch(:customers),
                                                               catalog: repos.fetch(:catalog), audit: audit, clock: clock, ids: ids),
          end_price_agreement: CT::EndPriceAgreement.new(uow: uow, agreements: agreements, audit: audit, clock: clock,
                                                         organizations: repos.fetch(:organizations)),
          list_price_agreements: CT::ListPriceAgreements.new(uow: uow, agreements: agreements, clock: clock, customers: repos.fetch(:customers))
        }
      end
    end
  end
end
