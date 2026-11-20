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

  # Metas para domínio e aplicação, verificadas quando COVERAGE_CHECK=1 (suíte completa na CI).
  # Nenhum arquivo dessas camadas é excluído da medição.
  if ENV["COVERAGE_CHECK"] == "1"
    SimpleCov.at_exit do
      result = SimpleCov.result
      result.format!
      files = result.files.select { |f| f.filename.include?("/lib/locentra/domain") || f.filename.include?("/lib/locentra/application") }
      lines_total = files.sum { |f| f.covered_lines.size + f.missed_lines.size }
      lines_hit = files.sum { |f| f.covered_lines.size }
      branches_total = begin
        files.sum(&:total_branches_count)
      rescue StandardError
        files.sum { |f| f.total_branches.size }
      end
      branches_hit = begin
        files.sum(&:covered_branches_count)
      rescue StandardError
        files.sum { |f| f.covered_branches.size }
      end
      line_pct = lines_total.zero? ? 100.0 : (100.0 * lines_hit / lines_total)
      branch_pct = branches_total.zero? ? 100.0 : (100.0 * branches_hit / branches_total)
      warn format("Cobertura domínio+aplicação: linhas %<lines>.2f%% (meta 90%%), branches %<branches>.2f%% (meta 80%%)", lines: line_pct, branches: branch_pct)
      if line_pct < 90 || branch_pct < 80
        warn "Metas de cobertura não atingidas."
        exit 1
      end
    end
  end
end

require "minitest/autorun"
require_relative "support/property"
require_relative "support/time_helpers"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
