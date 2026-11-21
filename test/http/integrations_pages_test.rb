# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/worker_support"
require_relative "../support/webhook_support"
require_relative "../support/portal_support"

# Tela de integrações com o circuito por endpoint: endpoint pausado com a explicação e o botão de
# reativação (com CSRF), entregas retidas sem reenvio, reativação por administrador com o aviso da
# contagem, alerta para endpoint não pausado e recusa para o auditor e para envio sem CSRF.
class IntegrationsPagesTest < HttpTest
  include WorkerHelpers
  include WebhookHelpers
  include PortalHelpers

  MEMBER_PASSWORD = "senha-muito-segura-7"

  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    worker_system
    drain
    @endpoint = uc(:create_webhook).call(@org[:actor], url: "http://127.0.0.1:9/hook", events: ["*"])["id"]
    login("dona@alfa.test")
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def sign_in_as(role)
    staff_member(@org, "#{role}@alfa.test", role)
    post_form "/sair", {}
    login("#{role}@alfa.test", MEMBER_PASSWORD)
  end

  def page(path = "/integracoes")
    get path

    assert_equal 200, last_response.status
    last_response.body
  end

  def test_paused_endpoint_shows_the_reason_and_a_resume_form_and_held_deliveries_have_no_redelivery
    pause_endpoint!(@org, @endpoint, failures: 23, since: t("2026-03-02T09:30:00Z"))
    dispatch_events(@org)
    body = page

    assert_includes body, "Pausado"
    assert_includes body, "Pausa automática após 23 falhas consecutivas desde 02/03/2026 06:30; 1 entrega(s) retida(s)."
    assert_match(%r{<form method="post" action="/integracoes/#{@endpoint}/reativar" class="inline"><input type="hidden" name="_csrf" value="[^"]+">},
                 body)
    assert_includes body, "/integracoes/#{@endpoint}/desativar", "pausado continua podendo ser desativado"
    assert_includes body, "Retida (endpoint pausado)"
    refute_includes body, "/reenviar"
    assert_includes body, "pausados automaticamente e reativados aqui"
  end

  def test_active_endpoint_has_no_resume_button
    body = page

    assert_includes body, "Ativo"
    refute_includes body, "/reativar"
  end

  def test_resume_without_csrf_is_refused
    pause_endpoint!(@org, @endpoint)
    post "/integracoes/#{@endpoint}/reativar", {}

    assert_equal 403, last_response.status
    refute_nil endpoint_row(@org, @endpoint)["paused_at"]
  end

  def test_admin_resumes_and_sees_the_held_count
    pause_endpoint!(@org, @endpoint)
    dispatch_events(@org, 2)
    sign_in_as("admin")
    post_form "/integracoes/#{@endpoint}/reativar", {}

    assert_equal 303, last_response.status
    assert_equal "/integracoes", URI(last_response.location).path
    follow_redirect!

    assert_includes last_response.body, "Endpoint reativado. Entregas retidas a reenviar em segundo plano: 2."
    assert_nil endpoint_row(@org, @endpoint)["paused_at"]
    assert_equal 1, webhook_jobs("webhooks.release_held").size
  end

  def test_resuming_an_endpoint_that_is_not_paused_redirects_with_an_alert
    post_form "/integracoes/#{@endpoint}/reativar", {}

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "endpoint não está pausado"
  end

  def test_auditor_cannot_open_or_resume
    pause_endpoint!(@org, @endpoint)
    sign_in_as("auditor")
    get "/integracoes"

    assert_equal 403, last_response.status
    post_form "/integracoes/#{@endpoint}/reativar", {}

    assert_equal 403, last_response.status
    refute_nil endpoint_row(@org, @endpoint)["paused_at"]
  end
end
