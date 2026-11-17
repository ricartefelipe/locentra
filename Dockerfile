# syntax=docker/dockerfile:1.7
ARG RUBY_VERSION=4.0.9

# ---------------------------------------------------------------------------
# Base comum: Ruby, bibliotecas de execução e usuário sem privilégios.
# ---------------------------------------------------------------------------
FROM ruby:${RUBY_VERSION}-slim-trixie AS base
ENV LANG=C.UTF-8 \
    TZ=UTC \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3
# `apt-get upgrade` aplica correções de segurança publicadas após a construção da imagem base.
RUN apt-get update \
 && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends libpq5 libyaml-0-2 tzdata ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Remove a default gem json 2.18.0 (CVE-2026-33210). A versão corrigida vem do Gemfile.lock.
RUN archdir="$(ruby -e 'print RbConfig::CONFIG["archdir"]')" \
 && rubylibdir="$(ruby -e 'print RbConfig::CONFIG["rubylibdir"]')" \
 && rm -rf "${rubylibdir}/json" "${rubylibdir}/json.rb" "${archdir}/json" \
      "$(ruby -e 'print Gem.default_specifications_dir')"/json-*.gemspec
WORKDIR /app

# ---------------------------------------------------------------------------
# Build: compila extensões nativas a partir do lockfile.
# ---------------------------------------------------------------------------
FROM base AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle config set --local deployment true \
 && bundle config set --local without "development test" \
 && bundle install \
 && rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# ---------------------------------------------------------------------------
# Desenvolvimento e testes: todas as dependências e Chromium para testes de navegador.
# ---------------------------------------------------------------------------
FROM base AS dev
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev pkg-config git \
      chromium fonts-dejavu-core postgresql-client \
 && rm -rf /var/lib/apt/lists/*
ENV BROWSER_PATH=/usr/bin/chromium
COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install
COPY . .
CMD ["bundle", "exec", "rake", "test:unit"]

# ---------------------------------------------------------------------------
# Execução: imagem enxuta para web, worker e CLI.
# ---------------------------------------------------------------------------
FROM base AS runtime
ENV APP_ENV=production \
    BUNDLE_DEPLOYMENT=true \
    BUNDLE_WITHOUT="development test"
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY . .
RUN groupadd --system --gid 10001 locentra \
 && useradd --system --uid 10001 --gid locentra --home-dir /app --shell /usr/sbin/nologin locentra \
 && mkdir -p /app/storage /app/tmp \
 && chown -R locentra:locentra /app/storage /app/tmp
USER locentra:locentra
EXPOSE 9292
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD ["ruby", "-rnet/http", "-e", "exit(Net::HTTP.get_response(URI('http://127.0.0.1:9292/health/live')).is_a?(Net::HTTPSuccess) ? 0 : 1)"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
