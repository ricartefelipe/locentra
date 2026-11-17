# frozen_string_literal: true

require_relative "repository_helper"

class TransactorTest < DatabaseTest
  def transactor = @system.transactor

  def test_rollback_on_error_and_connection_returns_clean
    org = create_organization
    assert_raises(RuntimeError) do
      transactor.call(tenant_id: org[:organization_id]) do |tx|
        tx.execute("UPDATE organizations SET name = 'Alterado' WHERE id = $1", [org[:organization_id]])
        raise "falha"
      end
    end
    name = transactor.call(tenant_id: org[:organization_id]) do |tx|
      tx.query_value("SELECT name FROM organizations WHERE id = $1", [org[:organization_id]])
    end

    assert_equal "Locadora Alfa", name
    context = transactor.call { |tx| tx.query_value("SELECT current_setting('app.tenant_id', true)") }

    assert_includes [nil, ""], context, "o contexto de tenant é local à transação"
  end

  def test_nested_transactions_are_rejected
    assert_raises(Locentra::Infrastructure::Database::NestedTransactionError) do
      transactor.call { transactor.call { nil } }
    end
    assert_equal(1, transactor.call { |tx| tx.query_value("SELECT 1") })
  end

  def test_savepoint_rolls_back_only_inner_block
    org = create_organization
    transactor.call(tenant_id: org[:organization_id]) do |tx|
      tx.execute("UPDATE organizations SET name = 'Externo' WHERE id = $1", [org[:organization_id]])
      assert_raises(D::Conflict) do
        tx.savepoint do
          tx.execute("UPDATE organizations SET name = 'Interno' WHERE id = $1", [org[:organization_id]])
          tx.execute("INSERT INTO branches (id, organization_id, name, code, created_at, updated_at) VALUES ($1, $2, 'Dup', 'MATRIZ', now(), now())",
                     [SecureRandom.uuid, org[:organization_id]])
        end
      end
    end
    name = transactor.call(tenant_id: org[:organization_id]) do |tx|
      tx.query_value("SELECT name FROM organizations WHERE id = $1", [org[:organization_id]])
    end

    assert_equal "Externo", name
  end

  def test_after_commit_runs_only_on_success
    ran = []
    transactor.call { |tx| tx.after_commit { ran << :ok } }
    begin
      transactor.call do |tx|
        tx.after_commit { ran << :nao }
        raise ArgumentError
      end
    rescue ArgumentError
      nil
    end

    assert_equal [:ok], ran
  end

  def test_parameters_are_never_interpolated
    value = transactor.call { |tx| tx.query_value("SELECT $1::text", ["'; DROP TABLE users; --"]) }

    assert_equal "'; DROP TABLE users; --", value
    assert_equal 1, owner_query("SELECT count(*) AS n FROM pg_tables WHERE tablename = 'users'").first["n"].to_i
  end

  def test_pool_discards_broken_connections
    pid = transactor.call { |tx| tx.query_value("SELECT pg_backend_pid()") }
    TestDatabase.owner_connection.exec_params("SELECT pg_terminate_backend($1)", [pid]) rescue nil # rubocop:disable Style/RescueModifier

    assert_equal(1, transactor.call { |tx| tx.query_value("SELECT 1") })
  end
end

class MigratorTest < Minitest::Test
  def setup
    TestDatabase.prepare!
  end

  def migrator(directory)
    Locentra::Infrastructure::Database::Migrator.new(url: TestDatabase.owner_url, directory: directory)
  end

  def test_applied_migrations_are_up_to_date
    real = migrator(File.expand_path("../../db/migrations", __dir__))

    refute_predicate real, :pending?
    assert(real.status.all? { |row| row["status"] == "aplicada" })
  end

  def test_detects_edited_migration
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir[File.expand_path("../../db/migrations/*.sql", __dir__)], dir)
      File.write(File.join(dir, "0001_identidade_organizacoes.sql"), "\n-- alteração", mode: "a")
      error = assert_raises(Locentra::Infrastructure::Database::MigrationError) { migrator(dir).migrate }

      assert_match(/alterada após aplicada/, error.message)
      assert_equal "checksum divergente", migrator(dir).status.first["status"]
    end
  end

  def test_concurrent_runs_are_mutually_exclusive
    results = Queue.new
    threads = Array.new(3) { Thread.new { results << migrator(File.expand_path("../../db/migrations", __dir__)).migrate } }
    threads.each(&:join)

    assert_equal [[], [], []], Array.new(3) { results.pop }
  end
end
