# frozen_string_literal: true

require_relative "web/auth_controller"
require_relative "web/main_controllers"
require_relative "web/operations_controllers"
require_relative "web/integrations_controller"
require_relative "web/finance_controllers"
require_relative "web/fulfillment_controllers"
require_relative "web/maintenance_controllers"
require_relative "web/quotes_controller"
require_relative "web/contracts_controller"
require_relative "web/portal_controllers"
require_relative "api/v1"
require_relative "api/v1_finance"
require_relative "routes_commercial_terms"

module Locentra
  module Interfaces
    module HTTP
      # Tabela de rotas da aplicação. Caminhos da interface web em português; API versionada em /api/v1.
      module Routes
        # Limites por IP das rotas públicas: [nome, limite, janela em segundos].
        SIGNUP = ["signup:ip", 10, 3600].freeze
        PASSWORD_RESET = ["password_reset:ip", 20, 3600].freeze
        INVITATION = ["invitation:ip", 20, 3600].freeze
        PORTAL_INVITATION = ["portal_invitation:ip", 20, 3600].freeze
        PAYMENT_WEBHOOK = ["payment_webhook:ip", 1200, 60].freeze
        PORTAL_REQUEST = ["portal_request:user", 30, 3600].freeze

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
          r.post "/entrar", auth, :login, auth: :public, csrf: :origin
          r.post "/sair", auth, :logout, auth: :login
          r.get "/cadastro", auth, :signup_form, auth: :public
          r.post "/cadastro", auth, :signup, auth: :public, csrf: :origin, throttle: SIGNUP
          r.get "/organizacoes", auth, :organizations, auth: :login
          r.post "/organizacoes/ativar", auth, :switch, auth: :login
          r.get "/confirmar-email", auth, :confirm_email, auth: :public
          r.get "/recuperar-senha", auth, :forgot_form, auth: :public
          r.post "/recuperar-senha", auth, :forgot, auth: :public, csrf: :origin
          r.get "/redefinir-senha", auth, :reset_form, auth: :public
          r.post "/redefinir-senha", auth, :reset, auth: :public, csrf: :origin, throttle: PASSWORD_RESET
          r.get "/convites", auth, :invitation_form, auth: :public
          r.post "/convites", auth, :accept_invitation, auth: :public, csrf: :origin, throttle: INVITATION

          draw_portal(r, deps, w)
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
          CommercialTermsRoutes.draw_web(r, deps)

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

          draw_quotes(r, deps, w)
          draw_contracts(r, deps, w)

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
          draw_operations(r, deps, w)
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

          r.post "/webhooks/pagamentos/:conta_id", w::PaymentWebhooksController.new(deps), :receive,
                 auth: :public, csrf: false, throttle: PAYMENT_WEBHOOK

          api = API::FinanceV1Controller.new(deps)
          r.post "/api/v1/payments", api, :create_payment, auth: :api
          r.get "/api/v1/payments/:id", api, :payment, auth: :api
          r.post "/api/v1/payments/:id/refunds", api, :create_refund, auth: :api
        end

        # Retirada, devolução, inspeção, avarias, manutenção e transferências.
        def draw_operations(router, deps, web)
          r = router
          w = web
          board = w::OperationsController.new(deps)
          r.get "/operacao", board, :show
          r.post "/operacao/alertas/:id/resolver", board, :resolve_alert

          pickups = w::PickupsController.new(deps)
          r.post "/operacao/reservas/:id/retirada", pickups, :start
          r.get "/operacao/retiradas/:id", pickups, :show
          r.post "/operacao/retiradas/:id/conferir", pickups, :check
          r.post "/operacao/retiradas/:id/entregar", pickups, :deliver
          r.post "/operacao/retiradas/:id/cancelar", pickups, :cancel

          returns = w::ReturnsController.new(deps)
          r.get "/operacao/reservas/:id/devolucao", returns, :new
          r.post "/operacao/reservas/:id/devolucao", returns, :create
          r.get "/operacao/devolucoes/:id", returns, :show

          inspections = w::InspectionsController.new(deps)
          r.get "/operacao/inspecoes", inspections, :index
          r.post "/operacao/inspecoes/:id/aprovar", inspections, :approve
          r.post "/operacao/inspecoes/:id/reprovar", inspections, :reject

          damages = w::DamageReportsController.new(deps)
          r.get "/operacao/avarias", damages, :index
          r.post "/operacao/avarias", damages, :create
          r.get "/operacao/avarias/:id", damages, :show
          r.post "/operacao/avarias/:id", damages, :update
          r.post "/operacao/avarias/:id/aprovar", damages, :approve
          r.post "/operacao/avarias/:id/descartar", damages, :dismiss

          maintenance = w::MaintenanceController.new(deps)
          r.get "/manutencao", maintenance, :index
          r.post "/manutencao", maintenance, :create
          r.get "/manutencao/:id", maintenance, :show
          r.post "/manutencao/:id/iniciar", maintenance, :start
          r.post "/manutencao/:id/concluir", maintenance, :complete
          r.post "/manutencao/:id/cancelar", maintenance, :cancel

          transfers = w::TransfersController.new(deps)
          r.get "/transferencias", transfers, :index
          r.post "/transferencias", transfers, :create
          r.post "/transferencias/:id/saida", transfers, :dispatch_transfer
          r.post "/transferencias/:id/recebimento", transfers, :receive
          r.post "/transferencias/:id/cancelar", transfers, :cancel
        end

        def draw_quotes(router, deps, web)
          r = router
          quotes = web::QuotesController.new(deps)
          r.get "/orcamentos", quotes, :index
          r.get "/orcamentos/novo", quotes, :new
          r.post "/orcamentos", quotes, :create
          r.get "/orcamentos/:id", quotes, :show
          r.get "/orcamentos/:id/nova-versao", quotes, :revision
          r.post "/orcamentos/:id/versoes", quotes, :revise
          r.post "/orcamentos/:id/enviar", quotes, :send_to_customer
          r.post "/orcamentos/:id/aprovar", quotes, :approve
          r.post "/orcamentos/:id/rejeitar", quotes, :reject
          r.post "/orcamentos/:id/converter", quotes, :convert
        end

        def draw_contracts(router, deps, web)
          r = router
          contracts = web::ContractsController.new(deps)
          r.get "/contratos", contracts, :index
          r.post "/contratos", contracts, :create
          r.get "/contratos/:id", contracts, :show
          r.post "/contratos/:id/aceite", contracts, :accept
          r.post "/contratos/:id/aditivos", contracts, :amend
          r.post "/contratos/:id/cancelar", contracts, :cancel
          r.post "/contratos/:id/encerrar", contracts, :close
        end

        # Portal do cliente: aceite público do convite, área do cliente (modo :portal, sessão de
        # portal) e gestão dos acessos na tela do cliente (equipe).
        def draw_portal(router, deps, web)
          r = router
          w = web
          invitations = w::PortalInvitationsController.new(deps)
          r.get "/portal/convite", invitations, :show, auth: :public
          # Sem sessão não há token CSRF; com sessão, o controlador exige o token da sessão.
          r.post "/portal/convite", invitations, :accept, auth: :public, csrf: :origin, throttle: PORTAL_INVITATION

          portal = w::PortalController.new(deps)
          r.get "/portal", portal, :home, auth: :portal
          r.get "/portal/disponibilidade", portal, :availability, auth: :portal
          r.post "/portal/reservas", portal, :request_reservation, auth: :portal, throttle_actor: PORTAL_REQUEST
          r.get "/portal/financeiro", portal, :finance, auth: :portal

          reservations = w::PortalReservationsController.new(deps)
          r.get "/portal/reservas", reservations, :index, auth: :portal
          r.get "/portal/reservas/:id", reservations, :show, auth: :portal

          quotes = w::PortalQuotesController.new(deps)
          r.get "/portal/orcamentos", quotes, :index, auth: :portal
          r.get "/portal/orcamentos/:id", quotes, :show, auth: :portal
          r.post "/portal/orcamentos/:id/aprovar", quotes, :approve, auth: :portal
          r.post "/portal/orcamentos/:id/rejeitar", quotes, :reject, auth: :portal

          contracts = w::PortalContractsController.new(deps)
          r.get "/portal/contratos", contracts, :index, auth: :portal
          r.get "/portal/contratos/:id", contracts, :show, auth: :portal
          r.post "/portal/contratos/:id/aceite", contracts, :accept, auth: :portal

          access = w::CustomerPortalController.new(deps)
          r.post "/clientes/:id/portal/convites", access, :invite
          r.post "/clientes/:id/portal/convites/:convite_id/cancelar", access, :cancel_invitation
          r.post "/clientes/:id/portal/acessos/:acesso_id/revogar", access, :revoke
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
