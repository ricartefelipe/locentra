# frozen_string_literal: true

require_relative "cli_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# `finance reconcile`: executa o caso de uso de conciliação (finance.write) e mostra o relatório
# (finance.read), com correções seguras aplicadas e auditadas como actor_type cli.
class CliFinanceTest < CliTest
  include WorkerHelpers
  include FinanceHelpers

  # Provedor fora do ar: toda requisição ao Asaas responde 503.
  class OutageHttp
    def request(*, **) = Locentra::Infrastructure::Payments::HttpClient::Response.new(status: 503, body: "")
  end

  def setup
    super
    finance_setup(@org)
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  # Pagamento online enviado ao simulador e pendente no Locentra.
  def pending_online_payment
    worker_system
    simulator_account
    reservation = booking
    sync(reservation)
    requested = request_online(rental_of(reservation), 10_000)
    drain
    requested
  end

  def test_human_output_reports_and_corrects_a_lost_confirmation
    paid = pending_online_payment
    owner_query("UPDATE payment_simulator_charges SET status = 'RECEIVED' WHERE external_reference = $1", [paid.id])
    outcome = cli("finance", "reconcile")

    assert_equal 0, outcome.status, outcome.err
    assert_match(/^Conciliação \S+ · Concluída$/, outcome.out)
    assert_includes outcome.out, "Provedor: Simulador local · pagamentos e cobranças desde 31/01/2026 09:00 (America/Sao_Paulo)"
    assert_includes outcome.out, "Pagamentos verificados: 1 · divergências: 1"
    assert_match(/^Situação divergente\s+#{paid.id}\s+sim_\h+\s+Aguardando pagamento\s+Paga\s+R\$ 100,00\s+R\$ 100,00\s+Atualizado no Locentra$/,
                 outcome.out)
    assert_equal "confirmed", payment(paid.id).status, "webhook perdido compensado pela conciliação"
    audit = audit_rows("reconciliation.completed").last

    assert_equal ["cli", @credential["id"]], audit.values_at("actor_type", "actor_id")
    refute_nil audit["request_id"]
    assert_no_secret(outcome)
  end

  def test_json_output
    pending_online_payment
    outcome = cli("finance", "reconcile", "--json")

    assert_equal 0, outcome.status, outcome.err
    data = outcome.json

    assert_equal %w[report items], data.keys
    assert_equal %w[id provider status window_start started_at finished_at summary error], data["report"].keys
    assert_equal ["simulator", "completed", nil, "2026-01-31T12:00:00Z"], data["report"].values_at("provider", "status", "error", "window_start")
    assert_equal [1, 0, true], data["report"]["summary"].values_at("checked", "discrepancies", "complete")
    assert_empty data["items"]
    owner_query("DELETE FROM payment_simulator_charges")
    @clock.advance(3600)
    missing = cli("finance", "reconcile", "--json").json["items"]

    assert_equal [%w[missing_remote review]], missing.map { |i| i.values_at("kind", "action") }, "pendente ausente no provedor vai para revisão"
    assert_equal({ "amount_cents" => 10_000, "currency" => "BRL", "formatted" => "R$ 100,00" }, missing.first["local_amount"])
    assert_nil missing.first["remote_amount"]
  end

  def test_requires_an_active_account_and_both_finance_scopes
    no_account = cli("finance", "reconcile", "--json")

    assert_equal [1, "validation_error"], [no_account.status, no_account.error["code"]]
    assert_includes no_account.error["message"], "nenhuma conta de provedor de pagamentos ativa"
    simulator_account
    write_only = cli_credential(@actor, scopes: %w[finance.write], name: "Só escrita")["token"]
    denied = cli("finance", "reconcile", "--json", token: write_only)

    assert_equal [77, "permissão necessária: finance.read"], [denied.status, denied.error["message"]]
    assert_equal 0, count("reconciliation_reports"), "sem permissão para ver o relatório, nada é executado"
    read_only = cli_credential(@actor, scopes: %w[finance.read], name: "Só leitura")["token"]

    assert_equal 77, cli("finance", "reconcile", token: read_only).status
    assert_equal 0, count("reconciliation_reports")
  end

  def test_provider_outage_records_a_failed_report_as_unavailable
    uc(:configure_payment_account).call(@actor, provider: "asaas", name: "Asaas sandbox", api_key: "$aact_hmlg_chave-secreta-de-teste")
    outage = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: @system.logger, payment_http: OutageHttp.new)
    json = cli("finance", "reconcile", "--json", system: outage)

    assert_equal 69, json.status
    assert_equal ["asaas", "failed", "Asaas indisponível (HTTP 503)"], json.json["report"].values_at("provider", "status", "error")
    human = cli("finance", "reconcile", system: outage)

    assert_equal 69, human.status
    assert_includes human.out, "Falha na consulta ao provedor: Asaas indisponível (HTTP 503). Nenhuma alteração foi feita."
    assert_equal 2, count("reconciliation_reports", "status = 'failed'")
    [json, human].each { |outcome| refute_includes outcome.text, "chave-secreta-de-teste" }
  ensure
    outage&.shutdown
  end
end
