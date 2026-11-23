# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Consultas do financeiro (somente leitura, permissão finance.read; o extrato do cliente também
      # atende o portal).
      class Queries
        RECEIVABLE_FILTERS = F::RECEIVABLE_STATUSES.keys.freeze

        def initialize(uow:, receivables:, payments:, deposits:, alerts:, accounts:, reports:, invoices:, ledger_entries:, reservations:)
          @uow = uow
          @receivables = receivables
          @payments = payments
          @deposits = deposits
          @alerts = alerts
          @accounts = accounts
          @reports = reports
          @invoices = invoices
          @ledger_entries = ledger_entries
          @reservations = reservations
        end

        def overview(actor, status: nil, limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          raise Domain::ValidationError.field("situacao", "inválida") if status && !RECEIVABLE_FILTERS.include?(status)

          read(actor) do |tx|
            items, total = @receivables.search(tx, status: status, limit: lim, offset: off)
            { receivables: Page.new(items: items, limit: lim, offset: off, total: total), totals: @receivables.totals(tx),
              payments: @payments.recent(tx, 20), alerts: @alerts.open(tx, 50), deposits: @deposits.held(tx, 50),
              reports: @reports.recent(tx, 5), account: @accounts.active(tx), trial_balance: @ledger_entries.trial_balance(tx) }
          end
        end

        def receivable(actor, receivable_id)
          read(actor) do |tx|
            receivable = @receivables.find(tx, Domain::Identifier.parse(receivable_id, "cobranca")) || raise(Domain::NotFound, "cobrança")
            { receivable: receivable, balance: @receivables.balance(tx, receivable.id), cancellation: @receivables.cancellation(tx, receivable.id),
              payments: @payments.for_receivable(tx, receivable.id), reservation: @reservations.find(tx, receivable.reservation_id),
              deposit: @deposits.for_reservation(tx, receivable.reservation_id), account: @accounts.active(tx),
              entries: @ledger_entries.for_source(tx, "receivable", receivable.id) }
          end
        end

        def payment(actor, payment_id)
          read(actor) do |tx|
            payment = @payments.find(tx, Domain::Identifier.parse(payment_id, "pagamento")) || raise(Domain::NotFound, "pagamento")
            committed = @payments.committed_refunds(tx, payment.id)
            { payment: payment, refunds: @payments.refunds(tx, payment.id), eligible: F::RefundPolicy.eligible(payment, committed),
              reservation: @reservations.find(tx, payment.reservation_id), alerts: @alerts.for_payment(tx, payment.id),
              entries: @ledger_entries.for_source(tx, "payment", payment.id) }
          end
        end

        def deposit(actor, deposit_id)
          read(actor) do |tx|
            deposit = @deposits.find(tx, Domain::Identifier.parse(deposit_id, "caucao")) || raise(Domain::NotFound, "caução")
            { deposit: deposit, ledger: @deposits.ledger(tx, deposit.id), entries: @deposits.entries(tx, deposit.id),
              payments: @payments.for_deposit(tx, deposit.id), receivables: @receivables.for_reservation(tx, deposit.reservation_id),
              reservation: @reservations.find(tx, deposit.reservation_id), account: @accounts.active(tx) }
          end
        end

        # Painel financeiro da reserva.
        def reservation(actor, reservation_id)
          read(actor) do |tx|
            id = Domain::Identifier.parse(reservation_id, "reserva")
            deposit = @deposits.for_reservation(tx, id)
            { receivables: @receivables.for_reservation(tx, id), deposit: deposit, deposit_ledger: deposit && @deposits.ledger(tx, deposit.id),
              payments: @payments.for_reservation(tx, id), alerts: @alerts.for_reservation(tx, id), invoices: @invoices.for_reservation(tx, id) }
          end
        end

        def report(actor, report_id)
          read(actor) do |tx|
            report = @reports.find(tx, Domain::Identifier.parse(report_id, "relatorio")) || raise(Domain::NotFound, "relatório")
            { report: report, items: @reports.items(tx, report["id"]) }
          end
        end

        def invoice(actor, invoice_id)
          read(actor) do |tx|
            @invoices.find(tx, Domain::Identifier.parse(invoice_id, "fatura")) || raise(Domain::NotFound, "fatura")
          end
        end

        # Extrato de um cliente: cobranças com saldo derivado, totais em aberto e cauções. O cliente do
        # portal consulta somente o próprio extrato (`portal.access`, cliente do acesso); a equipe usa
        # `finance.read`. Diário contábil, alertas, conciliação e dados do provedor não fazem parte dele.
        # Cobranças e cauções são páginas independentes (Page); os totais consideram todas as cobranças.
        def customer_statement(actor, customer_id: nil, limit: nil, offset: nil, deposits_limit: nil, deposits_offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          deposits_lim, deposits_off = Page.params(limit: deposits_limit, offset: deposits_offset)
          @uow.run(actor, actor.customer? ? "portal.access" : "finance.read") do |tx, current|
            id = current.customer? ? current.customer_id : Domain::Identifier.parse(customer_id, "cliente")
            receivables, receivables_total = @receivables.for_customer(tx, id, limit: lim, offset: off)
            deposits, deposits_total = @deposits.for_customer(tx, id, limit: deposits_lim, offset: deposits_off)
            { receivables: Page.new(items: receivables, limit: lim, offset: off, total: receivables_total),
              totals: @receivables.customer_totals(tx, id),
              deposits: Page.new(items: deposits, limit: deposits_lim, offset: deposits_off, total: deposits_total) }
          end
        end

        def accounts(actor)
          @uow.run(actor, "integrations.manage", read: true) { |tx, _| @accounts.list(tx) }
        end

        private

        def read(actor)
          @uow.run(actor, "finance.read") { |tx, _| yield tx }
        end
      end
    end
  end
end
