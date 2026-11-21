# frozen_string_literal: true

require_relative "../unit_helper"
require "rbconfig"
require "stringio"
require "locentra/infrastructure/observability/logger"

# Redação do log estruturado: chaves sensíveis em qualquer nível, senhas de banco em textos livres
# (mensagens de erro), truncamento de textos longos e entrega imediata de cada linha.
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

  # Fora de um terminal o Ruby acumula a saída padrão em buffer: sem descarga a cada linha, o log do worker
  # só aparece quando o buffer enche ou o processo termina.
  def test_each_line_reaches_a_pipe_before_the_process_exits
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "locentra/infrastructure/observability/logger"
      Locentra::Infrastructure::Observability::StructuredLogger.new.info("event" => "worker.started")
      sleep 10
    RUBY
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, out: writer, err: File::NULL)
    writer.close
    ready = reader.wait_readable(5)

    refute_nil ready, "a linha do log deve chegar antes do fim do processo"
    assert_equal "worker.started", JSON.parse(reader.gets)["event"]
  ensure
    Process.kill("KILL", pid) if pid
    Process.wait(pid) if pid
    reader&.close
  end

  def test_the_io_is_flushed_after_each_line
    io = Class.new(StringIO) do
      attr_reader :flushes

      def flush
        @flushes = (@flushes || 0) + 1
        super
      end
    end.new
    logger = L.new(io: io)
    logger.info("event" => "a")
    logger.warn("event" => "b")

    assert_equal 2, io.flushes
    assert_equal 2, io.string.lines.size
  end

  def test_a_destination_with_only_puts_still_receives_each_line
    lines = []
    destination = Object.new
    destination.define_singleton_method(:puts) { |line| lines << line }
    L.new(io: destination).info("event" => "cli.command")

    assert_equal "cli.command", JSON.parse(lines.fetch(0))["event"]
  end
end
