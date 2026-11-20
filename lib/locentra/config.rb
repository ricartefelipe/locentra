# frozen_string_literal: true

require "ipaddr"
require "uri"

module Locentra
  class ConfigError < StandardError; end

  PAYMENT_PROVIDER_NAMES = %w[simulator asaas].freeze
  SMTP_TLS_MODES = %w[none starttls tls].freeze
  SMTP_AUTH_METHODS = %w[plain login cram_md5].freeze

  # Configuração lida do ambiente somente quando o sistema é montado (nunca ao carregar o domínio).
  Config = Data.define(:env, :base_url, :secret_key_base, :encryption_key, :database_url, :worker_database_url,
                       :migration_database_url, :pool_size, :pool_timeout, :worker_concurrency, :webhook_concurrency, :log_level, :smtp,
                       :payment_providers, :asaas_base_url, :storage_root, :max_upload_bytes, :bcrypt_cost,
                       :metrics_token, :trusted_proxies, :api_rate_limit, :worker_health_file) do
    def self.from_env(env = ENV, overrides = {})
      app_env = env.fetch("APP_ENV", "development")
      values = {
        env: app_env,
        base_url: env.fetch("APP_BASE_URL", "http://localhost:9292"),
        secret_key_base: env["APP_SECRET_KEY_BASE"],
        encryption_key: env["APP_ENCRYPTION_KEY"],
        database_url: env["DATABASE_URL"],
        worker_database_url: env["WORKER_DATABASE_URL"],
        migration_database_url: env["MIGRATION_DATABASE_URL"],
        pool_size: Integer(env.fetch("DB_POOL_SIZE", env.fetch("PUMA_THREADS", "5"))),
        pool_timeout: Integer(env.fetch("DB_POOL_TIMEOUT", "5")),
        worker_concurrency: Integer(env.fetch("WORKER_CONCURRENCY", "4")),
        webhook_concurrency: Integer(env.fetch("WEBHOOK_CONCURRENCY", "1")),
        log_level: env.fetch("LOG_LEVEL", "info"),
        smtp: smtp(env, app_env),
        payment_providers: payment_providers(env["PAYMENT_PROVIDERS"], app_env),
        asaas_base_url: env.fetch("ASAAS_BASE_URL", "https://api-sandbox.asaas.com/v3"),
        storage_root: env.fetch("STORAGE_ROOT", File.expand_path("../../storage", __dir__)),
        max_upload_bytes: Integer(env.fetch("MAX_UPLOAD_BYTES", "10485760")),
        bcrypt_cost: Integer(env.fetch("BCRYPT_COST", app_env == "test" ? "4" : "12")),
        metrics_token: optional(env, "METRICS_TOKEN"),
        trusted_proxies: trusted_proxies(env["TRUSTED_PROXIES"]),
        api_rate_limit: Integer(env.fetch("API_RATE_LIMIT", "1200")),
        worker_health_file: env.fetch("WORKER_HEALTH_FILE", File.expand_path("../../tmp/worker.alive", __dir__))
      }.merge(overrides)
      new(**values).tap(&:validate!)
    rescue ArgumentError => e
      raise ConfigError, "configuração inválida: #{e.message}"
    end

    def self.optional(env, key) = env[key].to_s.empty? ? nil : env[key]

    # Envio de e-mail: servidor, remetente, TLS (none, starttls obrigatório ou tls implícito na conexão)
    # e autenticação. Em produção o padrão é starttls e `none` é recusado: links de recuperação de senha,
    # convites e contratos não trafegam em texto claro.
    def self.smtp(env, app_env)
      {
        host: env.fetch("SMTP_HOST", "localhost"), port: Integer(env.fetch("SMTP_PORT", "1025")),
        from: env.fetch("MAIL_FROM", "Locentra <nao-responda@locentra.local>"),
        tls: env.fetch("SMTP_TLS", app_env == "production" ? "starttls" : "none"),
        user_name: optional(env, "SMTP_USERNAME"), password: optional(env, "SMTP_PASSWORD"),
        authentication: env.fetch("SMTP_AUTH", "plain")
      }.freeze
    end

    # Provedores de pagamento que as organizações podem configurar neste processo. A chave de cada
    # conta é cadastrada por organização (Financeiro → Provedor), nunca no ambiente. O simulador
    # confirma pagamentos sem dinheiro real: fora da lista padrão de produção.
    def self.payment_providers(text, app_env)
      default = app_env == "production" ? "asaas" : PAYMENT_PROVIDER_NAMES.join(",")
      (text.to_s.strip.empty? ? default : text).split(",").map(&:strip).reject(&:empty?).uniq.freeze
    end

    # Endereços (IP ou CIDR, separados por vírgula) dos proxies reversos cujo X-Forwarded-For é
    # aceito. Vazio: o IP do cliente é sempre o par da conexão (REMOTE_ADDR).
    def self.trusted_proxies(text)
      text.to_s.split(",").map(&:strip).reject(&:empty?).map { |cidr| IPAddr.new(cidr) }.freeze
    rescue IPAddr::InvalidAddressError
      raise ConfigError, "TRUSTED_PROXIES inválido"
    end

    def production? = env == "production"
    def test? = env == "test"

    def validate!
      raise ConfigError, "DATABASE_URL obrigatório" if database_url.to_s.empty?
      raise ConfigError, "APP_SECRET_KEY_BASE deve ter ao menos 32 caracteres" if secret_key_base.to_s.length < 32
      raise ConfigError, "APP_ENCRYPTION_KEY obrigatório" if encryption_key.to_s.length < 16

      unknown = payment_providers - PAYMENT_PROVIDER_NAMES
      raise ConfigError, "PAYMENT_PROVIDERS inválido (use simulator e/ou asaas)" if payment_providers.empty? || !unknown.empty?
      raise ConfigError, "APP_BASE_URL deve usar https em produção" if production? && !base_url.start_with?("https://")
      raise ConfigError, "API_RATE_LIMIT deve ser positivo" unless api_rate_limit.positive?

      validate_smtp!

      true
    end

    def validate_smtp!
      raise ConfigError, "SMTP_TLS inválido (use none, starttls ou tls)" unless SMTP_TLS_MODES.include?(smtp[:tls])
      raise ConfigError, "SMTP_TLS deve ser starttls ou tls em produção" if production? && smtp[:tls] == "none"
      raise ConfigError, "SMTP_AUTH inválido (use plain, login ou cram_md5)" unless SMTP_AUTH_METHODS.include?(smtp[:authentication])
      raise ConfigError, "SMTP_USERNAME e SMTP_PASSWORD devem ser definidos juntos" if smtp[:user_name].nil? != smtp[:password].nil?
    end

    def secure_cookies? = production? || base_url.start_with?("https://")

    # Representação sem segredos, para diagnóstico.
    def inspect
      "#<Locentra::Config env=#{env} base_url=#{base_url} pool_size=#{pool_size} providers=#{payment_providers.join(",")}>"
    end
    alias_method :to_s, :inspect
  end
end
