# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Conciliação básica com o provedor: compara pagamentos locais e cobranças remotas (ausentes,
      # situação divergente, valor divergente, duplicadas) e grava o relatório.
      #
      # - A listagem do provedor (janela com margem) é a base da comparação; listagem incompleta não
      #   prova ausência de nenhuma cobrança.
      # - Envio sem confirmação ausente da listagem é consultado pela referência externa, um a um,
      #   antes de qualquer decisão; novo envio só com consulta conclusiva (ResolveSubmission).
      # - Pagamentos em aberto de contas desativadas são consultados com as credenciais da própria conta.
      # - Cobranças remotas só são "ausentes no Locentra" se a referência não for de nenhum pagamento.
      # Correções seguras são aplicadas no ato: envio sem confirmação resolvido e pagamento confirmado
      # no provedor ainda pendente no Locentra (webhook perdido). As demais ficam para revisão.
      class Reconcile
        WINDOW_DAYS = 30
        LEGACY_LIMIT = 50
        LOCAL_STATUSES = %w[pending_submission submission_unknown pending confirmed cancelled].freeze
        # Respostas inválidas do provedor: o relatório falha com a mensagem e a tarefa termina.
        EXPECTED_ERRORS = [ProviderError, Domain::ValidationError, KeyError, TypeError].freeze

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

          gathered = guarded(actor, context) { gather(actor, context) }
          return context[:report_id] unless gathered

          begin
            @uow.run(actor, "finance.write") { |tx, current| finish(tx, current, context, gathered) }
          rescue StandardError => e
            fail_report(actor, context, e)
            raise
          end
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
          legacy = @payments.open_from_inactive_accounts(tx, since, LEGACY_LIMIT)
          { account: account, since: since, report_id: report_id, rows: rows, legacy: legacy,
            legacy_accounts: legacy.map(&:provider_account_id).uniq.to_h { |id| [id, @accounts.find(tx, id)] },
            refunded: @payments.committed_refunds_by_payment(tx, rows.select(&:confirmed?).map(&:id)) }
        end

        # Chamadas ao provedor, fora de transação.
        def gather(actor, context)
          account = context[:account]
          listed_at = @clock.now
          listing = @providers.for(account["provider"], actor: actor).list_charges(account, since: context[:since])
          listed = listing.charges.to_h { |c| [c.external_reference.to_s, true] }
          unknown = context[:rows].select { |p| p.status == "submission_unknown" && !listed.key?(p.external_reference) }
          lookups = unknown.to_h { |p| [p.id, Lookup.perform(@providers, account, p, @clock, actor: actor)] }
          legacy, failures = legacy_lookups(actor, context)
          { listing: listing, listed_at: listed_at, lookups: lookups.merge(legacy), legacy_checked: legacy.size, legacy_failures: failures }
        end

        # Credenciais de conta desativada podem ter sido revogadas: a falha de uma consulta não
        # interrompe a conciliação da conta ativa.
        def legacy_lookups(actor, context)
          failures = 0
          found = context[:legacy].each_with_object({}) do |payment, result|
            account = context[:legacy_accounts].fetch(payment.provider_account_id)
            result[payment.id] = Lookup.perform(@providers, account, payment, @clock, actor: actor)
          rescue ProviderError
            failures += 1
          end
          [found, failures]
        end

        def finish(tx, actor, context, gathered)
          payments = (context[:rows] + context[:legacy].select { |p| gathered[:lookups].key?(p.id) }).select { |p| LOCAL_STATUSES.include?(p.status) }
          locals = payments.map { |p| local_of(p, context[:refunded]) }
          by_reference = charges_of(gathered).group_by { |c| c.external_reference.to_s }
          found = compare(tx, locals, by_reference, verified(gathered, payments)) + unknown_absent(locals, gathered[:lookups])
          by_id = payments.to_h { |p| [p.id, p] }
          found.each do |d|
            matches = by_reference.fetch(d.external_reference.to_s, [])
            record_item(tx, context[:report_id], d, correct(tx, actor, d, matches, lookup_for(d, by_id, matches, gathered)))
          end
          summary = summary_of(found, locals, gathered)
          @reports.complete_report(tx, context[:report_id], summary, @clock.now)
          @audit.record(tx, actor, "reconciliation.completed", "reconciliation_report", context[:report_id], summary)
          context[:report_id]
        end

        # A mesma cobrança pode vir da listagem e de uma consulta (conta substituída no mesmo provedor).
        def charges_of(gathered)
          (gathered[:listing].charges + gathered[:lookups].values.flat_map(&:charges)).uniq(&:provider_payment_id)
        end

        def compare(tx, locals, by_reference, verified)
          remotes = by_reference.values.flatten.map { |c| remote_of(c) }
          F::Reconciliation.compare(locals, remotes, known_references: known(tx, locals, by_reference), verified: verified)
        end

        def summary_of(found, locals, gathered)
          F::Reconciliation.summary(found, checked: locals.size)
                           .merge("complete" => gathered[:listing].complete, "legacy_checked" => gathered[:legacy_checked],
                                  "legacy_failures" => gathered[:legacy_failures])
        end

        def local_of(payment, refunded)
          F::Reconciliation::Local.new(payment_id: payment.id, external_reference: payment.external_reference, provider_payment_id: payment.provider_payment_id,
                                       status: payment.status, amount: payment.amount, refunded: refunded.fetch(payment.id, Domain::Money.zero))
        end

        def remote_of(charge)
          F::Reconciliation::Remote.new(provider_payment_id: charge.provider_payment_id, external_reference: charge.external_reference.to_s,
                                        status: charge.status, amount: charge.amount)
        end

        # Referências de pagamentos locais mais as de qualquer pagamento da organização entre as
        # cobranças remotas desconhecidas (pagamentos antigos, de outra conta ou fora da janela).
        def known(tx, locals, by_reference)
          refs = locals.map(&:external_reference)
          refs + @payments.existing_references(tx, by_reference.keys - refs)
        end

        # Ausência conclusiva: toda a conta ativa com listagem completa; com listagem incompleta, só os
        # pagamentos consultados pela referência. Pagamentos de contas desativadas, só se consultados.
        def verified(gathered, payments)
          return nil if gathered[:listing].complete

          payments.select { |p| gathered[:lookups].key?(p.id) }.map(&:external_reference)
        end

        # Envio sem confirmação consultado pela referência e sem cobrança no provedor.
        def unknown_absent(locals, lookups)
          locals.select { |l| l.status == "submission_unknown" && lookups[l.payment_id]&.charges&.empty? }.map do |local|
            F::Reconciliation.discrepancy("missing_remote", local, nil)
          end
        end

        def lookup_for(discrepancy, by_id, matches, gathered)
          gathered[:lookups].fetch(discrepancy.payment_id) do
            payment = by_id[discrepancy.payment_id]
            payment && Lookup.new(charges: matches, at: gathered[:listed_at], attempt: payment.submission_attempts)
          end
        end

        def record_item(tx, report_id, discrepancy, action)
          @reports.insert_item(tx, "id" => @ids.uuid, "report_id" => report_id, "kind" => discrepancy.kind, "payment_id" => discrepancy.payment_id,
                                   "provider_payment_id" => discrepancy.provider_payment_id, "external_reference" => discrepancy.external_reference,
                                   "local_status" => discrepancy.local_status, "remote_status" => discrepancy.remote_status,
                                   "local_amount_cents" => discrepancy.local_amount&.cents, "remote_amount_cents" => discrepancy.remote_amount&.cents,
                                   "action" => action, "created_at" => @clock.now)
        end

        # Divergência de valor e cobrança remota sem pagamento local sempre vão para revisão.
        def correct(tx, actor, discrepancy, matches, lookup)
          return "review" if discrepancy.payment_id.nil? || discrepancy.kind == "amount_mismatch"

          case [discrepancy.kind, discrepancy.local_status]
          in [_, "submission_unknown"]
            ResolveSubmission::OUTCOME_ACTIONS.fetch(@resolver.resolve(tx, actor, discrepancy.payment_id, lookup), "review")
          in ["status_mismatch", "pending"] if discrepancy.remote_status == "confirmed"
            confirm_lost_webhook(tx, actor, discrepancy.payment_id, matches.first)
          else "review"
          end
        end

        # Pagamento confirmado no provedor e pendente no Locentra (webhook perdido), pela cobrança associada.
        def confirm_lost_webhook(tx, actor, payment_id, charge)
          payment = @payments.lock(tx, payment_id)
          return "review" unless payment.status == "pending"
          return "review" unless payment.provider_payment_id.nil? || payment.provider_payment_id == charge.provider_payment_id

          @remote.apply(tx, actor, payment, charge)
          "local_updated"
        end

        def guarded(actor, context)
          yield
        rescue StandardError => e
          fail_report(actor, context, e)
          raise unless EXPECTED_ERRORS.any? { |kind| e.is_a?(kind) }

          nil
        end

        def fail_report(actor, context, error)
          message = error.is_a?(ProviderError) ? error.message : "resposta inválida do provedor (#{error.class.name.split("::").last}: #{error.message})"
          @uow.run(actor, "finance.write") { |tx, _| @reports.fail_report(tx, context[:report_id], message.to_s[0, 500], @clock.now) }
        end
      end
    end
  end
end
