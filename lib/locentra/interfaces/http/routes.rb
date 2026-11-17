# frozen_string_literal: true

require_relative "web/auth_controller"
require_relative "web/main_controllers"
require_relative "web/operations_controllers"
require_relative "web/integrations_controller"
require_relative "web/finance_controllers"
require_relative "api/v1"
require_relative "api/v1_finance"

module Locentra
  module Interfaces
    module HTTP
      # Tabela de rotas da aplicação. Caminhos da interface web em português; API versionada em /api/v1.
      module Routes
        module_function

        def draw(router, deps)
          r = router
          w = Web
          auth = w::AuthController.new(deps)
          health = w::HealthController.new(deps)
          r.get "/health/live", health, :live, auth: :public
          r.get "/health/ready", health, :ready, auth: :public
          r.get "/metrics", health, :metrics, auth: :public

          r.get "/entrar", auth, :login_form, auth: :public
          r.post "/entrar", auth, :login, auth: :public, csrf: false
          r.post "/sair", auth, :logout, auth: :login
          r.get "/cadastro", auth, :signup_form, auth: :public
          r.post "/cadastro", auth, :signup, auth: :public, csrf: false
          r.get "/organizacoes", auth, :organizations, auth: :login
          r.post "/organizacoes/ativar", auth, :switch, auth: :login
          r.get "/confirmar-email", auth, :confirm_email, auth: :public
          r.get "/recuperar-senha", auth, :forgot_form, auth: :public
          r.post "/recuperar-senha", auth, :forgot, auth: :public, csrf: false
          r.get "/redefinir-senha", auth, :reset_form, auth: :public
          r.post "/redefinir-senha", auth, :reset, auth: :public, csrf: false
          r.get "/convites", auth, :invitation_form, auth: :public
          r.post "/convites", auth, :accept_invitation, auth: :public, csrf: false

          draw_staff(r, deps, w)
          draw_api(r, API::V1Controller.new(deps))
        end

        def draw_staff(router, deps, web)
          r = router
          w = web
          r.get "/", w::DashboardController.new(deps), :show

          customers = w::CustomersController.new(deps)
          r.get "/clientes", customers, :index
          r.get "/clientes/novo", customers, :new
          r.post "/clientes", customers, :create
          r.get "/clientes/:id", customers, :show
          r.post "/clientes/:id", customers, :update
          r.post "/clientes/:id/contatos", customers, :add_contact
          r.post "/clientes/:id/enderecos", customers, :add_address

          catalog = w::CatalogController.new(deps)
          r.get "/produtos", catalog, :index
          r.get "/produtos/novo", catalog, :new
          r.post "/produtos", catalog, :create
          r.get "/produtos/:id", catalog, :show
          r.post "/produtos/:id/precos", catalog, :update_pricing
          r.post "/produtos/:id/componentes", catalog, :update_components
          r.post "/produtos/:id/ativos", catalog, :register_asset
          r.post "/produtos/:id/estoque", catalog, :adjust_stock
          r.get "/ativos", catalog, :assets
          r.get "/ativos/:id", catalog, :asset
          r.post "/ativos/:id/situacao", catalog, :change_asset_status
          r.post "/ativos/:id/bloqueios", catalog, :block_asset

          availability = w::AvailabilityController.new(deps)
          r.get "/disponibilidade", availability, :calendar
          r.get "/disponibilidade/consulta", availability, :check

          reservations = w::ReservationsController.new(deps)
          r.get "/reservas", reservations, :index
          r.get "/reservas/nova", reservations, :new
          r.post "/reservas", reservations, :create
          r.get "/reservas/:id", reservations, :show
          r.post "/reservas/:id/confirmar", reservations, :confirm
          r.post "/reservas/:id/cancelar", reservations, :cancel
          r.post "/reservas/:id/reagendar", reservations, :reschedule
          r.post "/reservas/:id/estender", reservations, :extend_period

          members = w::MembersController.new(deps)
          r.get "/usuarios", members, :index
          r.post "/usuarios/convites", members, :invite
          r.post "/usuarios/:id/papel", members, :change_role
          r.post "/usuarios/:id/revogar", members, :revoke
          r.post "/credenciais", members, :create_credential
          r.post "/credenciais/:id/revogar", members, :revoke_credential

          organization = w::OrganizationController.new(deps)
          r.get "/organizacao", organization, :show
          r.post "/organizacao/filiais", organization, :create_branch

          r.get "/auditoria", w::AuditController.new(deps), :index

          integrations = w::IntegrationsController.new(deps)
          r.get "/integracoes", integrations, :index
          r.post "/integracoes", integrations, :create
          r.post "/integracoes/:id/desativar", integrations, :disable
          r.post "/integracoes/entregas/:id/reenviar", integrations, :redeliver

          attachments = w::AttachmentsController.new(deps)
          r.post "/anexos", attachments, :create
          r.get "/anexos/:id", attachments, :show, auth: :staff_or_portal
          r.post "/anexos/:id/remover", attachments, :remove

          draw_finance(r, deps, w)
        end

        # Financeiro: cobranças, pagamentos, reembolsos, cauções, faturas, conciliação, provedor,
        # webhook público do provedor e API de pagamentos.
        def draw_finance(router, deps, web)
          r = router
          w = web
          finance = w::FinanceController.new(deps)
          r.get "/financeiro", finance, :index
          r.post "/financeiro/conciliacao", finance, :reconcile
          r.get "/financeiro/conciliacao/:id", finance, :report
          r.post "/financeiro/alertas/:id/resolver", finance, :resolve_alert
          r.get "/financeiro/provedor", finance, :provider
          r.post "/financeiro/provedor", finance, :configure_provider
          r.post "/financeiro/provedor/:id/desativar", finance, :deactivate_provider

          receivables = w::ReceivablesController.new(deps)
          r.get "/financeiro/cobrancas/:id", receivables, :show
          r.post "/financeiro/cobrancas/:id/pagamentos", receivables, :register_payment
          r.post "/financeiro/cobrancas/:id/solicitar", receivables, :request_payment
          r.post "/financeiro/cobrancas/:id/cancelar", receivables, :cancel
          r.post "/financeiro/reservas/:id/sincronizar", receivables, :sync
          r.post "/financeiro/reservas/:id/cobrancas", receivables, :create_charge
          r.post "/financeiro/reservas/:id/faturas", receivables, :issue_invoice
          r.get "/financeiro/faturas/:id", receivables, :invoice

          payments = w::PaymentsController.new(deps)
          r.get "/financeiro/pagamentos/:id", payments, :show
          r.post "/financeiro/pagamentos/:id/reembolsos", payments, :refund
          r.post "/financeiro/pagamentos/:id/simular", payments, :simulate

          deposits = w::DepositsController.new(deps)
          r.post "/financeiro/reservas/:id/caucao", deposits, :create
          r.get "/financeiro/caucoes/:id", deposits, :show
          r.post "/financeiro/caucoes/:id/receber", deposits, :receive
          r.post "/financeiro/caucoes/:id/solicitar", deposits, :request_payment
          r.post "/financeiro/caucoes/:id/aplicar", deposits, :apply
          r.post "/financeiro/caucoes/:id/devolver", deposits, :give_back

          r.post "/webhooks/pagamentos/:conta_id", w::PaymentWebhooksController.new(deps), :receive, auth: :public, csrf: false

          api = API::FinanceV1Controller.new(deps)
          r.post "/api/v1/payments", api, :create_payment, auth: :api
          r.get "/api/v1/payments/:id", api, :payment, auth: :api
          r.post "/api/v1/payments/:id/refunds", api, :create_refund, auth: :api
        end

        def draw_api(router, api)
          r = router
          r.get "/api/v1/openapi.yaml", api, :openapi, auth: :public
          r.get "/api/v1/availability", api, :availability, auth: :api
          r.get "/api/v1/customers", api, :customers, auth: :api
          r.post "/api/v1/customers", api, :create_customer, auth: :api
          r.get "/api/v1/customers/:id", api, :customer, auth: :api
          r.get "/api/v1/products", api, :products, auth: :api
          r.get "/api/v1/reservations", api, :reservations, auth: :api
          r.post "/api/v1/reservations", api, :create_reservation, auth: :api
          r.get "/api/v1/reservations/:id", api, :reservation, auth: :api
          r.post "/api/v1/reservations/:id/confirm", api, :confirm_reservation, auth: :api
          r.post "/api/v1/reservations/:id/cancel", api, :cancel_reservation, auth: :api
        end
      end
    end
  end
end
