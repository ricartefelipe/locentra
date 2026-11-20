# frozen_string_literal: true

require "rake/testtask"

SUITES = {
  unit: "test/unit/**/*_test.rb",
  repository: "test/repository/**/*_test.rb",
  integration: "test/integration/**/*_test.rb",
  http: "test/http/**/*_test.rb",
  cli: "test/cli/**/*_test.rb",
  concurrency: "test/concurrency/**/*_test.rb",
  browser: "test/browser/**/*_test.rb"
}.freeze

namespace :test do
  SUITES.each do |name, pattern|
    Rake::TestTask.new(name) do |task|
      task.libs = %w[lib test]
      task.pattern = pattern
      task.warning = false
      task.description = "Executa a suíte #{name}"
    end
  end

  desc "Executa todas as suítes exceto navegador, em um único processo (cobertura consolidada)"
  Rake::TestTask.new(:all) do |task|
    task.libs = %w[lib test]
    task.test_files = SUITES.except(:browser).values.flat_map { |pattern| FileList[pattern] }
    task.warning = false
  end
end

desc "Suíte unitária (sem banco, rede ou servidor)"
task test: "test:unit"

desc "Análise estática"
task :lint do
  sh "bundle exec rubocop"
end

desc "Auditoria de dependências com base de vulnerabilidades atualizada"
task :audit do
  sh "bundle exec bundle-audit check --update"
end

task default: %i[lint test]
