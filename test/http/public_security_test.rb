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
end
