# frozen_string_literal: true

require_relative "web/commercial_terms_controllers"

module Locentra
  module Interfaces
    module HTTP
      # Rotas das condições comerciais (cupons). As rotas literais vêm antes das parametrizadas
      # ("/cupons/novo" antes de "/cupons/:id").
      module CommercialTermsRoutes
        module_function

        # Interface web da equipe.
        def draw_web(router, deps)
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
        end
      end
    end
  end
end
