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
require_relative "domain/identity"
require_relative "domain/organizations"
require_relative "domain/customers"
require_relative "domain/catalog"
require_relative "domain/reservations"
require_relative "domain/pricing"
require_relative "domain/finance/receivables"
require_relative "domain/finance/payments"
require_relative "domain/finance/deposits"
require_relative "domain/finance/journal"
require_relative "domain/finance/reconciliation"
