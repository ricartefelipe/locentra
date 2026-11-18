# frozen_string_literal: true

require_relative "../unit_helper"

# Redação da mensagem de erro de tarefas antes da exibição (CLI) e da auditoria do reprocessamento.
class JobsErrorTextTest < UnitTest
  def redact(text) = Locentra::Application::Jobs::ErrorText.redact(text)

  def test_authorization_header_values_are_removed_with_the_scheme
    assert_equal "401 Authorization: [omitido] depois", redact("401 Authorization: Bearer sk_live_ABCDEF123 depois")
    assert_equal "authorization=[omitido]", redact("authorization=Basic dXNlcjpzZW5oYQ==")
    assert_equal "Proxy-Authorization: [omitido]", redact("Proxy-Authorization: Digest abc123")
  end

  def test_compound_key_names_are_sensitive
    assert_equal "access_token=[omitido] client_secret=[omitido] x-api-key: [omitido] refresh-token=[omitido] webhook_secret_key=[omitido]",
                 redact("access_token=$aact_prod_XYZ client_secret=s3cr3t x-api-key: k-123 refresh-token=r1 webhook_secret_key=w2")
  end

  def test_quoted_values_are_removed_entirely
    assert_equal '{"access_token":"[omitido]","status":401}', redact('{"access_token":"a b c","status":401}')
    assert_equal "senha: '[omitido]' fim", redact("senha: 'com espaços' fim")
  end

  def test_provider_keys_tokens_and_url_credentials
    assert_equal "chave [credencial] recusada", redact("chave $aact_hmlg_000MzkwODA2MWY2OGM3MWRlMDU2NWM3MzJlNzZmNGZhZGY6OjE= recusada")
    assert_equal "[credencial]", redact("lcn_#{"a" * 32}_#{"B" * 43}")
    assert_equal "https://[credenciais]@h.test/x?[parâmetros omitidos]", redact("https://u:p@h.test/x?token=1&a=2")
  end

  def test_ordinary_text_is_kept
    ["status=503 tentativas=3", "Token inválido para o recurso", "passport=AB123", "tokens=5", "bypass=1", "Timeout::Error: execution expired"].each do |text|
      assert_equal text, redact(text)
    end
    assert_nil redact(nil)
  end
end
