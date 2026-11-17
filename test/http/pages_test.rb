# frozen_string_literal: true

require_relative "http_helper"

# Todas as telas da equipe renderizam com dados reais e respeitam permissões.
class PagesTest < HttpTest
  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @actor = @org[:actor]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-PG", tracking: "serialized")
    @chairs = create_product(@actor, sku: "CAD-PG", tracking: "bulk", pricing: { "hourly_cents" => 200 })
    @kit = create_product(@actor, sku: "KIT-PG", tracking: "kit")
    uc(:set_kit_components).call(@actor, @kit.id, [{ product_id: @camera.id, quantity: 1 }, { product_id: @chairs.id, quantity: 2 }])
    @asset = register_assets(@actor, @camera, @org[:branch], 1).first
    stock(@actor, @chairs, @org[:branch], 20)
    @reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-03T12:00:00Z", "2026-03-04T12:00:00Z"), [line(@kit, 1)])
    login("dona@alfa.test")
  end

  def test_every_staff_page_renders
    pages = ["/", "/clientes", "/clientes/novo", "/clientes/#{@customer.id}", "/produtos", "/produtos/novo", "/produtos/#{@camera.id}",
             "/produtos/#{@chairs.id}", "/produtos/#{@kit.id}", "/ativos", "/ativos/#{@asset.id}", "/disponibilidade",
             "/disponibilidade?dias=14", "/disponibilidade/consulta", "/reservas", "/reservas/nova", "/reservas/#{@reservation.id}",
             "/usuarios", "/organizacao", "/auditoria", "/organizacoes"]
    pages.each do |path|
      begin
        get path
      rescue Rack::Lint::LintError => e
        flunk "#{path}: #{e.message}"
      end

      assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 300]}"
      assert_includes last_response.headers["content-type"], "text/html"
    end
  end

  def test_calendar_shows_kit_capacity_from_components
    get "/disponibilidade", { "inicio" => "2026-03-03", "dias" => "7" }

    assert_includes last_response.body, "Produto KIT-PG"
    assert_match(/cell-full|cell-partial|cell-free/, last_response.body)
  end

  def test_attendant_cannot_see_admin_screens
    invite = uc(:invite_member).call(@actor, email: "atendente@alfa.test", role: "attendant")
    token = "#{@org[:organization_id]}.segredo-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    uc(:accept_invitation).call(token: token, name: "Atendente", password: "senha-muito-segura-3")
    post_form "/sair", {}
    login("atendente@alfa.test", "senha-muito-segura-3")
    get "/auditoria"

    assert_equal 403, last_response.status
    get "/"

    refute_includes last_response.body, "/auditoria"
    get "/reservas/nova"

    assert_equal 200, last_response.status
  end
end
