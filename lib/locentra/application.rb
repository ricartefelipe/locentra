# frozen_string_literal: true

# Casos de uso. Dependem do domínio e de portas injetadas (repositórios, fila, relógio).
require_relative "domain"
require_relative "application/base"
require_relative "application/identity"
require_relative "application/organizations"
require_relative "application/customers"
require_relative "application/availability"
require_relative "application/catalog"
require_relative "application/reservations"
