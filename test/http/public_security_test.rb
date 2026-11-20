# frozen_string_literal: true

require_relative "http_helper"

# Formulários públicos e limites de taxa: origem do envio (CSRF de login), redirecionamento após a
# entrada, limites por IP e por credencial, IP do cliente atrás de proxy e mensagens de erro.
class PublicSecurityTest < HttpTest
  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
  end

  def credentials = { "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1" }

  def test_login_return_path_with_control_characters_is_ignored
    ["/\t/evil.example/roubo", "/\v/evil.example", "/\f/evil.example", "/\x1F/evil.example", "/ /evil.example", "/\\evil.example"].each do |back|
      post "/entrar", credentials.merge("voltar" => back)

      assert_equal "/", last_response.location, back.inspect
    end
    get "/entrar", { "voltar" => "/\t/evil.example" }

    refute_includes last_response.body, "evil.example"
  end

  def test_signup_is_limited_per_ip_and_per_email
    10.times { |i| post "/cadastro", { "nome" => "Pessoa", "email" => "p#{i}@x.test", "senha" => "curta", "organizacao" => "Empresa" } }

    assert_equal 422, last_response.status
    post "/cadastro", { "nome" => "Pessoa", "email" => "p11@x.test", "senha" => "curta", "organizacao" => "Empresa" }

    assert_equal 429, last_response.status
    assert_operator last_response.headers["retry-after"].to_i, :>, 0
    5.times { |i| post "/cadastro", { "nome" => "P", "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1" }, { "REMOTE_ADDR" => "10.9.0.#{i}" } }
    post "/cadastro", { "nome" => "P", "email" => "dona@alfa.test", "senha" => "senha-muito-segura-1", "organizacao" => "Outra" },
         { "REMOTE_ADDR" => "10.9.0.99" }

    assert_equal 429, last_response.status, "limite por e-mail, de qualquer IP"
  end

  def test_password_reset_and_invitations_are_limited_per_ip
    { "/redefinir-senha" => 20, "/convites" => 20, "/portal/convite" => 20 }.each do |path, limit|
      limit.times { post path, { "token" => "invalido", "senha" => "senha-muito-segura-1", "nome" => "X" }, { "REMOTE_ADDR" => "10.8.0.1" } }

      assert_equal 422, last_response.status, path
      post path, { "token" => "invalido" }, { "REMOTE_ADDR" => "10.8.0.1" }

      assert_equal 429, last_response.status, path
      post path, { "token" => "invalido" }, { "REMOTE_ADDR" => "10.8.0.2" }

      assert_equal 422, last_response.status, "#{path}: outro IP"
    end
  end

  def test_api_is_limited_per_credential
    limited = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env("API_RATE_LIMIT" => "2")), clock: @clock, logger: @system.logger)
    api = Rack::MockRequest.new(Locentra::Interfaces::HTTP::App.build(limited))
    token = uc(:create_credential).call(@org[:actor], name: "ERP", scopes: %w[customers.read], expires_in_days: 1)["token"]
    other = uc(:create_credential).call(@org[:actor], name: "BI", scopes: %w[customers.read], expires_in_days: 1)["token"]
    statuses = Array.new(3) { api.get("/api/v1/customers", "HTTP_AUTHORIZATION" => "Bearer #{token}").status }

    assert_equal [200, 200, 429], statuses
    assert_equal 200, api.get("/api/v1/customers", "HTTP_AUTHORIZATION" => "Bearer #{other}").status
  ensure
    limited&.shutdown
  end

  # Sem proxies confiáveis, cabeçalhos de encaminhamento não mudam o IP: o limite de entrada por IP
  # continua valendo e a sessão grava o par da conexão.
  def test_forwarded_headers_are_ignored_without_trusted_proxies
    statuses = Array.new(31) do |i|
      post "/entrar", { "email" => "u#{i}@x.test", "senha" => "errada-errada" },
           { "HTTP_FORWARDED" => "for=203.0.113.#{i}", "HTTP_X_FORWARDED_FOR" => "198.51.100.#{i}" }
      last_response.status
    end

    assert_equal 429, statuses.last
    @system.services[:rate_limiter].purge(@clock.now + 3600)
    post "/entrar", credentials, { "HTTP_FORWARDED" => "for=198.51.100.77", "HTTP_X_FORWARDED_FOR" => "198.51.100.78" }

    assert_equal(["127.0.0.1"], owner_query("SELECT ip FROM sessions", [], tenant: nil).map { |r| r["ip"] })
  end

  def test_client_address_from_trusted_proxies_only
    address = Locentra::Interfaces::HTTP::ClientAddress.new(nil, trusted: Locentra::Config.trusted_proxies("10.0.0.0/8, ::1"))
    resolve = ->(remote, forwarded = nil) { address.resolve("REMOTE_ADDR" => remote, "HTTP_X_FORWARDED_FOR" => forwarded) }

    assert_equal "203.0.113.9", resolve.call("10.0.0.2", "198.51.100.1, 203.0.113.9, 10.0.0.3")
    assert_equal "198.51.100.5", resolve.call("198.51.100.5", "203.0.113.9"), "par não confiável"
    assert_equal "10.0.0.2", resolve.call("10.0.0.2"), "sem cabeçalho"
    assert_equal "10.0.0.2", resolve.call("10.0.0.2", "lixo"), "cabeçalho inválido"
    assert_equal "203.0.113.9", resolve.call("::1", "203.0.113.9")
    assert_raises(Locentra::ConfigError) { Locentra::Config.trusted_proxies("10.0.0.0/8, não-é-ip") }
  end

  def test_csrf_failure_page_explains_what_to_do
    login("dona@alfa.test")
    post "/clientes", { "tipo" => "individual", "nome" => "Formulário antigo", "documento" => "52998224725", "_csrf" => "x" * 43 }

    assert_equal 403, last_response.status
    assert_includes last_response.body, "O formulário expirou ou a sessão mudou. Recarregue a página e tente novamente."
    refute_includes last_response.body, "Locentra::"
  end

  def test_unauthenticated_api_message_is_readable
    get "/api/v1/customers"

    assert_equal 401, last_response.status
    assert_equal "Autenticação necessária", json_body["error"]["message"]
  end
end
