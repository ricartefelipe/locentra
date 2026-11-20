# frozen_string_literal: true

require_relative "integration_helper"
require "stringio"
require "locentra/interfaces/cli/admin"

# Rotação de APP_ENCRYPTION_KEY: com a chave nova e a anterior configuradas, os segredos continuam
# legíveis, e secrets:reencrypt regrava todos com a chave nova (por organização, com o papel do worker).
class SecretRotationTest < DatabaseTest
  OLD_KEY = TestDatabase.env.fetch("APP_ENCRYPTION_KEY")
  NEW_KEY = "chave-nova-de-cifragem-0123456789"

  def setup
    super
    @org = create_organization
    @other = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    @endpoint = uc(:create_webhook).call(@org[:actor], url: "http://127.0.0.1:9/a", events: ["*"])
    uc(:configure_payment_account).call(@other[:actor], provider: "asaas", name: "Asaas sandbox", api_key: "$aact_hmlg_chave-de-teste-9876")
  end

  def ciphertexts
    webhook = owner_query("SELECT secret_ciphertext AS v FROM webhook_endpoints", [], tenant: @org[:organization_id]).first["v"]
    api_key = owner_query("SELECT api_key_ciphertext AS v FROM payment_provider_accounts", [], tenant: @other[:organization_id]).first["v"]
    [webhook, api_key]
  end

  def reencrypt
    out = StringIO.new
    env = { "WORKER_DATABASE_URL" => TestDatabase.worker_url, "APP_ENCRYPTION_KEY" => NEW_KEY, "APP_ENCRYPTION_KEY_PREVIOUS" => OLD_KEY }
    status = Locentra::Interfaces::CLI::Admin.new(env: env, out: out, err: StringIO.new).run(%w[secrets:reencrypt --json])
    [status, JSON.parse(out.string)]
  end

  def test_rotation_keeps_secrets_readable_and_reencrypts_every_organization
    before = ciphertexts
    rotated = Locentra::Infrastructure::SecretBox.new(NEW_KEY, previous: [OLD_KEY])

    assert_equal [@endpoint["secret"], "$aact_hmlg_chave-de-teste-9876"], before.map { |c| rotated.decrypt(c) }, "a chave anterior ainda decifra"
    assert_equal [0, { "webhook_endpoints" => 1, "payment_provider_accounts" => 1 }], reencrypt
    after = ciphertexts
    only_new = Locentra::Infrastructure::SecretBox.new(NEW_KEY)

    assert_equal([@endpoint["secret"], "$aact_hmlg_chave-de-teste-9876"], after.map { |c| only_new.decrypt(c) })
    assert_raises(ArgumentError) { Locentra::Infrastructure::SecretBox.new(OLD_KEY).decrypt(after.first) }
    assert_equal [0, { "webhook_endpoints" => 0, "payment_provider_accounts" => 0 }], reencrypt, "idempotente"
  end
end
