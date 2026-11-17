# frozen_string_literal: true

# Dimensionamento: cada processo Puma usa até PUMA_THREADS conexões do pool (DB_POOL_SIZE deve ser
# >= PUMA_THREADS). Total de conexões da camada web = WEB_CONCURRENCY (mín. 1) × DB_POOL_SIZE.
threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"))
threads threads_count, threads_count

workers Integer(ENV.fetch("WEB_CONCURRENCY", "0"))
port Integer(ENV.fetch("PORT", "9292"))
environment ENV.fetch("APP_ENV", "development")

# Sem preload: nenhum objeto com conexão é criado antes do fork. Cada worker carrega config.ru.
preload_app! false

worker_shutdown_timeout 25
persistent_timeout 20
first_data_timeout 30

# Limite de tamanho da linha/cabeçalhos é aplicado pelo Puma; o corpo é limitado pela aplicação.
