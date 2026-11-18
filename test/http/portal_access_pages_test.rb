# frozen_string_literal: true

require_relative "portal_http_helper"

# Acesso ao portal pela interface (Rack::Lint): concessão pela tela do cliente e aceite pelo e-mail,
# cancelamento de convites, vínculo de conta existente, entrada no portal, separação entre sessões de
# portal e de equipe, CSRF e revogação imediata.
class PortalAccessPagesTest < PortalHttpTest
  def test_staff_grants_access_by_email_and_contact_activates_it_through_the_pages
    contact = portal_contact(@actor, @customer, email: "paula@cliente.test", name: "Paula Compras")
    login("dona@alfa.test")
    body = get_ok("/clientes/#{@customer.id}")

    assert_includes body, "Acesso ao portal do cliente"
    assert_includes body, "Nenhum acesso concedido."
    assert_includes body, %(<option value="#{contact.id}">Paula Compras (paula@cliente.test)</option>)
    post_form "/clientes/#{@customer.id}/portal/convites", { "contato_id" => contact.id }

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Convite de acesso ao portal enviado para paula@cliente.test"
    assert_includes last_response.body, "Aguardando aceite"
    drain
    accept_through_the_pages(portal_token_for("paula@cliente.test"))
  end

  def test_staff_cancels_invitations_and_sees_refusals_on_the_customer_page
    contact = portal_contact(@actor, @customer, email: "cancelar@cliente.test")
    invitation = uc(:invite_portal_contact).call(@actor, customer_id: @customer.id, contact_id: contact.id)
    login("dona@alfa.test")
    post_form "/clientes/#{@customer.id}/portal/convites/#{invitation.id}/cancelar", {}
    follow_redirect!

    assert_includes last_response.body, "Convite cancelado."
    assert_includes last_response.body, "Cancelado"
    post_form "/clientes/#{@customer.id}/portal/convites/#{invitation.id}/cancelar", {}
    follow_redirect!

    assert_includes last_response.body, "Transição inválida"
    no_email = uc(:add_contact).call(@actor, @customer.id, { name: "Sem E-mail" })
    post_form "/clientes/#{@customer.id}/portal/convites", { "contato_id" => no_email.id }
    follow_redirect!

    assert_includes last_response.body, "Convite não enviado"
    post_form "/clientes/#{@other.id}/portal/convites", { "contato_id" => contact.id }

    assert_equal 404, last_response.status, "contato de outro cliente"
    small = create_organization(name: "Locadora Pequena", email: "dona@pequena.test", plan: "essencial")
    small_customer = create_customer(small[:actor], name: "Cliente Pequeno")
    post "/sair", { "_csrf" => csrf }
    login("dona@pequena.test")
    page = get_ok("/clientes/#{small_customer.id}")

    assert_includes page, "não inclui o portal do cliente"
    refute_includes page, "Enviar convite"
  end

  def test_logged_in_account_links_the_invitation_with_csrf
    beta = create_organization(name: "Locadora Beta", email: "compras@beta.test")
    token = invite_and_deliver(@actor, @customer, portal_contact(@actor, @customer, email: "compras@beta.test"))
    get "/portal/convite?token=#{URI.encode_www_form_component(token)}"

    assert_includes last_response.body, "Entre primeiro"
    post "/entrar", { "email" => "compras@beta.test", "senha" => "senha-muito-segura-1", "voltar" => "/portal/convite?token=#{token}" }

    assert_equal "/portal/convite?token=#{token}", last_response.location, "o retorno ao convite é preservado na entrada"
    follow_redirect!

    assert_includes last_response.body, "Você está conectado como"
    post "/portal/convite", { "token" => token }

    assert_equal 403, last_response.status, "com sessão, o aceite exige o token CSRF"
    post "/portal/convite", { "token" => token, "_csrf" => csrf_from_invitation(token) }

    assert_equal 303, last_response.status
    follow_redirect!

    assert_equal "/portal", last_request.path
    post "/sair", { "_csrf" => portal_csrf }
    login("compras@beta.test")

    assert_equal "/organizacoes", last_request.path
    assert_includes last_response.body, "Portal do cliente"
    assert_includes last_response.body, %(name="tipo" value="portal")
    post "/organizacoes/ativar", { "organizacao_id" => @org[:organization_id], "tipo" => "portal", "_csrf" => csrf_in_page }
    follow_redirect!

    assert_equal "/portal", last_request.path
    post "/organizacoes/ativar", { "organizacao_id" => beta[:organization_id], "tipo" => "staff", "_csrf" => portal_csrf }
    follow_redirect!

    assert_equal "/", last_request.path
  end

  def test_portal_login_honours_portal_return_paths_only
    portal_customer(@actor, @customer, email: "paula@cliente.test")
    post "/entrar", { "email" => "paula@cliente.test", "senha" => PORTAL_PASSWORD, "voltar" => "/portal/reservas" }

    assert_equal "/portal/reservas", last_response.location
    get "/entrar"

    assert_equal "/portal", last_response.location, "sessão de portal ativa volta ao portal"
    clear_cookies
    post "/entrar", { "email" => "paula@cliente.test", "senha" => PORTAL_PASSWORD, "voltar" => "/clientes" }

    assert_equal "/portal", last_response.location, "retorno para área da equipe é ignorado"
  end

  def test_portal_and_staff_sessions_do_not_cross_and_csrf_is_required
    portal_customer(@actor, @customer, email: "paula@cliente.test")
    portal_login
    token = portal_csrf
    %w[/ /clientes /reservas /financeiro /contratos /usuarios].each do |path|
      get path

      assert_equal 303, last_response.status, path
      assert_equal "/portal", last_response.location, path
    end
    post "/clientes", { "_csrf" => token, "tipo" => "individual", "nome" => "Intruso", "documento" => "52998224725" }

    assert_equal 403, last_response.status
    get "/api/v1/customers", {}, { "HTTP_ACCEPT" => "application/json" }

    assert_equal 403, last_response.status
    assert_equal "wrong_area", json_body.dig("error", "code")
    post "/portal/reservas", { "filial" => @branch.id, "inicio" => "2026-03-10T05:00", "fim" => "2026-03-11T05:00",
                               "produto" => [@camera.id], "quantidade" => ["1"] }

    assert_equal 403, last_response.status, "sem token CSRF"
    assert_equal 0, owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i
    post "/sair", { "_csrf" => token }
    login("dona@alfa.test")
    get "/portal"

    assert_equal 303, last_response.status
    assert_equal "/", last_response.location
    post "/portal/reservas", { "_csrf" => csrf, "filial" => @branch.id, "inicio" => "2026-03-10T05:00", "fim" => "2026-03-11T05:00",
                               "produto" => [@camera.id], "quantidade" => ["1"] }

    assert_equal 403, last_response.status
    clear_cookies
    get "/portal/reservas"

    assert_equal 303, last_response.status
    assert_equal "/entrar?voltar=%2Fportal%2Freservas", last_response.location
  end

  def test_revocation_is_immediate_for_open_portal_sessions
    portal_customer(@actor, @customer, email: "paula@cliente.test")
    portal_login
    get_ok("/portal/reservas")
    access_id = owner_query("SELECT id FROM portal_accesses").first["id"]
    owner_query("UPDATE portal_accesses SET status = 'revoked', revoked_at = now() WHERE id = $1", [access_id])
    get "/portal/reservas"

    assert_equal 403, last_response.status, "a autenticação revalida o acesso a cada requisição"
    assert_includes last_response.body, "acesso ao portal revogado"
    owner_query("UPDATE portal_accesses SET status = 'active', revoked_at = NULL WHERE id = $1", [access_id])
    get_ok("/portal")
    with_session(:equipe) do
      login("dona@alfa.test")
      body = get_ok("/clientes/#{@customer.id}")

      assert_includes body, "Revogar acesso"
      post_form "/clientes/#{@customer.id}/portal/acessos/#{access_id}/revogar", {}
      follow_redirect!

      assert_includes last_response.body, "Acesso ao portal revogado"
    end
    get "/portal"

    assert_equal 303, last_response.status, "a sessão do portal foi encerrada"
    assert_match %r{\A/entrar}, last_response.location
    post "/entrar", { "email" => "paula@cliente.test", "senha" => PORTAL_PASSWORD }

    assert_equal "/organizacoes", last_response.location, "sem acesso ativo, a conta não entra no portal"
    follow_redirect!

    assert_includes last_response.body, "não possui acesso ativo"
  end

  private

  # Aceite pela página pública do convite, sem sessão, e primeira visita ao portal.
  def accept_through_the_pages(token)
    post "/sair", { "_csrf" => csrf }
    clear_cookies
    invitation = get_ok("/portal/convite?token=#{URI.encode_www_form_component(token)}")

    assert_includes invitation, "Ativar acesso ao portal do cliente"
    assert_includes invitation, %(name="senha")
    post "/portal/convite", { "token" => token, "nome" => "Paula Compras", "senha" => "curta" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "ao menos 12 caracteres"
    post "/portal/convite", { "token" => token, "nome" => "Paula Compras", "senha" => PORTAL_PASSWORD }

    assert_equal 303, last_response.status
    assert_equal "/portal", last_response.location
    home = get_ok("/portal")

    assert_includes home, "Cliente &lt;b&gt;Portal&lt;/b&gt;"
    refute_includes home, "<b>Portal</b>"
    assert_includes home, %(aria-label="Navegação do portal")
    assert_includes home, %(href="/portal/financeiro")
    refute_includes home, %(href="/clientes"), "o portal não mostra a navegação da equipe"
    post "/portal/convite", { "token" => token, "_csrf" => portal_csrf }

    assert_equal 422, last_response.status, "convite aceito não é reutilizado"
    assert_includes last_response.body, "convite inválido ou expirado"
  end
end
