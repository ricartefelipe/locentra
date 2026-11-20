# frozen_string_literal: true

require "bundler/setup"
require_relative "lib/locentra/system"
require_relative "lib/locentra/interfaces/http/app"

# Cada processo Puma monta o próprio System (pools são criados sob demanda após o fork).
system = Locentra::System.boot(ENV, {}, pool_name: "web")
run Locentra::Interfaces::HTTP::App.build(system, reload_templates: system.config.env == "development")
