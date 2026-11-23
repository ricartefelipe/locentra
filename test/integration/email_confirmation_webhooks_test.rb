# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/webhook_support"

# Endpoint de webhook cadastrado por conta ainda não confirmada (possível com a 1.3.0 durante a implantação
# gradual ou no retorno, ADR-031): o despacho não cria entregas para ele e a entrega já criada é encerrada
# como falha, sem chamada de rede e sem contar no circuito. Depois da confirmação de quem o cadastrou, os
# eventos novos voltam a sair. Endpoint sem autor registrado não tem situação de e-mail.
class EmailConfirmationWebhooksTest < DatabaseTest
  include WorkerHelpers
  include WebhookHelpers

  def setup
    super
    @org = create_organization
    worker_system
    drain
    @server = CaptureServer.new(status: 200)
    @endpoint = uc(:create_webhook).call(@org[:actor], url: @server.url("/hook/erp"), events: ["*"])["id"]
  end

  def teardown
    @server&.stop
    @worker_system&.shutdown
    super
  end

  def unconfirm = owner_query("UPDATE users SET email_confirmed_at = NULL WHERE id = $1", [@org[:user_id]], tenant: "")

  def delivery_rows
    owner_query("SELECT status, attempts, last_error FROM webhook_deliveries ORDER BY created_at, id", tenant: @org[:organization_id])
  end

  def test_unconfirmed_creator_gets_no_deliveries_until_confirmation
    unconfirm
    dispatch_events(@org, 2)
    drain

    assert_empty delivery_rows, "o despacho não cria entregas para o endpoint"
    assert_equal 0, @server.requests.size
    confirm_email(@org[:user_id])
    dispatch_events(@org)
    drain

    assert_equal([%w[delivered 1]], delivery_rows.map { |row| row.values_at("status", "attempts") })
    assert_equal 1, @server.requests.size
  end

  def test_delivery_created_before_is_closed_without_network_or_circuit
    dispatch_events(@org)
    unconfirm
    drain
    row = delivery_rows.first

    assert_equal %w[failed 0], row.values_at("status", "attempts")
    assert_equal Locentra::Application::Webhooks::Deliver::CREATOR_UNCONFIRMED, row["last_error"]
    assert_equal 0, @server.requests.size
    assert_equal "0", endpoint_row(@org, @endpoint)["consecutive_failures"], "o circuito não conta a entrega recusada"
    assert_equal(%w[succeeded], webhook_jobs.map { |job| job["status"] }, "uma única execução, sem novas tentativas")
  end

  def test_endpoint_without_recorded_creator_keeps_delivering
    owner_query("UPDATE webhook_endpoints SET created_by = NULL", [], tenant: @org[:organization_id])
    unconfirm
    dispatch_events(@org)
    drain

    assert_equal(["delivered"], delivery_rows.map { |row| row["status"] })
  end
end
