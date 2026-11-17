# frozen_string_literal: true

# A coleta de cobertura começa antes de qualquer código da aplicação ser carregado.
if ENV.fetch("COVERAGE", "1") == "1"
  require "simplecov"
  SimpleCov.command_name(ENV.fetch("COVERAGE_NAME", "suite"))
  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :line
    skip "/test/"
    skip "/vendor/"
    group "Domínio", "lib/locentra/domain"
    group "Aplicação", "lib/locentra/application"
    group "Infraestrutura", "lib/locentra/infrastructure"
    group "Interfaces", "lib/locentra/interfaces"
    cover "lib/**/*.rb"
  end
end

require "minitest/autorun"
require_relative "support/property"
require_relative "support/time_helpers"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
