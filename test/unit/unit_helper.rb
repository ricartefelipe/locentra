# frozen_string_literal: true

# Suíte unitária: carrega somente domínio e aplicação. Sem banco, rede ou servidor.
require_relative "../test_helper"
require "locentra/domain"
require "locentra/application" if File.exist?(File.expand_path("../../lib/locentra/application.rb", __dir__))

class UnitTest < Minitest::Test
  include PropertyTesting
  include TimeHelpers

  Domain = Locentra::Domain
end
