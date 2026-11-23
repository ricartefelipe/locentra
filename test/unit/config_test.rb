# frozen_string_literal: true

require_relative "unit_helper"
require "locentra/config"

# Configuração do worker: threads da fila de webhooks, limite de execuções simultâneas por organização e
# janelas de retenção do histórico de integrações, com os mínimos seguros recusados na leitura.
class ConfigTest < UnitTest
  BASE = { "DATABASE_URL" => "postgres://x@db/x", "APP_SECRET_KEY_BASE" => "s" * 40, "APP_ENCRYPTION_KEY" => "k" * 20 }.freeze

  def config(env = {}) = Locentra::Config.from_env(BASE.merge(env))

  def refused(env)
    assert_raises(Locentra::ConfigError, env.inspect) { config(env) }.message
  end

  def test_defaults_for_webhook_threads_fairness_and_retention
    defaults = config

    assert_equal [4, 2, 30, 30, 90], [defaults.webhook_concurrency, defaults.webhook_max_per_organization, defaults.outbox_retention_days,
                                      defaults.webhook_delivery_retention_days, defaults.inbound_webhook_retention_days]
  end

  def test_limit_per_organization_must_be_between_one_and_one_hundred
    %w[0 101 -1].each do |value|
      assert_equal "WEBHOOK_MAX_PER_ORGANIZATION deve estar entre 1 e 100", refused("WEBHOOK_MAX_PER_ORGANIZATION" => value)
    end
    assert_equal([1, 100], %w[1 100].map { |value| config("WEBHOOK_MAX_PER_ORGANIZATION" => value).webhook_max_per_organization })
    assert_equal "WEBHOOK_CONCURRENCY não pode ser negativo", refused("WEBHOOK_CONCURRENCY" => "-1")
    assert_equal 0, config("WEBHOOK_CONCURRENCY" => "0").webhook_concurrency, "zero desliga as threads de webhooks do processo"
    assert_match(/configuração inválida/, refused("WEBHOOK_MAX_PER_ORGANIZATION" => "dois"))
  end

  def test_retention_windows_refuse_values_below_the_safe_minimum_or_above_ten_years
    assert_equal "INBOUND_WEBHOOK_RETENTION_DAYS deve estar entre 45 e 3650 dias (mínimo seguro: 45)",
                 refused("INBOUND_WEBHOOK_RETENTION_DAYS" => "44")
    assert_equal 45, config("INBOUND_WEBHOOK_RETENTION_DAYS" => "45").inbound_webhook_retention_days
    assert_equal "OUTBOX_RETENTION_DAYS deve estar entre 7 e 3650 dias (mínimo seguro: 7)", refused("OUTBOX_RETENTION_DAYS" => "6")
    assert_equal "WEBHOOK_DELIVERY_RETENTION_DAYS deve estar entre 7 e 3650 dias (mínimo seguro: 7)",
                 refused("WEBHOOK_DELIVERY_RETENTION_DAYS" => "3651")
    assert_equal 7, config("WEBHOOK_DELIVERY_RETENTION_DAYS" => "7").webhook_delivery_retention_days
    %w[OUTBOX_RETENTION_DAYS INBOUND_WEBHOOK_RETENTION_DAYS].each do |var|
      assert_includes refused(var => "3651"), "#{var} deve estar entre"
      assert_equal 3650, config(var => "3650").public_send(Locentra::RETENTION_LIMITS.find { |_, (_, name)| name == var }.first)
    end
  end
end
