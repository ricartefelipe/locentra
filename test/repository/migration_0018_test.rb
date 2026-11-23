# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "repository_helper"

# Atualização de um banco da versão 1.3.0 (migrations 0001 a 0017) para a 0018, com usuários gravados no
# formato da 1.3.0: confirmados, não confirmados criados há mais de 7 dias e não confirmados recentes.
# Depois da migration, todos estão confirmados, as confirmações anteriores não mudam, os confirmados pela
# migration são identificáveis pelo instante gravado em schema_migrations e a conta antiga não fica somente
# leitura. Cadastros no formato da 1.3.0 (sem confirmação) continuam aceitos e seguem a regra nova. O
# esquema completo é recriado ao final.
class Migration0018Test < DatabaseTest
  MIGRATIONS = File.expand_path("../../db/migrations", __dir__)
  EC = Locentra::Domain::Identity::EmailConfirmation
  CONFIRMED_AT = Time.utc(2026, 1, 10, 8, 0, 0)

  def setup
    super
    @previous = Dir.mktmpdir("locentra-migrations")
    Dir.children(MIGRATIONS).sort.each { |file| FileUtils.cp(File.join(MIGRATIONS, file), @previous) unless file.start_with?("0018") }
    recreate_schema
    migrator(@previous).migrate
  end

  # O esquema completo volta a existir para os testes seguintes do mesmo processo.
  def teardown
    FileUtils.remove_entry(@previous) if @previous
    migrator(MIGRATIONS).migrate
    super
  rescue Locentra::Infrastructure::Database::MigrationError
    TestDatabase.instance_variable_set(:@prepared, false)
    TestDatabase.prepare!
  end

  def migrator(directory) = Locentra::Infrastructure::Database::Migrator.new(url: TestDatabase.owner_url, directory: directory)

  def recreate_schema
    conn = TestDatabase.owner_connection
    conn.exec("DROP SCHEMA IF EXISTS public CASCADE")
    conn.exec("CREATE SCHEMA public")
    conn.exec("GRANT USAGE ON SCHEMA public TO locentra_app, locentra_worker")
  end

  USER_SQL = <<~SQL
    INSERT INTO users (id, email, name, password_digest, email_confirmed_at, created_at, updated_at) VALUES ($1, $2, 'Pessoa', 'x', $3, $4, $4)
  SQL

  # Usuário no formato da 1.3.0, gravado pelo papel da aplicação.
  def legacy_user(email, created_at:, confirmed_at: nil)
    id = SecureRandom.uuid
    conn = PG.connect(TestDatabase.app_url)
    conn.exec_params(USER_SQL, [id, email, confirmed_at, created_at])
    id
  ensure
    conn&.close
  end

  def users
    TestDatabase.owner_connection.exec("SELECT id, email_confirmed_at, updated_at FROM users").to_a.to_h do |row|
      [row["id"], [row["email_confirmed_at"], row["updated_at"]]]
    end
  end

  def applied_at
    TestDatabase.owner_connection.exec("SELECT applied_at FROM schema_migrations WHERE version = '0018'").getvalue(0, 0)
  end

  def test_upgrade_confirms_existing_users_and_keeps_previous_confirmations
    confirmed = legacy_user("confirmada@legado.test", created_at: Time.utc(2026, 1, 2), confirmed_at: CONFIRMED_AT)
    old = legacy_user("antiga@legado.test", created_at: Time.utc(2025, 12, 1))
    recent = legacy_user("recente@legado.test", created_at: Time.utc(2026, 3, 1))
    before = users

    assert_equal ["0018"], migrator(MIGRATIONS).migrate
    after = users

    assert_equal before.fetch(confirmed), after.fetch(confirmed), "confirmação anterior intacta"
    assert_equal [applied_at, applied_at], [after.fetch(old).first, after.fetch(recent).first], "identificáveis pelo instante da migration"
    assert_equal [applied_at, applied_at], [after.fetch(old).last, after.fetch(recent).last]
    assert_equal 0, TestDatabase.owner_connection.exec("SELECT count(*) FROM users WHERE email_confirmed_at IS NULL").getvalue(0, 0).to_i
    assert_equal [], migrator(MIGRATIONS).migrate, "aplicada uma única vez"
  end

  # Proprietária cadastrada há 30 dias sem confirmar: sem a migration, a conta ficaria somente leitura na
  # atualização; com ela, continua operando e convidando. Um cadastro no formato da 1.3.0 depois da
  # migration nasce sem confirmação e segue a regra nova.
  def test_legacy_owner_keeps_operating_and_new_signups_follow_the_rule
    org = create_organization(confirmed: false)
    TestDatabase.owner_connection.exec_params("UPDATE users SET created_at = $2 WHERE id = $1", [org[:user_id], @clock.now - (30 * 86_400)])
    status = -> { @system.uow.run(org[:actor]) { |_tx, current| current.email_status } }

    assert_equal EC::READ_ONLY, status.call
    migrator(MIGRATIONS).migrate

    assert_equal EC::CONFIRMED, status.call
    assert_equal "convidado@legado.test", uc(:invite_member).call(org[:actor], email: "convidado@legado.test", role: "attendant")["email"]
    fresh = legacy_user("depois@legado.test", created_at: @clock.now)

    assert_nil users.fetch(fresh).first
  end
end
