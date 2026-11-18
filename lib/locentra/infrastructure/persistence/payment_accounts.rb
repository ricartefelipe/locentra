# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Contas de provedores de pagamento por organização.
      class PaymentAccountRepository
        COLUMNS = "id, organization_id, provider, name, environment, api_key_ciphertext, api_key_hint, webhook_token_hint, active, created_at, deactivated_at"

        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("provider", "name", "environment", "api_key_ciphertext", "api_key_hint", "webhook_token_digest", "webhook_token_hint", "created_by", "created_at")])
            INSERT INTO payment_provider_accounts (id, organization_id, provider, name, environment, api_key_ciphertext, api_key_hint, webhook_token_digest,
                                                   webhook_token_hint, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          SQL
        end

        def active(tx)
          tx.query_one("SELECT #{COLUMNS} FROM payment_provider_accounts WHERE organization_id = $1 AND active", [tx.tenant_id!])
        end

        def find(tx, id)
          tx.query_one("SELECT #{COLUMNS} FROM payment_provider_accounts WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
        end

        def list(tx)
          tx.query("SELECT #{COLUMNS} FROM payment_provider_accounts WHERE organization_id = $1 ORDER BY created_at DESC", [tx.tenant_id!])
        end

        def deactivate(tx, id, now)
          tx.execute("UPDATE payment_provider_accounts SET active = false, deactivated_at = $3 WHERE organization_id = $1 AND id = $2 AND active",
                     [tx.tenant_id!, id, now])
        end

        # Consulta do webhook público, antes de haver tenant: a política webhook_account_lookup só expõe
        # a linha cujo id foi definido em app.payment_account_id nesta transação.
        def for_webhook(tx, id)
          tx.query_one("SELECT set_config('app.payment_account_id', $1, true)", [id])
          tx.query_one("SELECT id, organization_id, provider, webhook_token_digest, active FROM payment_provider_accounts WHERE id = $1", [id])
        end
      end

      # Webhooks recebidos: persistidos e deduplicados antes do processamento.
      class InboundWebhookRepository
        def insert(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("provider", "event_id", "event_type", "payload", "received_at", "provider_account_id")]) == 1
            INSERT INTO inbound_webhooks (id, organization_id, provider, event_id, event_type, payload, received_at, provider_account_id)
            VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8)
            ON CONFLICT (organization_id, provider, event_id) DO NOTHING
          SQL
        end

        # O corpo é lido como texto para que valores decimais sejam convertidos sem Float.
        def lock(tx, id)
          tx.query_one(<<~SQL, [tx.tenant_id!, id])
            SELECT id, provider, provider_account_id, event_id, event_type, status, payload::text AS payload_text, received_at
              FROM inbound_webhooks WHERE organization_id = $1 AND id = $2 FOR UPDATE
          SQL
        end

        def finish(tx, id, status, error, now)
          tx.execute("UPDATE inbound_webhooks SET status = $3, error = $4, processed_at = $5 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, id, status, error, now])
        end

        def recent(tx, limit)
          tx.query(<<~SQL, [tx.tenant_id!, limit])
            SELECT id, provider, event_id, event_type, status, error, received_at, processed_at
              FROM inbound_webhooks WHERE organization_id = $1 AND provider IN ('simulator', 'asaas') ORDER BY received_at DESC LIMIT $2
          SQL
        end
      end

      class ReconciliationRepository
        COLUMNS = "id, account_id, provider, status, window_start, started_at, finished_at, summary, error"

        def insert_report(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("account_id", "provider", "window_start", "started_at")])
            INSERT INTO reconciliation_reports (id, organization_id, account_id, provider, status, window_start, started_at)
            VALUES ($1, $2, $3, $4, 'running', $5, $6)
          SQL
        end

        def complete_report(tx, id, summary, now)
          tx.execute("UPDATE reconciliation_reports SET status = 'completed', summary = $3, finished_at = $4 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, id, summary, now])
        end

        def fail_report(tx, id, error, now)
          tx.execute("UPDATE reconciliation_reports SET status = 'failed', error = $3, finished_at = $4 WHERE organization_id = $1 AND id = $2",
                     [tx.tenant_id!, id, error, now])
        end

        def insert_item(tx, row)
          tx.execute(<<~SQL, [row["id"], tx.tenant_id!, *row.values_at("report_id", "kind", "payment_id", "provider_payment_id", "external_reference", "local_status", "remote_status", "local_amount_cents", "remote_amount_cents", "action", "created_at")])
            INSERT INTO reconciliation_items (id, organization_id, report_id, kind, payment_id, provider_payment_id, external_reference, local_status,
                                              remote_status, local_amount_cents, remote_amount_cents, action, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
          SQL
        end

        def recent(tx, limit)
          tx.query("SELECT #{COLUMNS} FROM reconciliation_reports WHERE organization_id = $1 ORDER BY started_at DESC, id DESC LIMIT $2",
                   [tx.tenant_id!, limit])
        end

        def find(tx, id)
          tx.query_one("SELECT #{COLUMNS} FROM reconciliation_reports WHERE organization_id = $1 AND id = $2", [tx.tenant_id!, id])
        end

        def items(tx, report_id)
          tx.query(<<~SQL, [tx.tenant_id!, report_id])
            SELECT id, kind, payment_id, provider_payment_id, external_reference, local_status, remote_status, local_amount_cents, remote_amount_cents,
                   action, created_at
              FROM reconciliation_items WHERE organization_id = $1 AND report_id = $2 ORDER BY created_at, id
          SQL
        end
      end
    end
  end
end
