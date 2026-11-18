# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "stringio"
require "locentra/interfaces/cli/operational"

# Redação da saída da CLI (sem banco): segredos removidos do texto humano, do JSON e do log, sem
# alterar a estrutura do JSON. No JSON a redação é aplicada a cada valor antes da serialização.
class CliRedactionTest < Minitest::Test
  include PropertyTesting

  CLI = Locentra::Interfaces::CLI
  TOKEN = "lcn_#{"0" * 32}_#{"A" * 43}".freeze
  PROTECTED = "segredo-protegido"

  def setup
    @io = StringIO.new
    @output = CLI::SafeOutput.new(@io)
    @output.protect(PROTECTED)
  end

  def test_text_masks_tokens_database_urls_conninfo_passwords_and_protected_secrets
    @output.puts("falha #{TOKEN} em postgres://app:senha-do-banco@db:5432/locentra host=db password='com espaço' e #{PROTECTED}")

    assert_equal "falha lcn_[omitido] em postgres://app:[omitido]@db:5432/locentra host=db password=[omitido] e [omitido]\n", @io.string
  end

  def test_short_protected_values_are_not_masked_literally
    @output.protect("abc")
    @output.puts("abc continua visível")

    assert_equal "abc continua visível\n", @io.string
  end

  def test_json_values_are_redacted_before_serialization
    data = { "notes" => "portao: password=1234", "error" => "IOError: password=x", "n" => 1, "flag" => true, "empty" => nil,
             "nested" => [{ "url" => "postgres://u:senha-do-banco@h/db", "quoted" => "a \"password=b\\\"c\" d" }],
             "chave #{PROTECTED}" => "valor com #{PROTECTED} e #{TOKEN}" }
    @output.json(data)
    parsed = JSON.parse(@io.string)

    assert_equal({ "notes" => "portao: password=[omitido]", "error" => "IOError: password=[omitido]", "n" => 1, "flag" => true, "empty" => nil,
                   "nested" => [{ "url" => "postgres://u:[omitido]@h/db", "quoted" => "a \"password=[omitido] d" }],
                   "chave [omitido]" => "valor com [omitido] e lcn_[omitido]" }, parsed)
    assert @io.string.start_with?("{\n  \"notes\""), "JSON indentado por padrão"
  end

  def test_compact_json_for_error_lines
    @output.json({ "error" => { "message" => "x://u:p", "details" => "@" } }, pretty: false)

    assert_equal({ "error" => { "message" => "x://u:p", "details" => "@" } }, JSON.parse(@io.string), "a redação não atravessa valores")
    assert_equal 1, @io.string.lines.size
  end

  # Qualquer combinação de fragmentos sensíveis e de caracteres de sintaxe do JSON resulta em
  # documento válido e sem os segredos, tanto no JSON indentado quanto no compacto e no log.
  def test_json_output_is_always_parseable_and_free_of_secrets
    fragments = ["password=", "password='", "'", "\"", "\\", ",", " ", ":", "{", "}", "@", "/", "\n", "x", "postgres://u:", "@h/db",
                 TOKEN, PROTECTED, "lcn_", "host=db "]
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: @output.log_io, level: "info")
    property("JSON redigido continua válido") do |random|
      text = -> { Array.new(random.rand(1..8)) { fragments.sample(random: random) }.join }
      data = { text.call => text.call, "lista" => Array.new(random.rand(0..3)) { { text.call => text.call } } }
      @io.truncate(0)
      @io.rewind
      @output.json(data, pretty: random.rand < 0.5)
      logger.info(event: "cli.teste", detalhe: text.call)
      first, *rest = @io.string.split(/\n(?=\{"ts")/)

      [first, *rest].each do |chunk|
        JSON.parse(chunk)
      rescue JSON::ParserError => e
        flunk("JSON inválido (#{e.message}): #{chunk.inspect}")
      end

      refute_includes @io.string, TOKEN
      refute_includes @io.string, PROTECTED
    end
  end

  def test_log_lines_are_redacted_value_by_value
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: @output.log_io, level: "info", base: { "service" => "locentra-cli" })
    logger.error(event: "cli.error", message: "conexão postgres://app:senha-do-banco@db/locentra password=abc")
    entry = JSON.parse(@io.string)

    assert_equal ["locentra-cli", "cli.error", "conexão postgres://app:[omitido]@db/locentra password=[omitido]"],
                 entry.values_at("service", "event", "message")
  end

  def test_log_lines_that_are_not_json_are_redacted_as_text
    @output.log_io.puts("linha livre com #{PROTECTED}")

    assert_equal "linha livre com [omitido]\n", @io.string
  end
end
