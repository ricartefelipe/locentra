# frozen_string_literal: true

require_relative "config"
require_relative "infrastructure"
require_relative "infrastructure/observability/logger"

module Locentra
  # Composition root: monta adaptadores e casos de uso a partir da configuração.
  #
  # Nenhuma conexão é aberta na montagem; os pools conectam sob demanda. Cada processo (Puma
  # worker, worker de fila, CLI) monta o próprio System após o fork.
  class System
    I = Infrastructure
    P = Infrastructure::Persistence
    A = Application

    attr_reader :config, :clock, :ids, :logger, :metrics, :pool, :transactor, :uow, :repos, :queue, :use_cases, :services

    def self.boot(env = ENV, overrides = {}, **deps)
      new(Config.from_env(env, overrides), **deps)
    end

    def initialize(config, clock: Domain::SystemClock.new, ids: Domain::IdGenerator.new, logger: nil, metrics: nil, database_url: nil,
                   pool_name: "web", pool_size: nil, mailer: nil, http: nil, payment_http: nil)
      @config = config
      @payment_http = payment_http
      @clock = clock
      @ids = ids
      @logger = logger || I::Observability::StructuredLogger.new(level: config.log_level, base: { "service" => "locentra" })
      @metrics = metrics || I::Observability::Metrics.new
      @pool = I::Database::ConnectionPool.new(url: database_url || config.database_url, size: pool_size || config.pool_size,
                                              timeout: config.pool_timeout, name: pool_name, metrics: @metrics, logger: @logger)
      @mailer = mailer || I::SmtpMailer.new(host: config.smtp_host, port: config.smtp_port, from: config.mail_from)
      @http = http || I::Integrations::SafeHttp.new(allow_http: !config.production?, allow_private: config.test?)
      @transactor = I::Database::Transactor.new(pool: @pool, logger: @logger, metrics: @metrics)
      build_repositories
      @uow = A::UnitOfWork.new(transactor: @transactor, access: @repos[:access], clock: clock)
      build_services
      build_use_cases
    end

    def shutdown
      @pool.shutdown
    end

    private

    def build_repositories
      @queue = I::Jobs::Queue.new(clock: clock, ids: ids)
      @repos = {
        users: P::UserRepository.new, sessions: P::SessionRepository.new, user_tokens: P::UserTokenRepository.new,
        access: P::AccessRepository.new, organizations: P::OrganizationRepository.new, subscriptions: P::SubscriptionRepository.new,
        customers: P::CustomerRepository.new, catalog: P::CatalogRepository.new, availability: P::AvailabilityRepository.new,
        reservations: P::ReservationRepository.new, audit: P::AuditRepository.new, pricing: P::PricingRepository.new,
        credentials: P::CredentialRepository.new, idempotency: P::IdempotencyRepository.new, reports: P::ReportsRepository.new,
        webhooks: P::WebhookRepository.new, attachments: P::AttachmentRepository.new,
        receivables: P::ReceivableRepository.new, payments: P::PaymentRepository.new, deposits: P::DepositRepository.new,
        ledger_entries: P::LedgerRepository.new, finance_alerts: P::FinanceAlertRepository.new, invoices: P::InvoiceRepository.new,
        payment_accounts: P::PaymentAccountRepository.new, inbound_webhooks: P::InboundWebhookRepository.new,
        reconciliation: P::ReconciliationRepository.new
      }
    end

    def build_services
      @services = {
        hasher: I::PasswordHasher.new(cost: config.bcrypt_cost),
        rate_limiter: I::RateLimiter.new(transactor: transactor, clock: clock),
        audit: A::AuditTrail.new(repository: repos[:audit], clock: clock, ids: ids),
        events: P::EventPublisher.new(queue: queue, clock: clock, ids: ids),
        notifier: I::JobNotifier.new(queue: queue),
        tokens: A::Identity::OneTimeTokens.new(repository: repos[:user_tokens], clock: clock, ids: ids),
        sessions: A::Identity::Sessions.new(uow: uow, repository: repos[:sessions], clock: clock, ids: ids),
        limits: A::Organizations::PlanLimits.new(subscriptions: repos[:subscriptions]),
        allocator: A::Availability::Allocator.new(repository: repos[:availability], ids: ids),
        pricer: A::Reservations::Pricer.new(pricing: repos[:pricing]),
        pricing_rules: Domain::Pricing::Rules.new,
        mailer: @mailer, http: @http,
        box: I::SecretBox.new(config.encryption_key),
        storage: I::Storage::Local.new(root: config.storage_root),
        mail_templates: I::MailTemplates.new(root: File.expand_path("../../views/mailer", __dir__))
      }
      @services[:notifications] = A::Notifications::EventNotifications.new(queue: queue, reservations: repos[:reservations], customers: repos[:customers])
      @services[:finance_subscriber] = A::Finance::ReservationChargesSubscriber.new(queue: queue)
      @services[:dispatch_event] = A::Webhooks::DispatchEvent.new(webhooks: repos[:webhooks], queue: queue, notifications: @services[:notifications],
                                                                  clock: clock, ids: ids, subscribers: [@services[:finance_subscriber]])
      @services[:deliver_webhook] = A::Webhooks::Deliver.new(transactor: transactor, webhooks: repos[:webhooks], http: @http, box: @services[:box],
                                                             clock: clock, logger: logger)
    end

    def common = { uow: uow, clock: clock }

    def build_use_cases
      uc = {}
      build_identity_use_cases(uc)
      build_catalog_use_cases(uc)
      build_reservation_use_cases(uc)
      build_integration_use_cases(uc)
      build_finance_use_cases(uc)
      @use_cases = UseCases.new(uc)
    end

    def build_identity_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      uc[:sign_up] = A::Identity::SignUp.new(uow: uow, users: r[:users], organizations: r[:organizations], hasher: s[:hasher],
                                             notifier: s[:notifier], clock: clock, ids: ids, audit: audit)
      uc[:authenticate] =
        A::Identity::Authenticate.new(uow: uow, users: r[:users], hasher: s[:hasher], rate_limiter: s[:rate_limiter], clock: clock)
      uc[:confirm_email] = A::Identity::ConfirmEmail.new(uow: uow, tokens: s[:tokens], users: r[:users], clock: clock)
      uc[:request_password_reset] = A::Identity::RequestPasswordReset.new(uow: uow, users: r[:users], rate_limiter: s[:rate_limiter],
                                                                          notifier: s[:notifier])
      uc[:reset_password] = A::Identity::ResetPassword.new(uow: uow, users: r[:users], tokens: s[:tokens], hasher: s[:hasher],
                                                           sessions_repository: r[:sessions], clock: clock)
      uc[:list_memberships] = A::Identity::ListMemberships.new(uow: uow, organizations: r[:organizations])
      uc[:switch_organization] =
        A::Organizations::SwitchOrganization.new(uow: uow, organizations: r[:organizations], sessions: s[:sessions])
      uc[:create_branch] =
        A::Organizations::CreateBranch.new(**common, organizations: r[:organizations], limits: s[:limits], audit: audit, ids: ids)
      uc[:invite_member] = A::Organizations::InviteMember.new(**common, organizations: r[:organizations], limits: s[:limits],
                                                                        notifier: s[:notifier], audit: audit, ids: ids)
      uc[:accept_invitation] = A::Organizations::AcceptInvitation.new(**common, organizations: r[:organizations], users: r[:users],
                                                                                hasher: s[:hasher], audit: audit, ids: ids)
      uc[:change_member_role] = A::Organizations::ChangeMemberRole.new(**common, organizations: r[:organizations], audit: audit)
      uc[:revoke_membership] = A::Organizations::RevokeMembership.new(**common, organizations: r[:organizations],
                                                                                sessions_repository: r[:sessions], audit: audit)
      uc[:list_members] = A::Organizations::ListMembers.new(uow: uow, organizations: r[:organizations])
      uc[:get_organization] = A::Organizations::GetOrganization.new(uow: uow, organizations: r[:organizations])
      uc[:create_credential] = A::Integrations::CreateCredential.new(**common, credentials: r[:credentials], limits: s[:limits], audit: audit, ids: ids)
      uc[:revoke_credential] = A::Integrations::RevokeCredential.new(**common, credentials: r[:credentials], audit: audit)
      uc[:list_credentials] = A::Integrations::ListCredentials.new(uow: uow, credentials: r[:credentials])
      uc[:authenticate_credential] = A::Integrations::AuthenticateCredential.new(**common, credentials: r[:credentials])
      uc[:idempotency] = A::Idempotency.new(**common, repository: r[:idempotency], ids: ids)
      uc[:dashboard] = A::Reports::Dashboard.new(**common, reports: r[:reports])
      uc[:list_audit] = A::Reports::ListAudit.new(uow: uow, audit: r[:audit])
      uc[:collect_metrics] = A::Reports::CollectMetrics.new(transactor: transactor, reports: r[:reports], metrics: metrics, clock: clock)
    end

    def build_catalog_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      uc[:create_customer] = A::Customers::CreateCustomer.new(**common, customers: r[:customers], audit: audit, ids: ids)
      uc[:update_customer] = A::Customers::UpdateCustomer.new(**common, customers: r[:customers], audit: audit)
      uc[:add_contact] = A::Customers::AddContact.new(**common, customers: r[:customers], audit: audit, ids: ids)
      uc[:add_address] = A::Customers::AddAddress.new(**common, customers: r[:customers], audit: audit, ids: ids)
      uc[:list_customers] = A::Customers::ListCustomers.new(uow: uow, customers: r[:customers])
      uc[:get_customer] = A::Customers::GetCustomer.new(uow: uow, customers: r[:customers])

      uc[:create_product] =
        A::Catalog::CreateProduct.new(**common, catalog: r[:catalog], pricing_rules: s[:pricing_rules], audit: audit, ids: ids)
      uc[:update_product_pricing] =
        A::Catalog::UpdateProductPricing.new(**common, catalog: r[:catalog], pricing_rules: s[:pricing_rules], audit: audit)
      uc[:set_kit_components] = A::Catalog::SetKitComponents.new(uow: uow, catalog: r[:catalog], audit: audit)
      uc[:register_asset] = A::Catalog::RegisterAsset.new(**common, catalog: r[:catalog], limits: s[:limits], audit: audit, ids: ids)
      uc[:adjust_stock] = A::Catalog::AdjustStock.new(**common, catalog: r[:catalog], availability: r[:availability], limits: s[:limits],
                                                                audit: audit, ids: ids)
      uc[:change_asset_status] = A::Catalog::ChangeAssetStatus.new(**common, catalog: r[:catalog], availability: r[:availability],
                                                                             allocator: s[:allocator], audit: audit, ids: ids)
      uc[:block_availability] =
        A::Catalog::BlockAvailability.new(**common, catalog: r[:catalog], availability: r[:availability], audit: audit, ids: ids)
      uc[:list_products] = A::Catalog::ListProducts.new(uow: uow, catalog: r[:catalog])
      uc[:get_product] = A::Catalog::GetProduct.new(uow: uow, catalog: r[:catalog])
      uc[:get_asset] = A::Catalog::GetAsset.new(uow: uow, catalog: r[:catalog], availability: r[:availability])

      uc[:check_availability] = A::Availability::CheckAvailability.new(**common, repository: r[:availability], allocator: s[:allocator])
      uc[:calendar] = A::Availability::Calendar.new(uow: uow, check: uc[:check_availability], organizations: r[:organizations])
    end

    def build_reservation_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      reservation_deps = { reservations: r[:reservations], audit: audit, clock: clock }
      uc[:create_reservation] = A::Reservations::CreateReservation.new(uow: uow, customers: r[:customers], organizations: r[:organizations],
                                                                       allocator: s[:allocator], pricer: s[:pricer], events: s[:events], ids: ids,
                                                                       **reservation_deps)
      uc[:confirm_reservation] =
        A::Reservations::ConfirmReservation.new(uow: uow, allocator: s[:allocator], events: s[:events], **reservation_deps)
      uc[:cancel_reservation] = A::Reservations::CancelReservation.new(uow: uow, events: s[:events], **reservation_deps)
      uc[:reschedule_reservation] = A::Reservations::RescheduleReservation.new(uow: uow, organizations: r[:organizations],
                                                                               allocator: s[:allocator], **reservation_deps)
      uc[:extend_reservation] = A::Reservations::ExtendReservation.new(uow: uow, organizations: r[:organizations], allocator: s[:allocator],
                                                                       availability: r[:availability], events: s[:events], ids: ids,
                                                                       **reservation_deps)
      uc[:expire_holds] = A::Reservations::ExpireHolds.new(uow: uow, events: s[:events], **reservation_deps)
      uc[:list_reservations] = A::Reservations::ListReservations.new(uow: uow, reservations: r[:reservations])
      uc[:get_reservation] = A::Reservations::GetReservation.new(uow: uow, reservations: r[:reservations])
    end

    def build_integration_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      uc[:create_webhook] = A::Webhooks::CreateEndpoint.new(**common, webhooks: r[:webhooks], limits: s[:limits], http: s[:http], box: s[:box],
                                                                      audit: audit, ids: ids)
      uc[:disable_webhook] = A::Webhooks::DisableEndpoint.new(**common, webhooks: r[:webhooks], audit: audit)
      uc[:list_webhooks] = A::Webhooks::ListEndpoints.new(uow: uow, webhooks: r[:webhooks])
      uc[:redeliver_webhook] = A::Webhooks::Redeliver.new(uow: uow, webhooks: r[:webhooks], queue: queue, audit: audit)
      uc[:upload_attachment] = A::Attachments::Upload.new(**common, attachments: r[:attachments], storage: s[:storage], audit: audit, ids: ids,
                                                                    max_bytes: config.max_upload_bytes)
      uc[:download_attachment] = A::Attachments::Download.new(uow: uow, attachments: r[:attachments], storage: s[:storage],
                                                              portal_scope: s.fetch(:portal_scope) { NoPortalScope.new })
      uc[:remove_attachment] = A::Attachments::Remove.new(**common, attachments: r[:attachments], storage: s[:storage], audit: audit)
    end

    # Financeiro: cobranças, pagamentos, reembolsos, cauções, diário, provedores, webhooks e conciliação.
    def build_finance_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      fn = A::Finance
      simulator = I::Payments::Simulator.new(transactor: transactor, clock: clock, ids: ids)
      asaas = I::Payments::Asaas.new(http: @payment_http || I::Payments::HttpClient.new, box: s[:box], sandbox_url: config.asaas_base_url)
      providers = fn::Providers.new("simulator" => simulator, "asaas" => asaas)
      s[:payment_providers] = providers
      ledger = fn::Ledger.new(entries: r[:ledger_entries], ids: ids, clock: clock)
      alert_book = fn::AlertBook.new(alerts: r[:finance_alerts], ids: ids, clock: clock)
      settlement = fn::Settlement.new(payments: r[:payments], deposits: r[:deposits], reservations: r[:reservations], ledger: ledger,
                                      alert_book: alert_book, audit: audit, events: s[:events], clock: clock, ids: ids)
      remote = fn::RemoteSync.new(payments: r[:payments], settlement: settlement, clock: clock)
      target = fn::PaymentTarget.new(receivables: r[:receivables], deposits: r[:deposits])
      accounts = { accounts: r[:payment_accounts] }
      money = { ledger: ledger, audit: audit, clock: clock, ids: ids }
      resolver = fn::ResolveSubmission.new(uow: uow, payments: r[:payments], **accounts, providers: providers, remote: remote,
                                           alert_book: alert_book, queue: queue, audit: audit, clock: clock)
      ingest = fn::IngestWebhook.new(uow: uow, **accounts, inbound: r[:inbound_webhooks], providers: providers, queue: queue, clock: clock, ids: ids)

      uc[:sync_reservation_charges] = fn::SyncReservationCharges.new(uow: uow, reservations: r[:reservations], organizations: r[:organizations],
                                                                     receivables: r[:receivables], alert_book: alert_book, **money)
      uc[:create_manual_charge] = fn::CreateManualCharge.new(uow: uow, reservations: r[:reservations], organizations: r[:organizations],
                                                             receivables: r[:receivables], **money)
      uc[:cancel_receivable] = fn::CancelReceivable.new(uow: uow, receivables: r[:receivables], **money)
      uc[:register_payment] = fn::RegisterPayment.new(uow: uow, payments: r[:payments], target: target, settlement: settlement, clock: clock, ids: ids)
      uc[:request_payment] = fn::RequestPayment.new(uow: uow, payments: r[:payments], **accounts, organizations: r[:organizations], target: target,
                                                    queue: queue, audit: audit, clock: clock, ids: ids)
      uc[:request_refund] = fn::RequestRefund.new(uow: uow, payments: r[:payments], queue: queue, events: s[:events], **money)
      uc[:submit_payment] = fn::SubmitPayment.new(uow: uow, payments: r[:payments], **accounts, customers: r[:customers], reservations: r[:reservations],
                                                  providers: providers, remote: remote, resolver: resolver, queue: queue, audit: audit, clock: clock)
      uc[:resolve_submission] = resolver
      uc[:process_refund] = fn::ProcessRefund.new(uow: uow, payments: r[:payments], **accounts, providers: providers, ledger: ledger, audit: audit,
                                                  events: s[:events], clock: clock)
      uc[:ingest_payment_webhook] = ingest
      uc[:process_payment_webhook] = fn::ProcessWebhook.new(uow: uow, inbound: r[:inbound_webhooks], payments: r[:payments], providers: providers,
                                                            settlement: settlement, clock: clock)
      uc[:simulate_payment] = fn::SimulateProviderEvent.new(uow: uow, payments: r[:payments], **accounts, simulator: simulator, ingest: ingest)
      uc[:open_deposit] = fn::OpenDeposit.new(uow: uow, reservations: r[:reservations], deposits: r[:deposits], audit: audit, clock: clock, ids: ids)
      uc[:move_deposit] = fn::MoveDeposit.new(uow: uow, deposits: r[:deposits], receivables: r[:receivables], **money)
      uc[:reconcile_payments] = fn::Reconcile.new(uow: uow, **accounts, payments: r[:payments], reports: r[:reconciliation], providers: providers,
                                                  resolver: resolver, remote: remote, audit: audit, clock: clock, ids: ids)
      uc[:configure_payment_account] = fn::ConfigureProviderAccount.new(uow: uow, **accounts, limits: s[:limits], box: s[:box], audit: audit,
                                                                        clock: clock, ids: ids)
      uc[:deactivate_payment_account] = fn::DeactivateProviderAccount.new(uow: uow, **accounts, audit: audit, clock: clock)
      uc[:resolve_finance_alert] = fn::ResolveAlert.new(uow: uow, alerts: r[:finance_alerts], audit: audit, clock: clock)
      uc[:issue_invoice] = fn::IssueInvoice.new(uow: uow, reservations: r[:reservations], receivables: r[:receivables], organizations: r[:organizations],
                                                invoices: r[:invoices], audit: audit, clock: clock, ids: ids)
      uc[:finance] = fn::Queries.new(uow: uow, receivables: r[:receivables], payments: r[:payments], deposits: r[:deposits], alerts: r[:finance_alerts],
                                     **accounts, reports: r[:reconciliation], invoices: r[:invoices], ledger_entries: r[:ledger_entries],
                                     reservations: r[:reservations])
    end

    # Escopo de portal antes do portal do cliente existir: nenhum anexo é acessível por clientes.
    class NoPortalScope
      def customer_owns?(*) = false
    end

    # Acesso explícito aos casos de uso por nome, com erro claro para nomes inexistentes.
    class UseCases
      def initialize(map)
        @map = map.freeze
      end

      def [](name)
        @map.fetch(name) { raise KeyError, "caso de uso inexistente: #{name}" }
      end

      def names = @map.keys
    end
  end
end
