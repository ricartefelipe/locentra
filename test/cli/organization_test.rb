# frozen_string_literal: true

require_relative "cli_helper"
require_relative "../support/organization_settings_support"

# `organization show`: configurações e filiais em saída humana e JSON (o mesmo objeto da API v1), escopo
# `organization.read`, ajuda e filial inativa com a situação.
class CliOrganizationTest < CliTest
  include OrganizationSettingsSupport

  def setup
    super
    @credential = cli_credential(@actor, scopes: %w[organization.read], name: "Leitura da organização")
    @token = @credential["token"]
  end

  def test_human_output_with_defaults
    outcome = cli("organization", "show")

    assert_equal 0, outcome.status, outcome.err
    lines = outcome.out.lines.map(&:rstrip)

    ["Organização: Locadora Alfa (locadora-alfa)", "Fuso horário: America/Sao_Paulo — Brasília (SP, RJ, MG, ES, PR, SC, RS, GO, DF)",
     "Validade padrão do bloqueio temporário: 30 minutos (padrão)", "Política de cancelamento (padrão):",
     "  - 72 h ou mais antes do início: multa de 0% do valor contratado",
     "  - de 24 h a menos de 72 h antes do início: multa de 30% do valor contratado",
     "  - menos de 24 h antes do início (ou após o início): multa de 100% do valor contratado", "Filiais:",
     "Alterações: somente pela interface web (Organização > Editar configurações)."].each { |line| assert_includes lines, line }
    assert_match(/^Código\s+Nome\s+Endereço\s+Situação$/, outcome.out)
    assert_match(/^MATRIZ\s+Matriz\s+—\s+Ativa$/, outcome.out)
    assert_no_secret(outcome)
  end

  def test_custom_policy_inactive_branch_and_json_equal_to_the_serializer
    north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE", address: "Av. Norte, 100")
    uc(:set_branch_active).call(@actor, north.id, active: false)
    change_settings(hold_minutes: "45", cancellation_rows: [%w[0 50]])
    human = cli("organization", "show").out

    assert_includes human, "Validade padrão do bloqueio temporário: 45 minutos\n"
    assert_includes human, "Política de cancelamento:\n  - em qualquer momento (antes ou após o início): multa de 50% do valor contratado"
    assert_match(%r{^NORTE\s+Unidade Norte\s+Av\. Norte, 100\s+Inativa desde 02/03/2026 09:00$}, human)
    outcome = cli("organization", "show", "--json")
    data = uc(:read_organization).call(@actor)

    assert_equal 0, outcome.status
    assert_equal JSON.parse(JSON.generate(Locentra::Interfaces::OrganizationSerializers.organization(data[:organization], data[:branches]))),
                 outcome.json
    assert_equal [45, false], [outcome.json.dig("settings", "hold_minutes"), outcome.json.dig("settings", "cancellation_policy_default")]
  end

  def test_scope_is_required_and_the_help_lists_the_command
    outcome = cli("organization", "show", "--json", token: cli_credential(@actor, scopes: %w[reservations.read], name: "Sem escopo")["token"])

    assert_equal [77, "forbidden"], [outcome.status, outcome.error["code"]]
    assert_includes cli("--help", token: nil).out, "organization show"
    assert_includes cli("organization", "--help", token: nil).out,
                    "Configurações da organização (fuso, bloqueio temporário, política de cancelamento) e filiais"
  end
end
