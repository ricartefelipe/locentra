# frozen_string_literal: true

require_relative "http_helper"

class WebFlowTest < HttpTest
  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
  end

  def test_login_dashboard_and_logout_with_secure_session_cookie
    login("dona@alfa.test")

    assert_includes last_response.body, "Painel"
    cookie = rack_mock_session.cookie_jar.instance_variable_get(:@cookies).find { |c| c.name == "locentra_session" }

    assert cookie, "cookie de sessão emitido"
    assert_predicate cookie, :http_only?
    post_form "/sair", {}

    assert_equal 303, last_response.status
    get "/"

    assert_equal 303, last_response.status
    assert_match %r{/entrar}, last_response.location
  end

  def test_invalid_credentials_render_generic_error_and_rate_limit
    post "/entrar", { "email" => "dona@alfa.test", "senha" => "errada-errada" }

    assert_equal 401, last_response.status
    assert_includes last_response.body, "E-mail ou senha inválidos"
    10.times { post "/entrar", { "email" => "dona@alfa.test", "senha" => "errada-errada" } }

    assert_equal 429, last_response.status
  end

  def test_csrf_is_required_for_state_changes
    login("dona@alfa.test")
    post "/clientes", { "tipo" => "individual", "nome" => "Sem token", "documento" => "52998224725" }

    assert_equal 403, last_response.status
    post "/clientes", { "tipo" => "individual", "nome" => "Token falso", "documento" => "52998224725", "_csrf" => "x" * 43 }

    assert_equal 403, last_response.status
    assert_equal 0, owner_query("SELECT count(*) AS n FROM customers").first["n"].to_i
  end

  def test_user_content_is_escaped_in_html
    login("dona@alfa.test")
    post_form "/clientes", { "tipo" => "individual", "nome" => "<script>alert('x')</script>", "documento" => "52998224725" }
    follow_redirect!

    refute_includes last_response.body, "<script>alert('x')</script>"
    assert_includes last_response.body, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
  end

  def test_partials_are_rendered_as_html_not_escaped_text
    login("dona@alfa.test")
    get "/"

    assert_includes last_response.body, '<p class="empty">'
    refute_includes last_response.body, "&lt;p class=&quot;empty&quot;&gt;"
  end

  def test_security_headers_and_csp_without_inline_scripts
    get "/entrar"

    assert_equal 200, last_response.status
    csp = last_response.headers["content-security-policy"]

    assert_includes csp, "script-src 'self'"
    refute_includes csp, "unsafe-inline"
    assert_equal "nosniff", last_response.headers["x-content-type-options"]
    assert_equal "DENY", last_response.headers["x-frame-options"]
    refute_match(%r{<script(?![^>]*\bsrc=)(?![^>]*application/json)[^>]*>}, last_response.body)
    assert last_response.headers["x-request-id"]
  end

  def test_login_redirect_rejects_open_redirects
    post "/entrar", { "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1", "voltar" => "//evil.example/roubo" }

    assert_equal "/", last_response.location
    post "/entrar", { "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1", "voltar" => "/reservas" }

    assert_equal "/reservas", last_response.location
  end

  def test_full_slice_customer_asset_availability_reservation_confirmation
    login("dona@alfa.test")
    post_form "/clientes", { "tipo" => "company", "nome" => "Produtora Eventos", "documento" => "11.222.333/0001-81" }
    customer_id = last_response.location[%r{/clientes/(.+)}, 1]
    post_form "/produtos", { "sku" => "CAM-4K", "nome" => "Câmera 4K", "rastreamento" => "serialized", "preco_diaria" => "350,00",
                             "modalidade_diaria" => "rolling_24h", "caucao" => "1000" }
    product_id = last_response.location[%r{/produtos/(.+)}, 1]
    get "/produtos/#{product_id}"
    post_form "/produtos/#{product_id}/ativos", { "patrimonio" => "CAM-0001", "filial_id" => @org[:branch].id, "condicao" => "good" }

    assert_equal 303, last_response.status
    get "/disponibilidade/consulta", { "filial" => @org[:branch].id, "inicio" => "2026-03-10T09:00", "fim" => "2026-03-11T09:00" }

    assert_includes last_response.body, "Câmera 4K"
    get "/reservas/nova"
    post_form "/reservas", { "cliente_id" => customer_id, "filial_id" => @org[:branch].id, "inicio" => "2026-03-10T09:00",
                             "fim" => "2026-03-11T09:00", "produto" => [product_id], "quantidade" => ["1"], "modo" => "hold" }

    assert_equal 303, last_response.status
    reservation_path = last_response.location
    follow_redirect!

    assert_includes last_response.body, "Bloqueio temporário"
    assert_includes last_response.body, "R$ 350,00"
    post_form "#{reservation_path}/confirmar", {}
    follow_redirect!

    assert_includes last_response.body, "Confirmada"
    get "/reservas/nova"
    post_form "/reservas", { "cliente_id" => customer_id, "filial_id" => @org[:branch].id, "inicio" => "2026-03-10T12:00",
                             "fim" => "2026-03-10T18:00", "produto" => [product_id], "quantidade" => ["1"], "modo" => "confirm" }

    assert_equal 409, last_response.status
    assert_includes last_response.body, "Itens sem disponibilidade suficiente"
  end

  def test_other_tenant_resources_are_not_found
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")
    foreign = create_customer(other[:actor], name: "Cliente Beta")
    login("dona@alfa.test")
    get "/clientes/#{foreign.id}"

    assert_equal 404, last_response.status
    refute_includes last_response.body, "Cliente Beta"
  end

  def test_permission_denied_for_restricted_screens
    login("dona@alfa.test")
    get "/auditoria"

    assert_equal 200, last_response.status
    get "/rota-inexistente"

    assert_equal 404, last_response.status
    delete "/clientes"

    assert_equal 405, last_response.status
  end

  def test_attachments_upload_download_and_tenant_isolation
    login("dona@alfa.test")
    customer = create_customer(@org[:actor])
    get "/clientes/#{customer.id}"
    pdf = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4\n%teste\n"), "application/pdf", original_filename: "../../contrato.pdf")
    post "/anexos", { "_csrf" => csrf, "dono_tipo" => "customer", "dono_id" => customer.id, "arquivo" => pdf }

    assert_equal 303, last_response.status
    attachment = owner_query("SELECT id, filename, storage_key FROM attachments").first

    assert_equal "contrato.pdf", attachment["filename"]
    refute_includes attachment["storage_key"], "contrato"
    get "/anexos/#{attachment["id"]}"

    assert_equal 200, last_response.status
    assert_equal "application/pdf", last_response.headers["content-type"]
    assert_includes last_response.headers["content-security-policy"], "sandbox"
    assert last_response.body.start_with?("%PDF-")
    get "/clientes/#{customer.id}"
    html = Rack::Test::UploadedFile.new(StringIO.new("<script>alert(1)</script>"), "application/pdf", original_filename: "falso.pdf")
    post "/anexos", { "_csrf" => csrf, "dono_tipo" => "customer", "dono_id" => customer.id, "arquivo" => html }

    assert_equal 1, owner_query("SELECT count(*) AS n FROM attachments").first["n"].to_i, "conteúdo não PDF recusado"
    post_form "/sair", {}
    get "/anexos/#{attachment["id"]}"

    assert_equal 303, last_response.status, "download exige autenticação"
    other = create_organization(name: "Locadora Ômega", email: "omega@example.test")
    login("omega@example.test")
    get "/anexos/#{attachment["id"]}"

    assert_equal 404, last_response.status
    assert other
    get "/storage/#{attachment["storage_key"]}"

    assert_equal 404, last_response.status, "diretório de anexos não é servido estaticamente"
  end

  def test_health_endpoints
    get "/health/live"

    assert_equal 200, last_response.status
    get "/health/ready"

    assert_equal 200, last_response.status
    assert_equal({ "database" => true, "migrations" => true }, json_body["checks"])
  end

  def test_payload_limit_and_nested_params
    login("dona@alfa.test")
    token = csrf
    post "/clientes", "nome" => "x" * 10, "_csrf" => token, "a" => { "b" => { "c" => { "d" => { "e" => "f" } } } }

    assert_equal 400, last_response.status
  end

  def test_staff_invitation_return_path_survives_login_with_several_organizations
    second = staff_member_of(create_organization(name: "Locadora Beta", email: "dona@beta.test"), "dona@alfa.test")
    back = "/convites?token=#{@org[:organization_id]}.qualquer"
    post "/entrar", { "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1", "voltar" => back }

    refute_nil second
    assert_equal back, last_response.location
  end

  def staff_member_of(org, email)
    invitation = uc(:invite_member).call(org[:actor], email: email, role: "auditor")
    token = "#{org[:organization_id]}.segredo-#{invitation["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]], tenant: org[:organization_id])
    user = owner_query("SELECT id FROM users WHERE email = $1", [email], tenant: nil).first["id"]
    uc(:accept_invitation).call(token: token, user_id: user)
  end
end
