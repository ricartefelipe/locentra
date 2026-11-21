# frozen_string_literal: true

# Cenários de webhooks enviados (requer WorkerHelpers): eventos publicados e despachados pelo worker no
# contexto da organização, endpoint pausado diretamente no banco e consultas pelo papel proprietário.
module WebhookHelpers
  # Publica e despacha `count` eventos da organização; devolve os identificadores dos eventos.
  def dispatch_events(org, count = 1, system: worker_system, request_id: nil, event_type: "reservation.confirmed")
    Array.new(count) do
      system.transactor.call(tenant_id: org[:organization_id], request_id: request_id) do |tx|
        event = system.services[:events].publish(tx, event_type, "reservation", SecureRandom.uuid, { "code" => "R-000001" })
        system.services[:dispatch_event].call(tx, event)
        event
      end
    end
  end

  # Endpoint pausado pelo circuito (estado gravado diretamente, como a pausa automática deixaria).
  def pause_endpoint!(org, endpoint_id, failures: 20, since: @clock.now - 3600)
    owner_query(<<~SQL, [endpoint_id, failures, since, @clock.now], tenant: org[:organization_id])
      UPDATE webhook_endpoints SET consecutive_failures = $2, failing_since = $3, paused_at = $4 WHERE id = $1
    SQL
  end

  def endpoint_row(org, endpoint_id)
    owner_query("SELECT active, consecutive_failures, failing_since, paused_at FROM webhook_endpoints WHERE id = $1", [endpoint_id],
                tenant: org[:organization_id]).first
  end

  def deliveries_of(org)
    owner_query("SELECT id, status, attempts, held_at FROM webhook_deliveries ORDER BY created_at, id", tenant: org[:organization_id])
  end

  def outcome_totals
    owner_query("SELECT family, outcome, total FROM worker_outcome_totals ORDER BY family, outcome", tenant: nil)
      .to_h { |row| [[row["family"], row["outcome"]], row["total"].to_i] }
  end

  def webhook_jobs(kind = "webhooks.deliver") = jobs("kind = '#{kind}'")
end
