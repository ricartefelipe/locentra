# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/worker_support"
require_relative "../support/portal_support"

# Base dos testes de telas do portal do cliente: organização com dois clientes, produto com três
# ativos, worker com FakeMailer e auxiliares de navegação com sessão de portal.
class PortalHttpTest < HttpTest
  include WorkerHelpers
  include PortalHelpers

  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Cliente <b>Portal</b>")
    @other = create_customer(@actor, name: "Cliente Vizinho", document: "11144477735")
    @camera = create_product(@actor, sku: "CAM-WEB", tracking: "serialized", pricing: { "daily_cents" => 15_000 })
    register_assets(@actor, @camera, @branch, 3)
    worker_system
    drain
    @mailer.deliveries.clear
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def get_ok(path)
    get path
  rescue Rack::Lint::LintError => e
    flunk "#{path}: #{e.message}"
  else
    assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
    last_response.body
  end

  def portal_csrf
    get "/portal" unless last_response&.body.to_s.include?("_csrf")
    last_response.body[/name="_csrf" value="([^"]+)"/, 1] || raise("token CSRF não encontrado")
  end

  def portal_post(path, params) = post(path, params.merge("_csrf" => portal_csrf))

  def portal_login(email = "paula@cliente.test")
    login(email, PORTAL_PASSWORD)

    assert_equal "/portal", last_request.path
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z")

  def request_form(quantity, extra = {})
    { "filial" => @branch.id, "inicio" => "2026-03-10T05:00", "fim" => "2026-03-11T05:00", "produto" => [@camera.id],
      "quantidade" => [quantity] }.merge(extra)
  end

  private

  def csrf_in_page = last_response.body[/name="_csrf" value="([^"]+)"/, 1]

  def csrf_from_invitation(token)
    get "/portal/convite?token=#{URI.encode_www_form_component(token)}"
    csrf_in_page
  end
end
