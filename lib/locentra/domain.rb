# frozen_string_literal: true

# Carrega somente o domínio. Não abre conexões, não inicia threads e não lê variáveis
# de ambiente; depende apenas da biblioteca padrão e de tzinfo.
require_relative "version"
require_relative "domain/errors"
require_relative "domain/shared/money"
require_relative "domain/shared/period"
require_relative "domain/shared/time_zone"
require_relative "domain/shared/clock"
require_relative "domain/availability"
