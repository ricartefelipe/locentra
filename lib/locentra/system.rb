# frozen_string_literal: true

require_relative "config"
require_relative "infrastructure"
require_relative "infrastructure/observability/logger"
require_relative "wiring/commercial_terms"

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
      @mailer = mailer || I::SmtpMailer.new(**config.smtp)
      @http = http || I::Integrations::SafeHttp.new(allow_http: !config.production?, allow_private: config.test?)
      @transactor = I::Database::Transactor.new(pool: @pool, logger: @logger, metrics: @metrics)
      build_repositories
      @uow = A::UnitOfWork.new(transactor: @transactor, access: @repos[:access], clock: clock, metrics: @metrics)
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
        coupons: P::CouponRepository.new, fees: P::FeeRepository.new, price_agreements: P::PriceAgreementRepository.new,
        credentials: P::CredentialRepository.new, idempotency: P::IdempotencyRepository.new, reports: P::ReportsRepository.new,
        webhooks: P::WebhookRepository.new, attachments: P::AttachmentRepository.new,
        receivables: P::ReceivableRepository.new, payments: P::PaymentRepository.new, deposits: P::DepositRepository.new,
        ledger_entries: P::LedgerRepository.new, finance_alerts: P::FinanceAlertRepository.new, invoices: P::InvoiceRepository.new,
        payment_accounts: P::PaymentAccountRepository.new, inbound_webhooks: P::InboundWebhookRepository.new,
        reconciliation: P::ReconciliationRepository.new,
        fulfillment: P::FulfillmentRepository.new, operational_allocations: P::OperationalAllocationRepository.new,
        inspections: P::InspectionRepository.new, maintenance_orders: P::MaintenanceOrderRepository.new,
        damage_reports: P::DamageReportRepository.new, transfers: P::TransferRepository.new, alerts: P::AlertRepository.new,
        operations: P::OperationsRepository.new,
        quotes: P::QuoteRepository.new, contracts: P::ContractRepository.new, portal: P::PortalRepository.new
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
        pricer: A::Reservations::Pricer.new(pricing: repos[:pricing], ids: ids),
        pricing_rules: Domain::Pricing::Rules.new,
        mailer: @mailer, http: @http,
        box: I::SecretBox.new(config.encryption_key, previous: config.previous_encryption_keys),
        storage: I::Storage::Local.new(root: config.storage_root),
        mail_templates: I::MailTemplates.new(root: File.expand_path("../../views/mailer", __dir__)),
        contract_renderer: I::Documents::ContractPdf.new,
        reservation_guard: A::Reservations::ChangeGuard.new(contracts: repos[:contracts], quotes: repos[:quotes]),
        # Chamadas a provedores de pagamento e webhooks enviados: log com correlação e métricas.
        external_calls: A::ExternalCalls.new(logger: logger, metrics: metrics, clock: clock),
        portal_scope: A::Portal::ContractDocumentScope.new(contracts: repos[:contracts])
      }
      @services[:hold_expiry] = A::Reservations::HoldExpiry.new(reservations: repos[:reservations], audit: @services[:audit], events: @services[:events])
      @services[:allocator] = A::Availability::Allocator.new(repository: repos[:availability], ids: ids, expiry: @services[:hold_expiry])
      @services[:notifications] = A::Notifications::EventNotifications.new(queue: queue, reservations: repos[:reservations], customers: repos[:customers],
                                                                           quotes: repos[:quotes], contracts: repos[:contracts])
      @services[:finance_subscriber] = A::Finance::ReservationChargesSubscriber.new(queue: queue)
      @services[:dispatch_event] = A::Webhooks::DispatchEvent.new(webhooks: repos[:webhooks], queue: queue, notifications: @services[:notifications],
                                                                  clock: clock, ids: ids, subscribers: [@services[:finance_subscriber]])
      @services[:deliver_webhook] = A::Webhooks::Deliver.new(transactor: transactor, webhooks: repos[:webhooks], http: @http, box: @services[:box],
                                                             signer: I::WebhookSignature, clock: clock, calls: @services[:external_calls])
    end

    def common = { uow: uow, clock: clock }

    def build_use_cases
      uc = {}
      build_identity_use_cases(uc)
      build_catalog_use_cases(uc)
      build_reservation_use_cases(uc)
      build_integration_use_cases(uc)
      build_finance_use_cases(uc)
      build_operations_use_cases(uc)
      build_quote_use_cases(uc)
      build_contract_use_cases(uc)
      build_cli_use_cases(uc)
      build_portal_use_cases(uc)
      uc.merge!(Wiring::CommercialTerms.build(uow: uow, repos: repos, services: services, clock: clock, ids: ids))
      @use_cases = UseCases.new(uc)
    end

    def build_identity_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      uc[:sign_up] = A::Identity::SignUp.new(uow: uow, users: r[:users], organizations: r[:organizations], hasher: s[:hasher],
                                             notifier: s[:notifier], clock: clock, ids: ids, audit: audit,
                                             rate_limiter: s[:rate_limiter])
      uc[:authenticate] =
        A::Identity::Authenticate.new(uow: uow, users: r[:users], hasher: s[:hasher], rate_limiter: s[:rate_limiter], clock: clock)
      uc[:confirm_email] = A::Identity::ConfirmEmail.new(uow: uow, tokens: s[:tokens], users: r[:users], clock: clock)
      uc[:request_password_reset] = A::Identity::RequestPasswordReset.new(uow: uow, users: r[:users], rate_limiter: s[:rate_limiter],
                                                                          notifier: s[:notifier])
      uc[:reset_password] = A::Identity::ResetPassword.new(uow: uow, users: r[:users], tokens: s[:tokens], hasher: s[:hasher],
                                                           sessions_repository: r[:sessions], clock: clock)
      uc[:list_memberships] = A::Identity::ListMemberships.new(uow: uow, organizations: r[:organizations])
      uc[:create_branch] =
        A::Organizations::CreateBranch.new(**common, organizations: r[:organizations], limits: s[:limits], audit: audit, ids: ids)
      uc[:invite_member] = A::Organizations::InviteMember.new(**common, organizations: r[:organizations], limits: s[:limits],
                                                                        notifier: s[:notifier], audit: audit, ids: ids)
      uc[:accept_invitation] = A::Organizations::AcceptInvitation.new(**common, organizations: r[:organizations], users: r[:users],
                                                                                hasher: s[:hasher], audit: audit, ids: ids)
      uc[:change_member_role] = A::Organizations::ChangeMemberRole.new(**common, organizations: r[:organizations], audit: audit)
      uc[:revoke_membership] = A::Organizations::RevokeMembership.new(**common, organizations: r[:organizations],
                                                                                sessions_repository: r[:sessions], credentials: r[:credentials],
                                                                                audit: audit)
      uc[:list_members] = A::Organizations::ListMembers.new(uow: uow, organizations: r[:organizations])
      uc[:get_organization] = A::Organizations::GetOrganization.new(uow: uow, organizations: r[:organizations])
      uc[:create_credential] = A::Integrations::CreateCredential.new(**common, credentials: r[:credentials], limits: s[:limits], audit: audit, ids: ids)
      uc[:revoke_credential] = A::Integrations::RevokeCredential.new(**common, credentials: r[:credentials], audit: audit)
      uc[:list_credentials] = A::Integrations::ListCredentials.new(uow: uow, credentials: r[:credentials])
      uc[:authenticate_credential] = A::Integrations::AuthenticateCredential.new(**common, credentials: r[:credentials])
      uc[:idempotency] = A::Idempotency.new(**common, repository: r[:idempotency], ids: ids)
      uc[:dashboard] = A::Reports::Dashboard.new(**common, reports: r[:reports])
      uc[:list_audit] = A::Reports::ListAudit.new(uow: uow, audit: r[:audit])
      uc[:collect_metrics] = A::Reports::CollectMetrics.new(transactor: transactor, reports: r[:reports], metrics: metrics, clock: clock,
                                                            logger: logger)
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
      uc[:confirm_reservation] = A::Reservations::ConfirmReservation.new(uow: uow, allocator: s[:allocator], events: s[:events],
                                                                         guard: s[:reservation_guard], expiry: s[:hold_expiry],
                                                                         **reservation_deps)
      uc[:cancel_reservation] = A::Reservations::CancelReservation.new(uow: uow, events: s[:events], guard: s[:reservation_guard],
                                                                       **reservation_deps)
      uc[:reschedule_reservation] = A::Reservations::RescheduleReservation.new(uow: uow, organizations: r[:organizations],
                                                                               allocator: s[:allocator], guard: s[:reservation_guard],
                                                                               **reservation_deps)
      uc[:extend_reservation] = A::Reservations::ExtendReservation.new(uow: uow, organizations: r[:organizations], allocator: s[:allocator],
                                                                       availability: r[:availability], events: s[:events], ids: ids,
                                                                       guard: s[:reservation_guard], **reservation_deps)
      uc[:expire_holds] = A::Reservations::ExpireHolds.new(uow: uow, reservations: r[:reservations], expiry: s[:hold_expiry], clock: clock)
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
      # Evidências de avaria decidida não podem ser anexadas nem removidas.
      guards = { "damage_report" => A::Inspections::EvidenceGuard.new(damage_reports: r[:damage_reports]) }
      uc[:upload_attachment] = A::Attachments::Upload.new(**common, attachments: r[:attachments], storage: s[:storage], audit: audit, ids: ids,
                                                                    max_bytes: config.max_upload_bytes, guards: guards)
      uc[:download_attachment] = A::Attachments::Download.new(uow: uow, attachments: r[:attachments], storage: s[:storage],
                                                              portal_scope: s[:portal_scope])
      uc[:remove_attachment] = A::Attachments::Remove.new(**common, attachments: r[:attachments], storage: s[:storage], audit: audit, guards: guards)
    end

    # Retirada, devolução, inspeção, avarias, manutenção, transferências e atrasos.
    def build_operations_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      ops = A::Operations
      allocations = r[:operational_allocations]
      ledger = ops::AssetLedger.new(catalog: r[:catalog], ids: ids)
      alert_book = ops::AlertBook.new(alerts: r[:alerts], clock: clock, ids: ids)
      relocation = ops::AssetRelocation.new(availability: r[:availability], allocator: s[:allocator])
      coverage = ops::StockCoverage.new(allocations: allocations)
      desk = ops::MaintenanceDesk.new(orders: r[:maintenance_orders], inspections: r[:inspections], allocations: allocations,
                                      organizations: r[:organizations], ids: ids)
      pickup = { reservations: r[:reservations], fulfillment: r[:fulfillment] }

      uc[:start_pickup] = A::Fulfillment::StartPickup.new(**common, **pickup, audit: audit, ids: ids)
      uc[:check_pickup] = A::Fulfillment::CheckPickup.new(**common, **pickup, allocations: allocations, availability: r[:availability],
                                                                              catalog: r[:catalog], audit: audit)
      uc[:deliver_pickup] = A::Fulfillment::DeliverPickup.new(**common, **pickup, allocations: allocations, availability: r[:availability],
                                                                                  customers: r[:customers], catalog: r[:catalog], ledger: ledger,
                                                                                  audit: audit, events: s[:events])
      uc[:cancel_pickup] = A::Fulfillment::CancelPickup.new(**common, **pickup, audit: audit)
      uc[:get_pickup] = A::Fulfillment::GetPickup.new(uow: uow, **pickup, customers: r[:customers])

      uc[:register_return] = A::Returns::RegisterReturn.new(
        **common, **pickup, allocations: allocations, availability: r[:availability], catalog: r[:catalog], organizations: r[:organizations],
                            desk: desk, damage_reports: r[:damage_reports], ledger: ledger, relocation: relocation, coverage: coverage,
                            alert_book: alert_book, alerts: r[:alerts], audit: audit, events: s[:events], ids: ids
      )
      uc[:return_form] = A::Returns::ReturnForm.new(uow: uow, **pickup, customers: r[:customers])
      uc[:get_return] = A::Returns::GetReturn.new(uow: uow, **pickup)

      inspections = A::Inspections
      uc[:approve_inspection] = inspections::ApproveInspection.new(**common, inspections: r[:inspections], catalog: r[:catalog],
                                                                             allocations: allocations, ledger: ledger, audit: audit)
      uc[:reject_inspection] = inspections::RejectInspection.new(**common, inspections: r[:inspections], catalog: r[:catalog], desk: desk,
                                                                           ledger: ledger, relocation: relocation, alert_book: alert_book, audit: audit)
      uc[:list_inspections] = inspections::ListInspections.new(uow: uow, inspections: r[:inspections])
      uc[:create_damage_report] = inspections::CreateDamageReport.new(**common, fulfillment: r[:fulfillment], damage_reports: r[:damage_reports],
                                                                                organizations: r[:organizations], audit: audit, ids: ids)
      uc[:revise_damage_report] = inspections::ReviseDamageReport.new(**common, damage_reports: r[:damage_reports], audit: audit)
      uc[:approve_damage_charge] = inspections::ApproveDamageCharge.new(**common, damage_reports: r[:damage_reports],
                                                                                  reservations: r[:reservations], audit: audit, ids: ids)
      uc[:dismiss_damage_report] = inspections::DismissDamageReport.new(**common, damage_reports: r[:damage_reports], audit: audit)
      uc[:get_damage_report] = inspections::GetDamageReport.new(uow: uow, damage_reports: r[:damage_reports], attachments: r[:attachments])
      uc[:list_damage_reports] = inspections::ListDamageReports.new(uow: uow, damage_reports: r[:damage_reports])

      maintenance = A::Maintenance
      orders = { orders: r[:maintenance_orders], catalog: r[:catalog] }
      uc[:open_maintenance_order] = maintenance::OpenMaintenanceOrder.new(**common, catalog: r[:catalog], allocations: allocations,
                                                                                    availability: r[:availability], desk: desk, ledger: ledger,
                                                                                    relocation: relocation, audit: audit)
      uc[:start_maintenance] = maintenance::StartMaintenance.new(**common, **orders, ledger: ledger, audit: audit)
      uc[:complete_maintenance] = maintenance::CompleteMaintenance.new(**common, **orders, allocations: allocations, desk: desk, ledger: ledger,
                                                                                           audit: audit)
      uc[:cancel_maintenance] = maintenance::CancelMaintenance.new(**common, **orders, allocations: allocations, desk: desk, ledger: ledger,
                                                                                       audit: audit)
      uc[:list_maintenance_orders] = maintenance::ListMaintenanceOrders.new(uow: uow, orders: r[:maintenance_orders])
      uc[:get_maintenance_order] = maintenance::GetMaintenanceOrder.new(uow: uow, **orders, attachments: r[:attachments])

      transfers = A::Transfers
      uc[:request_transfer] = transfers::RequestTransfer.new(**common, transfers: r[:transfers], catalog: r[:catalog], allocations: allocations,
                                                                       organizations: r[:organizations], audit: audit, ids: ids)
      uc[:dispatch_transfer] = transfers::DispatchTransfer.new(**common, transfers: r[:transfers], catalog: r[:catalog], allocations: allocations,
                                                                         availability: r[:availability], ledger: ledger, audit: audit, ids: ids)
      uc[:receive_transfer] = transfers::ReceiveTransfer.new(**common, transfers: r[:transfers], catalog: r[:catalog], ledger: ledger, audit: audit,
                                                                       ids: ids)
      uc[:cancel_transfer] = transfers::CancelTransfer.new(**common, transfers: r[:transfers], audit: audit)
      uc[:list_transfers] = transfers::ListTransfers.new(uow: uow, transfers: r[:transfers])

      overdue = A::Overdue
      uc[:detect_overdue] = overdue::DetectOverdue.new(**common, operations: r[:operations], alerts: r[:alerts], alert_book: alert_book,
                                                                 allocations: allocations, availability: r[:availability], coverage: coverage,
                                                                 queue: queue, audit: audit)
      uc[:resolve_alert] = overdue::ResolveAlert.new(**common, alerts: r[:alerts], audit: audit)
      uc[:operations_board] = overdue::OperationsBoard.new(**common, operations: r[:operations], alerts: r[:alerts], inspections: r[:inspections],
                                                                     damage_reports: r[:damage_reports], transfers: r[:transfers],
                                                                     organizations: r[:organizations])
      uc[:reservation_operations] = overdue::ReservationOperations.new(uow: uow, fulfillment: r[:fulfillment], alerts: r[:alerts],
                                                                       damage_reports: r[:damage_reports])
    end

    # Orçamentos: compõem criação, confirmação e cancelamento de reservas na mesma transação.
    def build_quote_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      builder = A::Quotes::VersionBuilder.new(organizations: r[:organizations], allocator: s[:allocator], pricer: s[:pricer], ids: ids)
      hold_release = A::Quotes::HoldRelease.new(reservations: r[:reservations], cancel: uc[:cancel_reservation])
      expirer = A::Quotes::Expirer.new(quotes: r[:quotes], hold_release: hold_release, audit: audit, events: s[:events])
      quote_deps = { quotes: r[:quotes], audit: audit, clock: clock }
      uc[:create_quote] = A::Quotes::CreateQuote.new(uow: uow, customers: r[:customers], organizations: r[:organizations], builder: builder, ids: ids,
                                                     **quote_deps)
      uc[:revise_quote] = A::Quotes::ReviseQuote.new(uow: uow, customers: r[:customers], organizations: r[:organizations], builder: builder,
                                                     hold_release: hold_release, **quote_deps)
      uc[:send_quote] = A::Quotes::SendQuote.new(uow: uow, create_reservation: uc[:create_reservation], events: s[:events], **quote_deps)
      uc[:approve_quote] = A::Quotes::ApproveQuote.new(uow: uow, expirer: expirer, events: s[:events], **quote_deps)
      uc[:reject_quote] = A::Quotes::RejectQuote.new(uow: uow, hold_release: hold_release, events: s[:events], **quote_deps)
      uc[:expire_quotes] = A::Quotes::ExpireQuotes.new(uow: uow, quotes: r[:quotes], expirer: expirer, clock: clock)
      uc[:convert_quote] = A::Quotes::ConvertQuote.new(uow: uow, reservations: r[:reservations], create_reservation: uc[:create_reservation],
                                                       confirm_reservation: uc[:confirm_reservation], events: s[:events], **quote_deps)
      uc[:list_quotes] = A::Quotes::ListQuotes.new(uow: uow, quotes: r[:quotes])
      uc[:get_quote] = A::Quotes::GetQuote.new(uow: uow, quotes: r[:quotes], customers: r[:customers], reservations: r[:reservations])
    end

    # Contratos: documentos via Upload de anexos; aditivo e cancelamento compõem casos de uso de reserva.
    def build_contract_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      documents = A::Contracts::DocumentGenerator.new(contracts: r[:contracts], organizations: r[:organizations], renderer: s[:contract_renderer],
                                                      upload: uc[:upload_attachment], ids: ids)
      contract_deps = { contracts: r[:contracts], audit: audit, clock: clock }
      uc[:issue_contract] = A::Contracts::IssueContract.new(uow: uow, reservations: r[:reservations], customers: r[:customers],
                                                            organizations: r[:organizations], quotes: r[:quotes], documents: documents,
                                                            events: s[:events], ids: ids, **contract_deps)
      uc[:accept_contract] = A::Contracts::AcceptContract.new(uow: uow, events: s[:events], **contract_deps)
      uc[:amend_contract] = A::Contracts::AmendContract.new(uow: uow, reservations: r[:reservations], extend_reservation: uc[:extend_reservation],
                                                            documents: documents, organizations: r[:organizations], events: s[:events], ids: ids,
                                                            **contract_deps)
      uc[:cancel_contract] = A::Contracts::CancelContract.new(uow: uow, reservations: r[:reservations], cancel_reservation: uc[:cancel_reservation],
                                                              events: s[:events], ids: ids, **contract_deps)
      uc[:close_contract] = A::Contracts::CloseContract.new(uow: uow, reservations: r[:reservations], **contract_deps)
      uc[:preview_contract_cancellation] = A::Contracts::PreviewCancellation.new(uow: uow, contracts: r[:contracts], clock: clock)
      uc[:list_contracts] = A::Contracts::ListContracts.new(uow: uow, contracts: r[:contracts])
      uc[:get_contract] = A::Contracts::GetContract.new(uow: uow, contracts: r[:contracts], reservations: r[:reservations], clock: clock)
      uc[:reservation_links] = A::Contracts::ReservationLinks.new(uow: uow, contracts: r[:contracts], quotes: r[:quotes])
    end

    # Portal do cliente: concessão e revogação de acesso pela equipe, aceite do convite e operações do
    # próprio cliente, que compõem os casos de uso de disponibilidade e reservas na mesma transação.
    def build_portal_use_cases(cases)
      uc = cases
      s = services
      r = repos
      audit = s[:audit]
      pt = A::Portal
      uc[:invite_portal_contact] = pt::InviteContact.new(**common, portal: r[:portal], customers: r[:customers], limits: s[:limits],
                                                                   notifier: s[:notifier], audit: audit, ids: ids)
      uc[:cancel_portal_invitation] = pt::CancelInvitation.new(**common, portal: r[:portal], audit: audit)
      uc[:accept_portal_invitation] = pt::AcceptInvitation.new(**common, portal: r[:portal], customers: r[:customers], users: r[:users],
                                                                         limits: s[:limits], hasher: s[:hasher], audit: audit, ids: ids)
      uc[:revoke_portal_access] = pt::RevokeAccess.new(**common, portal: r[:portal], sessions_repository: r[:sessions], audit: audit)
      uc[:list_portal_accesses] = pt::ListAccesses.new(**common, portal: r[:portal], customers: r[:customers], limits: s[:limits])
      uc[:portal_home] = pt::Home.new(**common, customers: r[:customers], reservations: r[:reservations], quotes: r[:quotes],
                                                contracts: r[:contracts], receivables: r[:receivables])
      uc[:portal_availability] = pt::CheckAvailability.new(**common, organizations: r[:organizations], check: uc[:check_availability])
      uc[:portal_request_reservation] = pt::RequestReservation.new(uow: uow, create_reservation: uc[:create_reservation])
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
      # Somente os provedores habilitados no processo (PAYMENT_PROVIDERS); em produção, o simulador fica
      # fora por padrão.
      providers = fn::Providers.new({ "simulator" => simulator, "asaas" => asaas }.slice(*config.payment_providers), s[:external_calls])
      s[:payment_providers] = providers
      ledger = fn::Ledger.new(entries: r[:ledger_entries], ids: ids, clock: clock)
      alert_book = fn::AlertBook.new(alerts: r[:finance_alerts], ids: ids, clock: clock)
      settlement = fn::Settlement.new(payments: r[:payments], deposits: r[:deposits], reservations: r[:reservations], ledger: ledger,
                                      alert_book: alert_book, audit: audit, events: s[:events], clock: clock, ids: ids)
      remote = fn::RemoteSync.new(payments: r[:payments], settlement: settlement, clock: clock)
      s[:payment_remote_sync] = remote
      s[:finance_alert_book] = alert_book
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
                                                  providers: providers, remote: remote, resolver: resolver, alert_book: alert_book, audit: audit, clock: clock)
      uc[:resolve_submission] = resolver
      uc[:process_refund] = fn::ProcessRefund.new(uow: uow, payments: r[:payments], **accounts, providers: providers, ledger: ledger, queue: queue,
                                                  audit: audit, events: s[:events], clock: clock)
      uc[:ingest_payment_webhook] = ingest
      uc[:process_payment_webhook] = fn::ProcessWebhook.new(uow: uow, inbound: r[:inbound_webhooks], payments: r[:payments], providers: providers,
                                                            settlement: settlement, alert_book: alert_book, clock: clock)
      uc[:simulate_payment] = fn::SimulateProviderEvent.new(uow: uow, payments: r[:payments], **accounts,
                                                            simulator: config.payment_providers.include?("simulator") ? simulator : nil, ingest: ingest)
      uc[:open_deposit] = fn::OpenDeposit.new(uow: uow, reservations: r[:reservations], deposits: r[:deposits], audit: audit, clock: clock, ids: ids)
      uc[:move_deposit] = fn::MoveDeposit.new(uow: uow, deposits: r[:deposits], receivables: r[:receivables], **money)
      uc[:reconcile_payments] = fn::Reconcile.new(uow: uow, **accounts, payments: r[:payments], reports: r[:reconciliation], providers: providers,
                                                  resolver: resolver, remote: remote, audit: audit, clock: clock, ids: ids)
      uc[:configure_payment_account] = fn::ConfigureProviderAccount.new(uow: uow, **accounts, limits: s[:limits], box: s[:box], audit: audit,
                                                                        clock: clock, ids: ids, enabled: config.payment_providers)
      uc[:deactivate_payment_account] = fn::DeactivateProviderAccount.new(uow: uow, **accounts, audit: audit, clock: clock)
      uc[:resolve_finance_alert] = fn::ResolveAlert.new(uow: uow, alerts: r[:finance_alerts], audit: audit, clock: clock)
      uc[:issue_invoice] = fn::IssueInvoice.new(uow: uow, reservations: r[:reservations], receivables: r[:receivables], organizations: r[:organizations],
                                                invoices: r[:invoices], audit: audit, clock: clock, ids: ids)
      uc[:finance] = fn::Queries.new(uow: uow, receivables: r[:receivables], payments: r[:payments], deposits: r[:deposits], alerts: r[:finance_alerts],
                                     **accounts, reports: r[:reconciliation], invoices: r[:invoices], ledger_entries: r[:ledger_entries],
                                     reservations: r[:reservations])
    end

    # CLI operacional (bin/locentra): identidade autenticada e tarefas mortas da fila. Os demais
    # comandos usam os casos de uso já montados (disponibilidade, reservas, ativos, conciliação).
    def build_cli_use_cases(cases)
      uc = cases
      r = repos
      uc[:whoami] = A::Integrations::WhoAmI.new(uow: uow, credentials: r[:credentials], organizations: r[:organizations])
      uc[:list_failed_jobs] = A::Jobs::ListFailures.new(uow: uow, queue: queue)
      uc[:retry_job] = A::Jobs::RetryJob.new(uow: uow, queue: queue, audit: services[:audit])
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
