# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      class WebhookRepository
        def insert_endpoint(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("url", "description", "events", "secret_ciphertext", "created_by", "created_at")])
            INSERT INTO webhook_endpoints (id, organization_id, url, description, events, secret_ciphertext, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          SQL
        end

        def disable_endpoint(tx, id, now)
          tx.execute("UPDATE webhook_endpoints SET active = false, disabled_at = $3 WHERE organization_id = $1 AND id = $2 AND active",
                     [tx.tenant_id!, id, now])
        end

        def endpoints(tx)
          tx.query(<<~SQL, [tx.tenant_id!])
            SELECT w.id, w.url, w.description, w.events, w.active, w.created_at, w.disabled_at, w.consecutive_failures, w.failing_since, w.paused_at,
                   (SELECT count(*) FROM webhook_deliveries d
                     WHERE d.organization_id = w.organization_id AND d.endpoint_id = w.id AND d.held_at IS NOT NULL) AS held_deliveries
              FROM webhook_endpoints w
             WHERE w.organization_id = $1 ORDER BY w.created_at DESC
          SQL
        end

        # Endpoints inscritos no evento, com FOR KEY SHARE: a reativação (FOR UPDATE) espera o despacho
        # terminar, e assim nenhuma entrega é retida depois do commit da reativação. Não conflita com a
        # atualização do contador de falhas nem com a pausa.
        def endpoints_for(tx, event_type)
          tx.query(<<~SQL, [tx.tenant_id!, event_type])
            SELECT id, paused_at FROM webhook_endpoints WHERE organization_id = $1 AND active AND ($2 = ANY (events) OR '*' = ANY (events))
               FOR KEY SHARE
          SQL
        end

        def lock_event(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT id, event_type, aggregate_type, aggregate_id, payload, correlation_id, occurred_at, dispatched_at
              FROM outbox_events WHERE organization_id = $1 AND id = $2 FOR UPDATE
          SQL
        end

        def mark_dispatched(tx, id, now)
          tx.execute("UPDATE outbox_events SET dispatched_at = $3 WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id, now])
        end

        def insert_delivery(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("endpoint_id", "event_id", "event_type", "created_at", "held_at")]) == 1
            INSERT INTO webhook_deliveries (id, organization_id, endpoint_id, event_id, event_type, created_at, held_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (endpoint_id, event_id) DO NOTHING
          SQL
        end

        def delivery_bundle(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT d.id, d.status, d.event_id, d.event_type, d.endpoint_id, d.held_at, e.payload, e.occurred_at, w.url, w.secret_ciphertext,
                   w.active, w.paused_at
              FROM webhook_deliveries d
              JOIN webhook_endpoints w ON w.organization_id = d.organization_id AND w.id = d.endpoint_id
              JOIN outbox_events e ON e.organization_id = d.organization_id AND e.id = d.event_id
             WHERE d.organization_id = $1 AND d.id = $2
          SQL
        end

        def record_attempt(tx, id, outcome, now)
          tx.execute(<<~SQL, [tx.tenant_id!, id, outcome[:success] ? "delivered" : "failed", outcome[:status], outcome[:error], now])
            UPDATE webhook_deliveries
               SET status = $3, attempts = attempts + 1, last_status_code = $4, last_error = $5, last_attempt_at = $6, held_at = NULL,
                   delivered_at = CASE WHEN $3 = 'delivered' THEN $6::timestamptz ELSE delivered_at END
             WHERE organization_id = $1 AND id = $2 AND status <> 'delivered'
          SQL
        end

        # Retém a entrega enquanto o endpoint está ativo e pausado. O FOR KEY SHARE no endpoint faz a
        # reativação (FOR UPDATE) esperar este commit; se a reativação veio antes, nada é retido (0).
        def hold_delivery(tx, id, endpoint_id, now)
          tx.execute(<<~SQL, [tx.tenant_id!, id, endpoint_id, now])
            WITH endpoint AS (
              SELECT id FROM webhook_endpoints WHERE organization_id = $1 AND id = $3 AND active AND paused_at IS NOT NULL FOR KEY SHARE)
            UPDATE webhook_deliveries d SET held_at = COALESCE(d.held_at, $4::timestamptz)
              FROM endpoint e
             WHERE d.organization_id = $1 AND d.id = $2 AND d.endpoint_id = e.id AND d.status <> 'delivered'
          SQL
        end

        # Atualiza a sequência de falhas do endpoint e devolve o estado do circuito. Sucesso com a
        # sequência já zerada não grava nada (nil): o caminho feliz não disputa a linha do endpoint.
        def register_endpoint_result(tx, endpoint_id, success, now)
          tx.query_one(<<~SQL, [tx.tenant_id!, endpoint_id, success, now])
            UPDATE webhook_endpoints
               SET consecutive_failures = CASE WHEN $3::boolean THEN 0 ELSE consecutive_failures + 1 END,
                   failing_since = CASE WHEN $3::boolean THEN NULL ELSE COALESCE(failing_since, $4::timestamptz) END
             WHERE organization_id = $1 AND id = $2 AND (NOT $3::boolean OR consecutive_failures > 0)
            RETURNING consecutive_failures, failing_since, paused_at, active
          SQL
        end

        def pause_endpoint(tx, id, now)
          tx.execute("UPDATE webhook_endpoints SET paused_at = $3 WHERE organization_id = $1 AND id = $2 AND active AND paused_at IS NULL",
                     [tx.tenant_id!, id, now])
        end

        def lock_endpoint(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT id, active, paused_at, consecutive_failures, failing_since FROM webhook_endpoints WHERE organization_id = $1 AND id = $2 FOR UPDATE
          SQL
        end

        def resume_endpoint(tx, id)
          tx.execute(<<~SQL, [tx.tenant_id!, id])
            UPDATE webhook_endpoints SET paused_at = NULL, consecutive_failures = 0, failing_since = NULL
             WHERE organization_id = $1 AND id = $2 AND paused_at IS NOT NULL
          SQL
        end

        def held_count(tx, endpoint_id)
          tx.query_value(<<~SQL, [tx.tenant_id!, endpoint_id])
            SELECT count(*) FROM webhook_deliveries WHERE organization_id = $1 AND endpoint_id = $2 AND held_at IS NOT NULL
          SQL
        end

        # Endpoint travado contra a reativação concorrente durante a liberação de um lote.
        def lock_endpoint_for_release(tx, id)
          tx.query_one("SELECT id, active, paused_at FROM webhook_endpoints WHERE organization_id = $1 AND id = $2 FOR KEY SHARE", [tx.tenant_id!, id])
        end

        # Lote de entregas retidas devolvido a `pending`, das mais antigas para as mais novas.
        def release_held(tx, endpoint_id, limit)
          tx.query(<<~SQL, [tx.tenant_id!, endpoint_id, limit]).map { |row| row["id"] }
            UPDATE webhook_deliveries d SET held_at = NULL, status = 'pending'
             WHERE d.id IN (SELECT id FROM webhook_deliveries
                             WHERE organization_id = $1 AND endpoint_id = $2 AND held_at IS NOT NULL AND status <> 'delivered'
                             ORDER BY created_at LIMIT $3 FOR UPDATE SKIP LOCKED)
               AND d.organization_id = $1 AND d.held_at IS NOT NULL
            RETURNING d.id
          SQL
        end

        def lock_delivery(tx, id)
          tx.query_one("SELECT id, status FROM webhook_deliveries WHERE organization_id = $1 AND id = $2 FOR UPDATE", [tx.tenant_id!, id])
        end

        def reset_delivery(tx, id)
          tx.execute("UPDATE webhook_deliveries SET status = 'pending', held_at = NULL WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
        end

        def recent_deliveries(tx, limit)
          tx.query(<<~SQL, [tx.tenant_id!, limit])
            SELECT d.id, d.event_type, d.status, d.attempts, d.last_status_code, d.last_error, d.created_at, d.delivered_at, d.held_at, w.url
              FROM webhook_deliveries d JOIN webhook_endpoints w ON w.organization_id = d.organization_id AND w.id = d.endpoint_id
             WHERE d.organization_id = $1 ORDER BY d.created_at DESC LIMIT $2
          SQL
        end
      end

      class AttachmentRepository
        COLUMNS = "id, owner_type, owner_id, filename, content_type, byte_size, sha256, storage_key, created_by, created_at, retain_until"

        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("owner_type", "owner_id", "filename", "content_type", "byte_size", "sha256", "storage_key", "created_by", "created_at", "retain_until")])
            INSERT INTO attachments (id, organization_id, owner_type, owner_id, filename, content_type, byte_size, sha256, storage_key, created_by,
                                     created_at, retain_until)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
          SQL
        end

        def find(tx, id)
          tx.query_one("SELECT #{COLUMNS} FROM attachments WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL", [tx.tenant_id!, id])
        end

        def for_owner(tx, owner_type, owner_id)
          tx.query("SELECT #{COLUMNS} FROM attachments WHERE organization_id = $1 AND owner_type = $2 AND owner_id = $3 AND deleted_at IS NULL " \
                   "ORDER BY created_at DESC", [tx.tenant_id!, owner_type, owner_id])
        end

        def soft_delete(tx, id, now)
          tx.execute("UPDATE attachments SET deleted_at = $3 WHERE organization_id = $1 AND id = $2 AND deleted_at IS NULL", [tx.tenant_id!, id, now])
        end
      end
    end
  end
end
