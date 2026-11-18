# frozen_string_literal: true

require_relative "cli_helper"
require_relative "../support/worker_support"

# `jobs failures` e `jobs retry`: tarefas mortas da organização e reprocessamento autorizado
# (jobs.manage), auditado com actor_type cli.
class CliJobsTest < CliTest
  include WorkerHelpers

  LEAKED = %w[segredo-url abc123 hunter2].freeze

  def teardown
    @worker_system&.shutdown
    super
  end

  # Tarefa com uma única tentativa cujo handler falha: termina `dead` com a mensagem de erro.
  def dead_job(organization_id = @org[:organization_id], error: "rede indisponível")
    id = worker_system.transactor.call(tenant_id: organization_id) do |tx|
      worker_system.queue.enqueue(tx, "webhooks.deliver", { "delivery_id" => SecureRandom.uuid }, max_attempts: 1)
    end
    handlers = Locentra::Interfaces::Worker::Handlers.new(worker_system, mailer: @mailer, templates: worker_system.services[:mail_templates])
    handlers.register("webhooks.deliver", ->(_job) { raise IOError, error })
    Locentra::Interfaces::Worker::Runner.new(system: worker_system, handlers: handlers, concurrency: 1, logger: worker_system.logger,
                                             scheduler: false).drain
    id
  end

  def job(id) = jobs("id = '#{id}'").first

  def test_failures_human_and_json_with_redacted_errors
    id = dead_job(error: "falha em https://usuario:segredo-url@hooks.example.test/receber?assinatura=abc123 password=hunter2 #{@token}")
    human = cli("jobs", "failures")

    assert_equal 0, human.status, human.err
    assert_includes human.out, "Tarefas mortas (1), horários em America/Sao_Paulo:"
    redacted = Regexp.escape("IOError: falha em https://[credenciais]@hooks.example.test/receber?[parâmetros omitidos]")

    assert_match(%r{^#{id}\s+webhooks\.deliver\s+1/1\s+02/03/2026 09:00\s+#{redacted}}, human.out)
    assert_includes human.out, "Reprocessar: bin/locentra jobs retry ID"
    json = cli("jobs", "failures", "--json")

    assert_equal 0, json.status
    row = json.json["data"].first

    assert_equal %w[id kind attempts max_attempts last_error correlation_id created_at updated_at finished_at], row.keys
    assert_equal [id, "webhooks.deliver", 1, 1, "2026-03-02T12:00:00Z"], row.values_at("id", "kind", "attempts", "max_attempts", "finished_at")
    assert_equal "IOError: falha em https://[credenciais]@hooks.example.test/receber?[parâmetros omitidos] password=[omitido] [credencial]",
                 row["last_error"]
    [human, json].each do |outcome|
      LEAKED.each { |secret| refute_includes outcome.text, secret }
      assert_no_secret(outcome)
    end
  end

  def test_retry_requeues_the_dead_job_and_is_audited_as_cli
    id = dead_job
    human = cli("jobs", "retry", id)

    assert_equal 0, human.status, human.err
    assert_includes human.out, "Tarefa #{id} (webhooks.deliver) reenfileirada para reprocessamento."
    assert_includes human.out, "Tentativas anteriores: 1. A operação foi registrada na auditoria."
    assert_equal ["pending", "0", nil], job(id).values_at("status", "attempts", "last_error"), "tentativas zeradas (consulta sem conversão de tipos)"
    audit = audit_rows("job.retried")

    assert_equal 1, audit.size
    assert_equal ["cli", @credential["id"], id], audit.first.values_at("actor_type", "actor_id", "resource_id")
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, audit.first["request_id"])
    assert_equal({ "kind" => "webhooks.deliver", "attempts" => 1, "last_error" => "IOError: rede indisponível" }, JSON.parse(audit.first["details"]))
    again = cli("jobs", "retry", id, "--json")

    assert_equal [69, "job_not_dead"], [again.status, again.error["code"]]
    assert_includes again.error["message"], "situação atual: Pendente"
    assert_equal 1, audit_rows("job.retried").size, "conflito não é auditado como reprocessamento"
  end

  def test_retry_json_output
    id = dead_job
    outcome = cli("jobs", "retry", id, "--json")

    assert_equal 0, outcome.status, outcome.err
    assert_equal({ "job" => { "id" => id, "kind" => "webhooks.deliver", "status" => "pending", "previous_attempts" => 1 } }, outcome.json)
  end

  def test_retry_requires_jobs_manage
    id = dead_job
    limited = cli_credential(@actor, scopes: %w[reservations.read], name: "Sem tarefas")["token"]
    denied = cli("jobs", "retry", id, "--json", token: limited)

    assert_equal [77, "forbidden", "permissão necessária: jobs.manage"], [denied.status, *denied.error.values_at("code", "message")]
    assert_equal "dead", job(id)["status"]
    assert_empty audit_rows("job.retried")
  end

  def test_jobs_are_isolated_between_organizations
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    foreign = dead_job(beta[:organization_id])

    assert_equal "Nenhuma tarefa morta.", cli("jobs", "failures").out.strip
    attempt = cli("jobs", "retry", foreign, "--json")

    assert_equal [1, "not_found"], [attempt.status, attempt.error["code"]]
    assert_equal "dead", job(foreign)["status"]
    beta_token = cli_credential(beta[:actor], scopes: %w[jobs.manage])["token"]

    assert_equal([foreign], cli("jobs", "failures", "--json", token: beta_token).json["data"].map { |row| row["id"] })
    assert_empty audit_rows("job.retried")
  end

  def test_invalid_references_and_limits_are_business_errors
    [%w[jobs retry abc], ["jobs", "retry", SecureRandom.uuid], %w[jobs failures --limite 0], %w[jobs failures --limite x]].each do |argv|
      assert_equal 1, cli(*argv).status, argv.inspect
    end
    2.times { dead_job }

    assert_equal 1, cli("jobs", "failures", "--json", "--limite", "1").json["data"].size
  end
end
