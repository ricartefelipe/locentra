# frozen_string_literal: true

require_relative "../unit_helper"
require "locentra/config"
require "locentra/infrastructure/mailer"

# Envio de e-mail: TLS e autenticação configuráveis; texto claro só fora de produção.
class SmtpTest < UnitTest
  BASE = { "DATABASE_URL" => "postgres://x@db/x", "APP_SECRET_KEY_BASE" => "s" * 40, "APP_ENCRYPTION_KEY" => "k" * 20 }.freeze

  def config(env) = Locentra::Config.from_env(BASE.merge(env))
  def mailer(env) = Locentra::Infrastructure::SmtpMailer.new(**config(env).smtp)

  def test_local_relay_without_tls_and_authentication
    settings = mailer("SMTP_HOST" => "mailpit").settings

    assert_equal({ address: "mailpit", port: 1025, open_timeout: 5, read_timeout: 10, enable_starttls_auto: false }, settings)
  end

  def test_starttls_or_implicit_tls_with_authentication
    production = { "APP_ENV" => "production", "APP_BASE_URL" => "https://l.example" }
    starttls = mailer(production.merge("SMTP_HOST" => "smtp.example", "SMTP_PORT" => "587", "SMTP_USERNAME" => "envio", "SMTP_PASSWORD" => "s3gr3d0"))

    assert_equal [true, OpenSSL::SSL::VERIFY_PEER, "envio", "s3gr3d0", :plain],
                 starttls.settings.values_at(:enable_starttls, :openssl_verify_mode, :user_name, :password, :authentication)
    tls = mailer(production.merge("SMTP_TLS" => "tls", "SMTP_PORT" => "465", "SMTP_USERNAME" => "envio", "SMTP_PASSWORD" => "x", "SMTP_AUTH" => "login"))

    assert_equal [true, :login], tls.settings.values_at(:tls, :authentication)
    refute_includes config(production).inspect, "s3gr3d0"
  end

  def test_invalid_or_plaintext_production_settings_are_refused
    production = { "APP_ENV" => "production", "APP_BASE_URL" => "https://l.example" }

    [production.merge("SMTP_TLS" => "none"), { "SMTP_TLS" => "ssl" }, { "SMTP_AUTH" => "xoauth" }, { "SMTP_USERNAME" => "so-usuario" }].each do |env|
      assert_raises(Locentra::ConfigError, env.inspect) { config(env) }
    end
  end
end
