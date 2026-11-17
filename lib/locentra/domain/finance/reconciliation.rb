# frozen_string_literal: true

module Locentra
  module Domain
    module Finance
      # Situações normalizadas de cobranças no provedor.
      REMOTE_STATUSES = {
        "pending" => "Pendente", "confirmed" => "Paga", "refunded" => "Estornada", "cancelled" => "Removida", "disputed" => "Em contestação"
      }.freeze

      # Conciliação básica: compara pagamentos locais com as cobranças do provedor.
      module Reconciliation
        KINDS = {
          "missing_remote" => "Ausente no provedor", "missing_local" => "Ausente no Locentra", "status_mismatch" => "Situação divergente",
          "amount_mismatch" => "Valor divergente", "duplicate_remote" => "Cobrança duplicada no provedor"
        }.freeze
        ACTIONS = { "review" => "Revisar", "local_updated" => "Atualizado no Locentra", "resubmission_scheduled" => "Novo envio agendado" }.freeze

        # Situação local compatível com cada situação remota.
        COMPATIBLE = {
          "pending" => %w[pending], "confirmed" => %w[confirmed refunded], "cancelled" => %w[cancelled], "failed" => %w[cancelled]
        }.freeze
        # Pagamentos ainda não enviados (ou com envio em dúvida) podem não existir no provedor.
        MAY_BE_ABSENT = %w[pending_submission submission_unknown].freeze

        Local = Data.define(:payment_id, :external_reference, :provider_payment_id, :status, :amount)
        Remote = Data.define(:provider_payment_id, :external_reference, :status, :amount)
        Discrepancy = Data.define(:kind, :payment_id, :provider_payment_id, :external_reference, :local_status, :remote_status,
                                  :local_amount, :remote_amount) do
          def kind_label = KINDS.fetch(kind)
        end

        module_function

        # `known_references`: referências externas de todos os pagamentos locais da conta (qualquer
        # situação), para que uma cobrança remota de pagamento local não seja tida como ausente.
        def compare(locals, remotes, known_references: locals.map(&:external_reference))
          by_reference = remotes.group_by(&:external_reference)
          found = locals.flat_map { |local| compare_local(local, by_reference.fetch(local.external_reference, [])) }
          known = known_references.to_h { |ref| [ref, true] }
          orphans = remotes.reject { |remote| known.key?(remote.external_reference) }.map do |remote|
            Discrepancy.new(kind: "missing_local", payment_id: nil, provider_payment_id: remote.provider_payment_id,
                            external_reference: remote.external_reference, local_status: nil, remote_status: remote.status,
                            local_amount: nil, remote_amount: remote.amount)
          end
          found + orphans
        end

        def compare_local(local, matches)
          return [] if matches.empty? && MAY_BE_ABSENT.include?(local.status)
          return [discrepancy("missing_remote", local, nil)] if matches.empty?
          return [discrepancy("duplicate_remote", local, matches.first)] if matches.size > 1

          remote = matches.first
          list = []
          list << discrepancy("amount_mismatch", local, remote) unless remote.amount == local.amount
          list << discrepancy("status_mismatch", local, remote) unless COMPATIBLE.fetch(local.status, []).include?(remote.status)
          list
        end

        def discrepancy(kind, local, remote)
          Discrepancy.new(kind: kind, payment_id: local.payment_id, provider_payment_id: remote&.provider_payment_id || local.provider_payment_id,
                          external_reference: local.external_reference, local_status: local.status, remote_status: remote&.status,
                          local_amount: local.amount, remote_amount: remote&.amount)
        end

        def summary(discrepancies, checked:)
          counts = KINDS.keys.to_h { |kind| [kind, 0] }
          discrepancies.each { |d| counts[d.kind] += 1 }
          { "checked" => checked, "discrepancies" => discrepancies.size, "by_kind" => counts }
        end
      end
    end
  end
end
