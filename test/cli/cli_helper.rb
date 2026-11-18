# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/database"
require "json"
require "stringio"
require "tmpdir"
require "locentra/interfaces/cli/operational"

# Executa a CLI operacional no mesmo processo, com o System do teste (relógio controlado), e
# captura stdout, stderr e o código de saída.
class CliTest < DatabaseTest
  CLI = Locentra::Interfaces::CLI

  Outcome = Data.define(:status, :out, :err) do
    def json = JSON.parse(out)
    def error = JSON.parse(err.lines.last)["error"]
    def text = out + err
  end

  ALL_SCOPES = %w[availability.read reservations.read customers.read catalog.read finance.read finance.write jobs.manage].freeze

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @credential = cli_credential(@actor, scopes: ALL_SCOPES)
    @token = @credential["token"]
  end

  # Câmera com dois ativos (CAM-CLI-1 e CAM-CLI-2) e cadeiras com estoque de 10 (CAD-CLI) na matriz.
  def catalog_setup
    @camera = create_product(@actor, sku: "CAM-CLI", name: "Câmera CLI", tracking: "serialized")
    @assets = register_assets(@actor, @camera, @org[:branch], 2)
    @chairs = create_product(@actor, sku: "CAD-CLI", name: "Cadeira CLI", tracking: "bulk")
    stock(@actor, @chairs, @org[:branch], 10)
  end

  def cli_credential(actor, scopes:, kind: "cli", days: 30, name: "Rotina operacional")
    uc(:create_credential).call(actor, name: name, scopes: scopes, kind: kind, expires_in_days: days)
  end

  def cli(*argv, token: @token, env: {}, system: @system)
    out = StringIO.new
    err = StringIO.new
    environment = TestDatabase.env(token ? { "LOCENTRA_TOKEN" => token } : {}).merge(env)
    status = CLI::Operational.new(env: environment, out: out, err: err, system: system).run(argv.flatten.map(&:to_s))
    Outcome.new(status: status, out: out.string, err: err.string)
  end

  # Nenhuma saída pode conter a credencial completa nem o segredo isolado.
  def assert_no_secret(outcome, token = @token)
    secret = token.split("_", 3).last

    refute_includes outcome.text, token
    refute_includes outcome.text, secret
  end

  def audit_rows(action)
    owner_query("SELECT actor_type, actor_id, resource_id, request_id, details FROM audit_events WHERE action = $1 ORDER BY occurred_at", [action])
  end
end
