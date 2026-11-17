# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Conciliação básica com o provedor da conta ativa: compara pagamentos locais e cobranças
      # remotas (ausentes, situação divergente, valor divergente, duplicadas) e grava o relatório.
      # Correções seguras são aplicadas no ato: envio sem confirmação encontrado no provedor e
      # pagamento confirmado no provedor ainda pendente no Locentra (webhook perdido).
      class Reconcile
        WINDOW_DAYS = 30
        LOCAL_STATUSES = %w[pending_submission submission_unknown pending confirmed cancelled].freeze

        def initialize(uow:, accounts:, payments:, reports:, providers:, resolver:, remote:, audit:, clock:, ids:)
          @uow = uow
          @accounts = accounts
          @payments = payments
          @reports = reports
          @providers = providers
          @resolver = resolver
          @remote = remote
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor)
          context = @uow.run(actor, "finance.write") { |tx, _| start(tx) }
          return :no_account unless context

          remotes = fetch(actor, context)
          return context[:report_id] unless remotes

          @uow.run(actor, "finance.write") { |tx, current| finish(tx, current, context, remotes) }
        end

        private

        def start(tx)
          account = @accounts.active(tx)
          return nil unless account

          since = @clock.now - (WINDOW_DAYS * 86_400)
          report_id = @ids.uuid
          @reports.insert_report(tx, "id" => report_id, "account_id" => account["id"], "provider" => account["provider"], "window_start" => since,
                                     "started_at" => @clock.now)
          rows = @payments.for_reconciliation(tx, account["id"], since)
          { account: account, since: since, report_id: report_id, rows: rows }
        end

        def fetch(actor, context)
          @providers.for(context[:account]["provider"]).list_charges(context[:account], since: context[:since])
        rescue ProviderError => e
          @uow.run(actor, "finance.write") { |tx, _| @reports.fail_report(tx, context[:report_id], e.message.to_s[0, 500], @clock.now) }
          nil
        end

        def finish(tx, actor, context, remotes)
          locals = context[:rows].select { |p| LOCAL_STATUSES.include?(p.status) }.map do |p|
            F::Reconciliation::Local.new(payment_id: p.id, external_reference: p.external_reference, provider_payment_id: p.provider_payment_id,
                                         status: p.status, amount: p.amount)
          end
          remote_rows = remotes.map do |c|
            F::Reconciliation::Remote.new(provider_payment_id: c.provider_payment_id, external_reference: c.external_reference.to_s,
                                          status: c.status, amount: c.amount)
          end
          by_reference = remotes.group_by { |c| c.external_reference.to_s }
          found = F::Reconciliation.compare(locals, remote_rows, known_references: context[:rows].map(&:external_reference)) +
                  unknown_absent(locals, by_reference)
          found.each { |d| record_item(tx, actor, context[:report_id], d, by_reference.fetch(d.external_reference.to_s, [])) }
          summary = F::Reconciliation.summary(found, checked: locals.size)
          @reports.complete_report(tx, context[:report_id], summary, @clock.now)
          @audit.record(tx, actor, "reconciliation.completed", "reconciliation_report", context[:report_id], summary)
          context[:report_id]
        end

        # Envio sem confirmação e sem cobrança no provedor: seguro reenviar com a mesma referência.
        def unknown_absent(locals, by_reference)
          locals.select { |l| l.status == "submission_unknown" && !by_reference.key?(l.external_reference) }.map do |local|
            F::Reconciliation.discrepancy("missing_remote", local, nil)
          end
        end

        def record_item(tx, actor, report_id, discrepancy, matches)
          action = correct(tx, actor, discrepancy, matches)
          @reports.insert_item(tx, "id" => @ids.uuid, "report_id" => report_id, "kind" => discrepancy.kind, "payment_id" => discrepancy.payment_id,
                                   "provider_payment_id" => discrepancy.provider_payment_id, "external_reference" => discrepancy.external_reference,
                                   "local_status" => discrepancy.local_status, "remote_status" => discrepancy.remote_status,
                                   "local_amount_cents" => discrepancy.local_amount&.cents, "remote_amount_cents" => discrepancy.remote_amount&.cents,
                                   "action" => action, "created_at" => @clock.now)
        end

        def correct(tx, actor, discrepancy, matches)
          return "review" unless discrepancy.payment_id

          case [discrepancy.kind, discrepancy.local_status]
          in ["missing_remote", "submission_unknown"]
            @resolver.resolve(tx, actor, discrepancy.payment_id, []) == :resubmission_scheduled ? "resubmission_scheduled" : "review"
          in ["status_mismatch", "submission_unknown"]
            @resolver.resolve(tx, actor, discrepancy.payment_id, matches) == :resolved ? "local_updated" : "review"
          in ["status_mismatch", "pending"] if discrepancy.remote_status == "confirmed"
            payment = @payments.lock(tx, discrepancy.payment_id)
            return "review" unless payment.status == "pending"

            @remote.apply(tx, actor, payment, matches.first)
            "local_updated"
          else "review"
          end
        end
      end
    end
  end
end
