# frozen_string_literal: true

require_relative "../unit_helper"
require "stringio"
require "locentra/infrastructure/observability/logger"

# Redação do log estruturado: chaves sensíveis em qualquer nível, senhas de banco em textos livres
# (mensagens de erro) e truncamento de textos longos.
class StructuredLoggerTest < UnitTest
  L = Locentra::Infrastructure::Observability::StructuredLogger

  def test_sensitive_keys_are_redacted_at_any_depth
    data = { "senha" => "x", "user" => { "password" => "y", "api_key" => "z", "nome" => "Ana" },
             "headers" => [{ "authorization" => "Bearer abc", "cookie" => "c=1" }], "pan" => "4111", "card_number" => "4111",
             "cvv" => "123", "access_token" => "t", "csrf_token" => "k", "company" => "Locadora", "expand" => "sim" }
    redacted = L.redact(data)

    assert_equal "[REDACTED]", redacted["senha"]
    assert_equal({ "password" => "[REDACTED]", "api_key" => "[REDACTED]", "nome" => "Ana" }, redacted["user"])
    assert_equal [{ "authorization" => "[REDACTED]", "cookie" => "[REDACTED]" }], redacted["headers"]
    %w[pan card_number cvv access_token csrf_token].each { |key| assert_equal "[REDACTED]", redacted[key], key }
    assert_equal %w[Locadora sim], redacted.values_at("company", "expand"), "nomes comuns não são confundidos com PAN"
  end

  def test_database_passwords_in_messages_are_masked
    message = %(missing "]" in URI: "postgres://locentra_app:SenhaWeb77@[::1/x" e host=db password=OutraSenha1 user=app)
    clean = L.redact({ "message" => message })["message"]

    refute_includes clean, "SenhaWeb77"
    refute_includes clean, "OutraSenha1"
    assert_includes clean, "postgres://locentra_app:[REDACTED]@"
    assert_includes clean, "password=[REDACTED]"
    assert_equal "sem segredo", L.redact("sem segredo")
  end

  def test_long_texts_are_truncated_and_lines_are_json
    io = StringIO.new
    L.new(io: io, level: "info").info(event: "teste", texto: "a" * 5000, password: "segredo")
    line = JSON.parse(io.string)

    assert_equal 4001, line["texto"].length
    assert_equal "[REDACTED]", line["password"]
  end
end
