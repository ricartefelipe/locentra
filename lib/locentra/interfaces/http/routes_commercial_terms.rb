# frozen_string_literal: true

require_relative "web/commercial_terms_controllers"
require_relative "api/v1_commercial_terms"

module Locentra
  module Interfaces
    module HTTP
      # Rotas das condições comerciais: cupons, tarifas adicionais e condições negociadas por cliente. As
      # rotas literais vêm antes das parametrizadas ("/cupons/novo" antes de "/cupons/:id").
      module CommercialTermsRoutes
        module_function

        # Interface web da equipe. `customers` é o controlador de clientes já montado pela tabela
        # principal: as condições negociadas são ações da página do cliente.
        def draw_web(router, deps, customers:)
          r = router
          coupons = Web::CouponsController.new(deps)
          r.get "/cupons", coupons, :index
          r.get "/cupons/novo", coupons, :new
          r.post "/cupons", coupons, :create
          r.get "/cupons/:id", coupons, :show
          r.post "/cupons/:id", coupons, :update
          r.post "/cupons/:id/desativar", coupons, :deactivate
          r.post "/cupons/:id/reativar", coupons, :reactivate
          r.post "/cupons/:id/excluir", coupons, :destroy

          fees = Web::FeesController.new(deps)
          r.get "/tarifas", fees, :index
          r.get "/tarifas/nova", fees, :new
          r.post "/tarifas", fees, :create
          r.get "/tarifas/:id", fees, :show
          r.post "/tarifas/:id", fees, :update
          r.post "/tarifas/:id/desativar", fees, :deactivate
          r.post "/tarifas/:id/reativar", fees, :reactivate

          r.post "/clientes/:id/condicoes", customers, :create_agreement
          r.post "/clientes/:id/condicoes/:condicao_id/encerrar", customers, :end_agreement
        end

        # API v1. As consultas de cupom e de tarifa aceitam identificador ou código em `:id`; as
        # mutações, somente o identificador. Toda mutação exige Idempotency-Key.
        def draw_api(router, deps)
          r = router
          api = API::CommercialTermsV1Controller.new(deps)
          r.get "/api/v1/coupons", api, :coupons, auth: :api
          r.post "/api/v1/coupons", api, :create_coupon, auth: :api
          r.get "/api/v1/coupons/:id", api, :coupon, auth: :api
          r.patch "/api/v1/coupons/:id", api, :update_coupon, auth: :api
          r.post "/api/v1/coupons/:id/deactivate", api, :deactivate_coupon, auth: :api
          r.post "/api/v1/coupons/:id/reactivate", api, :reactivate_coupon, auth: :api
          r.get "/api/v1/coupons/:id/redemptions", api, :coupon_redemptions, auth: :api

          r.get "/api/v1/fees", api, :fees, auth: :api
          r.post "/api/v1/fees", api, :create_fee, auth: :api
          r.get "/api/v1/fees/:id", api, :fee, auth: :api
          r.patch "/api/v1/fees/:id", api, :update_fee, auth: :api
          r.post "/api/v1/fees/:id/deactivate", api, :deactivate_fee, auth: :api
          r.post "/api/v1/fees/:id/reactivate", api, :reactivate_fee, auth: :api

          r.get "/api/v1/customers/:id/price-agreements", api, :price_agreements, auth: :api
          r.post "/api/v1/customers/:id/price-agreements", api, :create_price_agreement, auth: :api
          r.post "/api/v1/price-agreements/:id/end", api, :end_price_agreement, auth: :api
        end
      end
    end
  end
end
