# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/database"
require "json"
require "stringio"
require "locentra/interfaces/cli/admin"

# CLI administrativa (bin/locentra-admin): códigos de saída, saída JSON e mensagens de erro sem a senha
# da URL do banco.
class AdminCliTest < Minitest::Test
  Admin = Locentra::Interfaces::CLI::Admin

  def setup
    TestDatabase.prepare!
  end

  def run_admin(argv, env)
    out = StringIO.new
    err = StringIO.new
    status = Admin.new(env: env, out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  def test_status_and_migrate_with_json
    env = { "MIGRATION_DATABASE_URL" => TestDatabase.owner_url, "LOG_LEVEL" => "error" }
    status, out, = run_admin(%w[db:status --json], env)
    rows = JSON.parse(out)

    assert_equal 0, status
    assert_equal Dir[File.expand_path("../../db/migrations/*.sql", __dir__)].size, rows.size
    assert_equal ["aplicada"], rows.map { |row| row["status"] }.uniq
    status, out, = run_admin(%w[db:migrate --json], env)

    assert_equal [0, { "applied" => [] }], [status, JSON.parse(out)]
  end

  def test_usage_and_configuration_errors
    assert_equal 64, run_admin(%w[db:inexistente], {}).first
    assert_equal 64, run_admin(%w[--opcao-invalida], {}).first
    status, _, err = run_admin(%w[db:status], {})

    assert_equal [1, "erro: MIGRATION_DATABASE_URL não definido\n"], [status, err]
  end

  def test_seed_is_refused_in_production
    status, _, err = run_admin(%w[db:seed], "APP_ENV" => "production")

    assert_equal 1, status
    assert_match(/recusado com APP_ENV=production/, err)
  end

  def test_database_password_is_never_printed
    {
      "postgres://locentra_owner:SenhaSecreta99@[::1/x" => "URL que o libpq não interpreta",
      "postgres://locentra_owner:SenhaSecreta99@127.0.0.1:1/locentra" => "conexão recusada",
      "host=127.0.0.1 port=1 user=locentra_owner password=SenhaSecreta99 dbname=locentra" => "parâmetros de conexão"
    }.each do |url, scenario|
      status, out, err = run_admin(%w[db:status], "MIGRATION_DATABASE_URL" => url)

      assert_equal 2, status, scenario
      assert_match(/não foi possível conectar ao banco/, err, scenario)
      refute_includes out + err, "SenhaSecreta99", scenario
    end
  end
end
