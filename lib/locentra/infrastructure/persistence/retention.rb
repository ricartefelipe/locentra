# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Retenção do histórico de integrações, sempre no contexto da organização (RLS: sem tenant nenhuma
      # entrega seria visível e o "evento sem entrega restante" valeria para todos). Cada método remove um
      # lote e devolve a quantidade removida. As condições de elegibilidade são repetidas no DELETE
      # externo: em READ COMMITTED, depois de esperar o lock de uma linha alterada por outra transação, o
      # PostgreSQL reavalia somente as condições da tabela-alvo, e assim uma entrega devolvida a `pending`
      # por um reenvio concorrente não é removida.
      class RetentionRepository
        # Entregas concluídas (entregues ou com falha) e não retidas, sem tentativa desde o corte.
        def purge_finished_deliveries(tx, before:, limit:)
          tx.execute(<<~SQL, [tx.tenant_id!, before, limit])
            DELETE FROM webhook_deliveries d
             WHERE d.id IN (SELECT id FROM webhook_deliveries
                             WHERE organization_id = $1 AND status IN ('delivered', 'failed') AND held_at IS NULL AND last_attempt_at < $2
                             ORDER BY last_attempt_at LIMIT $3)
               AND d.organization_id = $1 AND d.status IN ('delivered', 'failed') AND d.held_at IS NULL AND d.last_attempt_at < $2
          SQL
        end

        # Todas as entregas antigas de endpoints desativados antes do corte (a desativação é definitiva).
        def purge_disabled_endpoint_deliveries(tx, before:, limit:)
          tx.execute(<<~SQL, [tx.tenant_id!, before, limit])
            DELETE FROM webhook_deliveries d
             WHERE d.id IN (SELECT x.id FROM webhook_deliveries x
                              JOIN webhook_endpoints w ON w.organization_id = x.organization_id AND w.id = x.endpoint_id
                             WHERE x.organization_id = $1 AND NOT w.active AND w.disabled_at < $2 AND x.created_at < $2
                             ORDER BY x.created_at LIMIT $3)
               AND d.organization_id = $1 AND d.created_at < $2
               AND EXISTS (SELECT 1 FROM webhook_endpoints w
                            WHERE w.organization_id = d.organization_id AND w.id = d.endpoint_id AND NOT w.active AND w.disabled_at < $2)
          SQL
        end

        # Eventos despachados antes do corte e sem nenhuma entrega restante (delivery_bundle lê o evento).
        def purge_dispatched_events(tx, before:, limit:)
          tx.execute(<<~SQL, [tx.tenant_id!, before, limit])
            DELETE FROM outbox_events e
             WHERE e.id IN (SELECT o.id FROM outbox_events o
                             WHERE o.organization_id = $1 AND o.dispatched_at < $2
                               AND NOT EXISTS (SELECT 1 FROM webhook_deliveries d WHERE d.organization_id = o.organization_id AND d.event_id = o.id)
                             ORDER BY o.dispatched_at LIMIT $3)
               AND e.organization_id = $1 AND e.dispatched_at < $2
               AND NOT EXISTS (SELECT 1 FROM webhook_deliveries d WHERE d.organization_id = e.organization_id AND d.event_id = e.id)
          SQL
        end

        # Webhooks recebidos já processados ou ignorados antes do corte (`received` e `failed` ficam).
        def purge_processed_inbound(tx, before:, limit:)
          tx.execute(<<~SQL, [tx.tenant_id!, before, limit])
            DELETE FROM inbound_webhooks i
             WHERE i.id IN (SELECT id FROM inbound_webhooks
                             WHERE organization_id = $1 AND status IN ('processed', 'ignored') AND processed_at < $2
                             ORDER BY processed_at LIMIT $3)
               AND i.organization_id = $1 AND i.status IN ('processed', 'ignored') AND i.processed_at < $2
          SQL
        end
      end

      # Totais globais por desfecho (webhooks entregues, com falha, retidos e liberados, pausas de
      # endpoints e registros removidos pela retenção), gravados pelo worker na mesma transação do fato.
      # Sem organização nem identificadores: somente família, desfecho e total.
      class OutcomeTotalsRepository
        def add(tx, family, outcome, amount, now)
          return if amount.zero?

          tx.execute(<<~SQL, [family, outcome, amount, now])
            INSERT INTO worker_outcome_totals (family, outcome, total, updated_at) VALUES ($1, $2, $3, $4)
            ON CONFLICT (family, outcome) DO UPDATE SET total = worker_outcome_totals.total + EXCLUDED.total, updated_at = EXCLUDED.updated_at
          SQL
        end
      end
    end
  end
end
