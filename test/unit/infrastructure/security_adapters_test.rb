# frozen_string_literal: true

require_relative "../unit_helper"
require "locentra/infrastructure/crypto"
require "locentra/infrastructure/storage"
require "locentra/infrastructure/integrations/safe_http"
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
