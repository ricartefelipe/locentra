# frozen_string_literal: true

source "https://rubygems.org"

ruby file: ".ruby-version"

# HTTP: interface Rack e servidor de aplicação.
gem "puma", "~> 8.1.2"
gem "rack", "~> 3.2.8"

# Persistência: driver PostgreSQL e pool de conexões.
gem "connection_pool", "~> 3.0.2"
gem "pg", "~> 1.7.0"

# Segurança: hashing de senhas.
gem "bcrypt", "~> 3.1.22"

# Fusos horários IANA com base de dados versionada junto ao lockfile.
gem "tzinfo", "~> 2.0.6"
gem "tzinfo-data", "~> 1.2026.6"

# Documentos e e-mail.
gem "mail", "~> 2.9.1"
gem "prawn", "~> 2.5.0"

# Bibliotecas que deixaram de ser default gems no Ruby 4.0 e precisam ser declaradas.
# Prawn 2.5 (via ttfunk 1.8) exige bigdecimal ~> 3.1; a linha 3.3 é compatível com Ruby 4.0.
gem "bigdecimal", "~> 3.3.1"
gem "csv", "~> 3.3.7"
gem "logger", "~> 1.7.0"
gem "net-smtp", "~> 0.5.2"

group :development, :test do
  gem "rake", "~> 13.4.2"
end

group :test do
  gem "ferrum", "~> 0.20.1"
  gem "minitest", "~> 6.1.0"
  gem "rack-test", "~> 2.3.0"
  gem "simplecov", "~> 1.3.2"
end

group :development do
  gem "bundler-audit", "~> 0.9.3", require: false
  gem "rubocop", "~> 1.92.2", require: false
  gem "rubocop-minitest", "~> 0.41.0", require: false
  gem "rubocop-performance", "~> 1.27.0", require: false
end
