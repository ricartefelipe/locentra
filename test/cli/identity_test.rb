# frozen_string_literal: true

require_relative "cli_helper"

# Identidade da CLI: credencial do tipo cli, origem do token, recusas, escopos, configuração e uso.
class CliIdentityTest < CliTest
  def test_whoami_human_and_json
    human = cli("whoami")

    assert_equal 0, human.status, human.err
    assert_includes human.out, "Credencial: Rotina operacional (tipo cli, id #{@credential["id"]})"
    assert_includes human.out, "Organização: Locadora Alfa (locadora-alfa) · fuso America/Sao_Paulo"
    assert_includes human.out, "Escopos: #{ALL_SCOPES.sort.join(", ")}"
    assert_includes human.out, "Válida até: 01/04/2026 09:00"
    json = cli("whoami", "--json")

    assert_equal 0, json.status
    data = json.json

    assert_equal "cli", data["actor_type"]
    assert_equal({ "id" => @org[:organization_id], "name" => "Locadora Alfa", "slug" => "locadora-alfa", "time_zone" => "America/Sao_Paulo" },
                 data["organization"])
    assert_equal %w[id name kind created_at expires_at last_used_at scopes], data["credential"].keys
    assert_equal ["2026-04-01T12:00:00Z", ALL_SCOPES.sort], data["credential"].values_at("expires_at", "scopes")
    assert_no_secret(human)
    assert_no_secret(json)
  end

  def test_rejected_credentials_exit_77_without_touching_them
    revoked = cli_credential(@actor, scopes: %w[reservations.read], name: "Revogada")
    uc(:revoke_credential).call(@actor, revoked["id"])
    expiring = cli_credential(@actor, scopes: %w[reservations.read], name: "Curta", days: 1)
    api = cli_credential(@actor, scopes: %w[reservations.read], name: "Integração", kind: "api")
    @clock.advance(2 * 86_400)
    unknown = "lcn_#{@org[:organization_id].delete("-")}_#{"a" * 43}"
    { "revogada" => revoked["token"], "expirada" => expiring["token"], "tipo api" => api["token"], "inexistente" => unknown }.each do |label, token|
      outcome = cli("whoami", "--json", token: token)

      assert_equal [77, "credential_rejected"], [outcome.status, outcome.error["code"]], label
      assert_includes outcome.error["message"], "credencial recusada", label
      assert_empty outcome.out, label
      assert_no_secret(outcome, token)
    end
    malformed = cli("whoami", token: "lcn_invalido")

    assert_equal 77, malformed.status
    assert_includes malformed.err, "credencial recusada"
    assert_nil owner_query("SELECT last_used_at FROM api_credentials WHERE id = $1", [api["id"]]).first["last_used_at"], "API não é tocada"
  end

  # A credencial segue a situação de confirmação de e-mail de quem a criou (ADR-031): depois do prazo do criador
  # sem confirmação, só consulta, e a recusa sai com o código próprio.
  def test_credential_of_a_read_only_creator_only_reads
    owner_query("UPDATE users SET email_confirmed_at = NULL WHERE id = $1", [@org[:user_id]], tenant: "")
    @clock.advance(Locentra::Domain::Identity::EmailConfirmation::GRACE_PERIOD_SECONDS)
    denied = cli("finance", "reconcile", "--json")

    assert_equal [77, "email_unconfirmed"], [denied.status, denied.error["code"]]
    assert_includes denied.error["message"], "Conta somente leitura até a confirmação do e-mail"
    assert_equal 0, cli("reservations", "list").status
  end

  def test_insufficient_scope_is_denied
    limited = cli_credential(@actor, scopes: %w[availability.read], name: "Somente disponibilidade")["token"]
    human = cli("reservations", "list", token: limited)

    assert_equal 77, human.status
    assert_includes human.err, "permissão necessária: reservations.read"
    json = cli("jobs", "failures", "--json", token: limited)

    assert_equal ["forbidden", 77, "permissão necessária: jobs.manage"], json.error.values_at("code", "exit_code", "message")
    assert_empty json.out
  end

  def test_unit_of_work_revalidates_the_credential_after_authentication
    actor = uc(:authenticate_credential).call(@token, kind: "cli")
    invocation = CLI::Parser.new.parse(%w[reservations list])

    assert_equal 0, CLI::Commands.new(system: @system, actor: actor).run(invocation).exit_code
    uc(:revoke_credential).call(@actor, @credential["id"])

    assert_raises(D::AccessDenied) { CLI::Commands.new(system: @system, actor: actor).run(invocation) }
    forged = actor.with(scopes: Locentra::Domain::Identity::PERMISSIONS.keys)
    narrow = cli_credential(@actor, scopes: %w[availability.read], name: "Estreita")
    narrowed = forged.with(credential_id: narrow["id"])

    assert_raises(D::AccessDenied, "escopos vêm do banco, não do ator") { CLI::Commands.new(system: @system, actor: narrowed).run(invocation) }
  end

  def test_token_file_requirements
    Dir.mktmpdir do |dir|
      path = File.join(dir, "credencial")
      File.write(path, "#{@token}\n")
      File.chmod(0o644, path)
      insecure = cli("whoami", "--token-file", path, token: nil)

      assert_equal 2, insecure.status
      assert_includes insecure.err, "atual 0644; use chmod 600"
      File.chmod(0o600, path)
      from_file = cli("whoami", "--json", "--token-file", path, token: "lcn_ignorado_quando_ha_arquivo")

      assert_equal 0, from_file.status, from_file.err
      assert_no_secret(from_file)
      link = File.join(dir, "atalho")
      File.symlink(path, link)
      empty = File.join(dir, "vazio")
      File.write(empty, "\n")
      File.chmod(0o600, empty)
      large = File.join(dir, "grande")
      File.write(large, "x" * 600)
      File.chmod(0o600, large)
      { link => "link simbólico", File.join(dir, "inexistente") => "não encontrado", dir => "arquivo regular", empty => "vazio",
        large => "acima de 512 bytes" }.each do |file, message|
        outcome = cli("whoami", "--json", "--token-file", file, token: nil)

        assert_equal [2, "configuration"], [outcome.status, outcome.error["code"]], message
        assert_includes outcome.error["message"], message
      end
      foreign = CLI::TokenSource.new(env: {}, file: path, uid: Process.euid + 1)
      error = assert_raises(Locentra::ConfigError) { foreign.read }

      assert_includes error.message, "deve pertencer ao usuário"
    end
  end

  def test_missing_token_and_database_configuration_exit_2_without_leaking_passwords
    missing = cli("whoami", token: nil)

    assert_equal 2, missing.status
    assert_includes missing.err, "credencial ausente: defina LOCENTRA_TOKEN"
    owner = cli("whoami", "--json", system: nil, env: { "DATABASE_URL" => TestDatabase.owner_url })

    assert_equal [2, "configuration"], [owner.status, owner.error["code"]]
    assert_includes owner.error["message"], "credencial de migrations"
    down = cli("whoami", "--json", system: nil, env: { "DATABASE_URL" => "postgres://locentra_app:senha-local@127.0.0.1:1/locentra" })

    assert_equal [2, "connection"], [down.status, down.error["code"]]
    assert_includes down.error["message"], "não foi possível conectar ao banco"
    unset = cli("whoami", system: nil, env: { "DATABASE_URL" => "" })

    assert_equal 2, unset.status
    assert_includes unset.err, "DATABASE_URL obrigatório"
    [owner, down, unset].each { |outcome| assert_no_secret(outcome) }
  end

  # O libpq repete a URL inteira quando não consegue interpretá-la: a mensagem chega à saída com a
  # senha mascarada, como erro de configuração (2), e não como erro interno.
  def test_malformed_database_url_is_a_configuration_error_with_the_password_masked
    password = "senha-que-nao-pode-vazar"
    url = "postgress://locentra_app:#{password}@127.0.0.1:1/locentra"
    json = cli("whoami", "--json", system: nil, env: { "DATABASE_URL" => url, "LOCENTRA_CLI_LOG_LEVEL" => "info" })

    assert_equal [2, "configuration", 2], [json.status, *json.error.values_at("code", "exit_code")]
    assert_includes json.error["message"], "DATABASE_URL"
    assert_includes json.error["message"], "postgress://locentra_app:[omitido]@127.0.0.1:1/locentra", "a mensagem do libpq contém a URL"
    human = cli("whoami", system: nil, env: { "DATABASE_URL" => url })

    assert_equal 2, human.status
    assert_includes human.err, "postgress://locentra_app:[omitido]@127.0.0.1:1/locentra"
    [json, human].each do |outcome|
      refute_includes outcome.text, password
      refute_includes outcome.text, "cli.error", "não é registrado como erro interno"
    end
  end

  # O papel é conferido no banco, com ou sem MIGRATION_DATABASE_URL no ambiente: proprietário do
  # schema (migrations) e papel do worker (políticas para todas as organizações) são recusados.
  def test_database_role_is_verified_even_without_migration_database_url
    without_migration = [nil, ""]
    { "proprietário do schema" => TestDatabase.owner_url, "todas as organizações" => TestDatabase.worker_url }.each do |reason, url|
      without_migration.each do |migration|
        outcome = cli("whoami", "--json", system: nil, env: { "DATABASE_URL" => url, "MIGRATION_DATABASE_URL" => migration })

        assert_equal [2, "configuration"], [outcome.status, outcome.error["code"]], reason
        assert_includes outcome.error["message"], reason
        assert_includes outcome.error["message"], "exige o papel da aplicação"
        assert_empty outcome.out
      end
    end

    assert_nil owner_query("SELECT last_used_at FROM api_credentials WHERE id = $1", [@credential["id"]]).first["last_used_at"],
               "a recusa ocorre antes da autenticação"
  end

  # Organização suspensa ou encerrada: a credencial deixa de autenticar e um ator já autenticado é
  # recusado pela UnitOfWork, como acontece com os vínculos de usuários.
  def test_credentials_of_inactive_organizations_are_refused
    actor = uc(:authenticate_credential).call(@token, kind: "cli")
    %w[suspended closed].each do |status|
      owner_query("UPDATE organizations SET status = $2 WHERE id = $1", [@org[:organization_id], status])
      outcome = cli("whoami", "--json")

      assert_equal [77, "credential_rejected"], [outcome.status, outcome.error["code"]], status
      assert_raises(D::AccessDenied, status) { uc(:whoami).call(actor) }
      assert_raises(D::AccessDenied, status) { CLI::Commands.new(system: @system, actor: actor).run(CLI::Parser.new.parse(%w[jobs failures])) }
    end
    owner_query("UPDATE organizations SET status = 'active' WHERE id = $1", [@org[:organization_id]])

    assert_equal 0, cli("whoami").status
  end

  def test_usage_errors_exit_64_without_echoing_values
    [[], ["inexistente"], %w[reservations], %w[reservations apagar], %w[reservations show], %w[whoami extra], %w[whoami --opcao],
     %w[jobs --limite 1], %w[jobs retry], %w[availability --inicio 2026-03-10T08:00], ["--version=1"]].each do |argv|
      outcome = cli(*argv)

      assert_equal 64, outcome.status, argv.inspect
      assert_includes outcome.err, "erro:", argv.inspect
    end
    passed = cli("whoami", "--token", @token, token: nil)

    assert_equal 64, passed.status
    assert_includes passed.err, "não é aceito como argumento"
    abbreviated = cli("whoami", "--json", "--tok=#{@token}")

    assert_equal [64, "usage", "opção desconhecida: --tok"], [abbreviated.status, *abbreviated.error.values_at("code", "message")]
    positional = cli("whoami", @token)

    assert_equal 64, positional.status
    [passed, abbreviated, positional].each { |outcome| assert_no_secret(outcome) }
    assert_includes cli("availability").err, "informe --inicio e --fim"
  end

  def test_help_and_version
    general = cli("--help", token: nil)

    assert_equal 0, general.status
    assert_includes general.out, "jobs retry ID"
    assert_includes general.out, " 77  permissão negada"
    assert_includes cli("jobs", "--help", token: nil).out, "jobs failures"
    assert_includes cli("--help", "asset", token: nil).out, "asset show PATRIMÔNIO|ID"
    list = cli("reservations", "list", "--help", token: nil)

    assert_equal 0, list.status
    assert_includes list.out, "--situacao SITUAÇÃO"
    assert_equal "locentra #{Locentra::VERSION}\n", cli("--version", token: nil).out
  end
end
