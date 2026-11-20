# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Publica eventos de negócio na outbox e agenda o despacho na mesma transação.
      class EventPublisher
        def initialize(queue:, clock:, ids:)
          @queue = queue
          @clock = clock
          @ids = ids
        end

        def publish(tx, event_type, aggregate_type, aggregate_id, payload = {})
          id = @ids.uuid
          correlation = tx.request_id
          tx.execute(<<~SQL, [id, tx.tenant_id!, event_type, aggregate_type, aggregate_id, payload, correlation, @clock.now])
            INSERT INTO outbox_events (id, organization_id, event_type, aggregate_type, aggregate_id, payload, correlation_id, occurred_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          SQL
          @queue.enqueue(tx, "events.dispatch", { "event_id" => id }, correlation_id: correlation, priority: 50)
          id
        end
      end
    end
  end
end
