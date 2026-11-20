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
end
