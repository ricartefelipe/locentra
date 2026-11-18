# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/portal_support"

# Base dos testes do portal pelos casos de uso: organização com dois clientes, produto com dois
# ativos e worker com FakeMailer para a entrega dos convites.
class PortalFlowCase < DatabaseTest
  include WorkerHelpers
  include PortalHelpers

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Cliente Alfa")
    @other = create_customer(@actor, name: "Cliente Vizinho", document: "11144477735")
    @camera = create_product(@actor, sku: "CAM-PORTAL", tracking: "serialized", pricing: { "daily_cents" => 15_000 })
    register_assets(@actor, @camera, @branch, 2)
    worker_system
    drain
    @mailer.deliveries.clear
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z")
  def document_of(actor, contract) = uc(:get_contract).call(actor, contract.id)[:documents].first["attachment_id"]
end
