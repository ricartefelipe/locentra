# frozen_string_literal: true

module Locentra
  module Application
    # Retenção do histórico de integrações: entregas de webhook, eventos da outbox e webhooks recebidos
    # fora da janela de cada tipo. Executada pelo worker por organização (organization.retention), no
    # contexto do tenant, em lotes curtos (cada lote numa transação própria).
    module Retention
      Windows = Data.define(:outbox_seconds, :deliveries_seconds, :inbound_seconds)

      # Ordem dos passos: entregas antes dos eventos, porque um evento só sai quando não resta entrega.
      STEPS = [
        ["webhook_deliveries", :deliveries_seconds, :purge_finished_deliveries],
        ["webhook_deliveries", :deliveries_seconds, :purge_disabled_endpoint_deliveries],
        ["outbox_events", :outbox_seconds, :purge_dispatched_events],
        ["inbound_webhooks", :inbound_seconds, :purge_processed_inbound]
      ].freeze

      # Remove, no contexto da organização, o histórico de integrações fora da janela (lotes em
      # transações curtas). O corte de cada tipo é calculado uma vez por execução; cada passo para no
      # primeiro lote incompleto ou em `max_batches` lotes (o restante sai na execução seguinte). Os totais
      # removidos somam em `retention/<tipo>` na transação do lote.
      class PurgeHistory
        def initialize(transactor:, retention:, totals:, clock:, windows:, batch_size: 1_000, max_batches: 10)
          @transactor = transactor
          @retention = retention
          @totals = totals
          @clock = clock
          @windows = windows
          @batch_size = batch_size
          @max_batches = max_batches
        end

        def call(organization_id)
          now = @clock.now
          STEPS.each_with_object(Hash.new(0)) do |(kind, window, method), removed|
            before = now - @windows.public_send(window)
            removed[kind] += purge(organization_id, kind, method, before, now)
          end.to_h
        end

        private

        def purge(organization_id, kind, method, before, now)
          total = 0
          @max_batches.times do
            count = @transactor.call(tenant_id: organization_id) do |tx|
              removed = @retention.public_send(method, tx, before: before, limit: @batch_size)
              @totals.add(tx, "retention", kind, removed, now) if removed.positive?
              removed
            end
            total += count
            break if count < @batch_size
          end
          total
        end
      end
    end
  end
end
