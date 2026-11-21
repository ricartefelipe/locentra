# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/commercial_terms_support"
require_relative "../support/portal_support"

# Base dos testes de telas das condições comerciais: organização com cliente e câmera (três ativos),
# proprietária conectada e troca de sessão para membros de outros papéis.
class CommercialTermsHttpTest < HttpTest
  include CommercialTermsSupport
  include PortalHelpers

  MEMBER_PASSWORD = "senha-muito-segura-7"

  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Produtora Horizonte")
    @camera = create_product(@actor, sku: "CAM-CT", name: "Câmera FX", tracking: "serialized", pricing: { "daily_cents" => 45_000 })
    register_assets(@actor, @camera, @branch, 3)
    @members = {}
    login("dona@alfa.test")
  end

  def get_ok(path)
    get path
  rescue Rack::Lint::LintError => e
    flunk "#{path}: #{e.message}"
  else
    assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
    last_response.body
  end

  # Encerra a sessão atual e conecta um membro com o papel informado (criado na primeira vez).
  def sign_in_as(role)
    email = "#{role.tr("_", "-")}@alfa.test"
    @members[role] ||= staff_member(@org, email, role)
    post_form "/sair", {}
    login(email, MEMBER_PASSWORD)
    @members[role]
  end

  def sign_in_as_owner
    post_form "/sair", {}
    login("dona@alfa.test")
  end

  def rental(day = 10) = period(format("2026-03-%02dT12:00:00Z", day), format("2026-03-%02dT12:00:00Z", day + 2))

  def reservation_form(**extra)
    { "cliente_id" => @customer.id, "filial_id" => @branch.id, "inicio" => "2026-03-10T09:00", "fim" => "2026-03-12T09:00",
      "produto" => [@camera.id], "quantidade" => ["1"], "modo" => "confirm" }.merge(extra.transform_keys(&:to_s))
  end

  def last_reservation_id = owner_query("SELECT id FROM reservations ORDER BY created_at DESC, code DESC LIMIT 1").first["id"]

  # Trecho do formulário (ou bloco <details>) que contém o texto informado.
  def block_with(body, pattern) = body[pattern] || flunk("trecho não encontrado: #{pattern.inspect}")
end
