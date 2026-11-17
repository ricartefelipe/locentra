# frozen_string_literal: true

# Adaptadores de infraestrutura. Carregar este arquivo não abre conexões.
require_relative "application"
require_relative "infrastructure/database/connection_pool"
require_relative "infrastructure/database/transactor"
require_relative "infrastructure/database/migrator"
require_relative "infrastructure/security"
require_relative "infrastructure/jobs/queue"
require_relative "infrastructure/notifications"
require_relative "infrastructure/persistence/identity"
require_relative "infrastructure/persistence/organizations"
require_relative "infrastructure/persistence/customers"
require_relative "infrastructure/persistence/catalog"
require_relative "infrastructure/persistence/availability"
require_relative "infrastructure/persistence/reservations"
require_relative "infrastructure/persistence/support"
