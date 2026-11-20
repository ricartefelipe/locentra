# frozen_string_literal: true

require_relative "../unit_helper"
require "locentra/infrastructure/crypto"
require "locentra/infrastructure/storage"
require "locentra/infrastructure/integrations/safe_http"
require "socket"
require "tmpdir"

# Adaptadores de segurança testados sem rede, banco ou servidor.
class SecurityAdaptersTest < UnitTest
  I = Locentra::Infrastructure

  class FakeResolver
    def initialize(map) = @map = map
    def getaddresses(host) = @map.fetch(host, [])
  end

  def http(map = {}) = I::Integrations::SafeHttp.new(resolver: FakeResolver.new(map))

  def test_ssrf_guard_blocks_internal_and_metadata_destinations
    blocked = {
      "http://example.com/x" => "use https",
      "https://user:pass@example.com/" => "credenciais",
      "https://127.0.0.1/" => "interna", "https://10.1.2.3/" => "interna", "https://192.168.0.10/" => "interna",
      "https://169.254.169.254/latest/meta-data" => "interna", "https://[::1]/" => "interna", "https://[fd00::1]/" => "interna",
      "https://[::ffff:127.0.0.1]/" => "interna", "https://100.64.0.1/" => "interna", "https://example.com:5432/" => "porta",
      "https://interno.example/" => "interna", "https://sem-dns.example/" => "sem endereço", "notaurl" => "use https"
    }
    resolver = { "interno.example" => ["10.0.0.5", "93.184.216.34"] }
    blocked.each do |url, message|
      error = assert_raises(I::Integrations::UnsafeDestination, url) { http(resolver).resolve!(url) }

      assert_match(/#{message}/, error.message, url)
    end
  end

  def test_ssrf_guard_pins_resolved_public_address
    uri, ip = http("hooks.example" => ["93.184.216.34"]).resolve!("https://hooks.example/a?b=1")

    assert_equal "hooks.example", uri.host
    assert_equal "93.184.216.34", ip
    assert I::Integrations::SafeHttp.new(allow_http: true, resolver: FakeResolver.new({})).resolve!("http://8.8.8.8/")
    refute I::Integrations::SafeHttp.new(allow_private: true).blocked?("127.0.0.1")
  end

  # Destino local que responde com o corpo informado, em partes, com pausa entre elas. Devolve o
  # cliente configurado, a porta e o total de bytes que o servidor conseguiu escrever.
  def with_responder(content_length:, chunk:, pause:, chunks:)
    server = TCPServer.new("127.0.0.1", 0)
    written = Queue.new
    thread = Thread.new do
      socket = server.accept
      socket.gets
      while (line = socket.gets) && line != "\r\n"; end
      total = 0
      begin
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{content_length}\r\nConnection: close\r\n\r\n")
        chunks.times do
          total += socket.write(chunk)
          sleep(pause) if pause.positive?
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        nil
      ensure
        written << total
        socket.close
      end
    end
    yield server.addr[1], written
  ensure
    thread&.join(5)
    server&.close
  end

  def local_http(**) = I::Integrations::SafeHttp.new(allow_http: true, allow_private: true, **)

  def test_response_body_is_read_up_to_the_limit_and_the_rest_is_never_loaded
    size = 20 * 1_048_576
    chunk = "x" * 65_536
    with_responder(content_length: size, chunk: chunk, pause: 0, chunks: size / chunk.bytesize) do |port, written|
      response = local_http.post("http://127.0.0.1:#{port}/hook", "{}")

      assert_equal 200, response.status
      assert_equal I::Integrations::SafeHttp::MAX_RESPONSE_BYTES, response.body.bytesize
      assert_operator written.pop, :<, size / 2, "a conexão é encerrada ao atingir o limite"
    end
  end

  def test_dripping_destination_is_cut_by_the_total_deadline
    with_responder(content_length: 100, chunk: "x", pause: 0.3, chunks: 100) do |port, _|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(I::Integrations::DeadlineExceeded) do
        local_http(read_timeout: 1, total_timeout: 1).post("http://127.0.0.1:#{port}/hook", "{}")
      end

      assert_match(/1s/, error.message)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.5
    end
  end

  def test_secret_box_round_trip_and_tamper_detection
    box = I::SecretBox.new("chave-de-teste-com-tamanho-suficiente")
    sealed = box.encrypt("whsec_segredo")

    refute_includes sealed, "whsec_segredo"
    assert_equal "whsec_segredo", box.decrypt(sealed)
    refute_equal sealed, box.encrypt("whsec_segredo"), "IV aleatório"
    tampered = sealed.sub(/.\z/) { |c| c == "A" ? "B" : "A" }

    assert_raises(ArgumentError) { box.decrypt(tampered) }
    assert_raises(ArgumentError) { I::SecretBox.new("outra-chave-com-tamanho-suficiente").decrypt(sealed) }
    assert_raises(ArgumentError) { box.decrypt("v0.xxx") }
    assert_raises(ArgumentError) { I::SecretBox.new("curta") }
  end

  def test_webhook_signature_validation_with_timestamp_tolerance
    now = Time.utc(2026, 3, 2, 12)
    header = I::WebhookSignature.header("segredo", now.to_i, '{"a":1}')

    assert I::WebhookSignature.valid?("segredo", header, '{"a":1}', now: now)
    refute I::WebhookSignature.valid?("segredo", header, '{"a":2}', now: now)
    refute I::WebhookSignature.valid?("outro", header, '{"a":1}', now: now)
    refute I::WebhookSignature.valid?("segredo", header, '{"a":1}', now: now + 301)
    refute I::WebhookSignature.valid?("segredo", "lixo", '{"a":1}', now: now)
  end

  def test_local_storage_rejects_arbitrary_paths
    Dir.mktmpdir do |root|
      storage = I::Storage::Local.new(root: root)
      key = "00000000-0000-7000-8000-000000000001/00000000-0000-7000-8000-000000000002"
      stats = storage.put(key, "conteúdo".b)

      assert_equal 9, stats[:byte_size]
      assert_equal "conteúdo".b, storage.get(key)
      ["../../etc/passwd", "/etc/passwd", "#{key}/../../x", "a/b", ""].each do |bad|
        assert_raises(I::Storage::InvalidKey, bad) { storage.get(bad) }
      end
      storage.delete(key)

      refute storage.exist?(key)
    end
  end
end
