# frozen_string_literal: true

require_relative "cli_helper"
require "open3"
require "rbconfig"

# bin/locentra como processo separado: monta o próprio System a partir do ambiente (relógio real,
# DATABASE_URL com o papel da aplicação) e devolve o código de saída ao shell.
class CliSubprocessTest < CliTest
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin", "locentra")

  def setup
    super
    # O processo usa o relógio real: a credencial precisa estar válida agora.
    owner_query("UPDATE api_credentials SET expires_at = now() + interval '1 day' WHERE id = $1", [@credential["id"]])
  end

  def run_bin(*argv, env: {})
    environment = TestDatabase.env("LOCENTRA_TOKEN" => @token).merge(env)
    out, err, status = Open3.capture3(environment, RbConfig.ruby, BIN, *argv, chdir: ROOT)
    Outcome.new(status: status.exitstatus, out: out, err: err)
  end

  def test_whoami_json_in_a_separate_process
    outcome = run_bin("whoami", "--json")

    assert_equal 0, outcome.status, outcome.err
    data = outcome.json

    assert_equal ["cli", @org[:organization_id], "Rotina operacional"], [data["actor_type"], data["organization"]["id"], data["credential"]["name"]]
    refute_nil data["credential"]["last_used_at"], "a autenticação registra o último uso"
    assert_empty outcome.err
    assert_no_secret(outcome)
  end

  def test_token_file_and_human_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "credencial")
      File.write(path, @token)
      File.chmod(0o600, path)
      outcome = run_bin("reservations", "list", "--token-file", path, env: { "LOCENTRA_TOKEN" => nil })

      assert_equal 0, outcome.status, outcome.err
      assert_equal "Nenhuma reserva encontrada.\n", outcome.out
      File.chmod(0o640, path)
      insecure = run_bin("reservations", "list", "--token-file", path, env: { "LOCENTRA_TOKEN" => nil })

      assert_equal 2, insecure.status
      assert_includes insecure.err, "use chmod 600"
    end
  end

  def test_exit_codes_reach_the_shell
    assert_equal 0, run_bin("--help", env: { "LOCENTRA_TOKEN" => nil }).status
    assert_equal 64, run_bin("inexistente").status
    assert_equal 2, run_bin("whoami", env: { "LOCENTRA_TOKEN" => nil }).status
    assert_equal 77, run_bin("whoami", env: { "LOCENTRA_TOKEN" => "lcn_#{@org[:organization_id].delete("-")}_#{"a" * 43}" }).status
    passed = run_bin("whoami", "--token", @token, env: { "LOCENTRA_TOKEN" => nil })

    assert_equal 64, passed.status
    assert_no_secret(passed)
  end
end
