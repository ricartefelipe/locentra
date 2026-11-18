# frozen_string_literal: true

require_relative "cli_helper"

# `availability`: mesma consulta da web e da API (CheckAvailability), com horários locais ou ISO 8601.
class CliAvailabilityTest < CliTest
  def setup
    super
    catalog_setup
    customer = create_customer(@actor)
    reserve(@actor, customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z"), [line(@camera, 1), line(@chairs, 4)],
            mode: "confirm")
  end

  def window = %w[--inicio 2026-03-10T05:00 --fim 2026-03-10T09:00]

  def test_human_output_uses_local_time_and_sku_filter
    outcome = cli("availability", *window, "--produto", "cam-cli")

    assert_equal 0, outcome.status, outcome.err
    assert_includes outcome.out, "Disponibilidade na filial MATRIZ (Matriz), período 10/03/2026 05:00 → 10/03/2026 09:00 (America/Sao_Paulo)"
    assert_match(/^CAM-CLI\s+Câmera CLI\s+Ativo individual\s+1\s+2$/, outcome.out)
    refute_includes outcome.out, "CAD-CLI"
    assert_no_secret(outcome)
  end

  def test_json_output_with_iso_instants_branch_code_and_ids
    outcome = cli("availability", "--json", "--filial", "matriz", "--inicio", "2026-03-10T08:00:00Z", "--fim", "2026-03-10T12:00:00Z")

    assert_equal 0, outcome.status, outcome.err
    data = outcome.json

    assert_equal %w[branch period time_zone data], data.keys
    assert_equal({ "id" => @org[:branch].id, "code" => "MATRIZ", "name" => "Matriz" }, data["branch"])
    assert_equal({ "starts_at" => "2026-03-10T08:00:00Z", "ends_at" => "2026-03-10T12:00:00Z" }, data["period"])
    assert_equal %w[product_id sku name tracking available total], data["data"].first.keys
    rows = data["data"].to_h { |row| [row["sku"], row.values_at("available", "total")] }

    assert_equal({ "CAM-CLI" => [1, 2], "CAD-CLI" => [6, 10] }, rows)
    mixed = cli("availability", "--json", "--filial", @org[:branch].id, *window, "--produto", "#{@chairs.id},CAM-CLI")

    assert_equal %w[CAD-CLI CAM-CLI], mixed.json["data"].map { |row| row["sku"] }.sort
    outside = cli("availability", "--json", "--inicio", "2026-03-10T12:00:00Z", "--fim", "2026-03-10T13:00:00Z", "--produto", "CAM-CLI")

    assert_equal [2, 2], outside.json["data"].first.values_at("available", "total"), "período semiaberto: devolução às 12:00 libera o ativo"
  end

  def test_validation_and_lookup_errors_are_business_errors
    unknown_sku = cli("availability", "--json", *window, "--produto", "NAO-EXISTE")

    assert_equal [1, "validation_error"], [unknown_sku.status, unknown_sku.error["code"]]
    assert_includes unknown_sku.error["details"]["fields"]["produto"].first, "NAO-EXISTE"
    unknown_id = cli("availability", "--json", *window, "--produto", SecureRandom.uuid)

    assert_equal [1, "validation_error"], [unknown_id.status, unknown_id.error["code"]]
    assert_includes unknown_id.error["message"], "produto: não encontrado"
    branch = cli("availability", "--json", "--filial", "XYZ", *window)

    assert_equal [1, "filial: não encontrada (códigos: MATRIZ)"], [branch.status, branch.error["message"]]
    inverted = cli("availability", "--inicio", "2026-03-10T09:00", "--fim", "2026-03-10T05:00")

    assert_equal 1, inverted.status
    assert_includes inverted.err, "o fim deve ser posterior ao início"
    malformed = cli("availability", "--json", "--inicio", "10/03/2026", "--fim", "2026-03-10T09:00")

    assert_equal [1, ["inicio"]], [malformed.status, malformed.error["details"]["fields"].keys]
    assert_includes malformed.error["message"], "America/Sao_Paulo"
    assert_equal 64, cli("availability", *window, "--produto", ",").status
  end

  def test_branch_is_required_when_there_are_several_and_scope_is_checked
    uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    several = cli("availability", *window)

    assert_equal 64, several.status
    assert_includes several.err, "informe --filial (códigos: MATRIZ, NORTE)"
    assert_equal 0, cli("availability", "--filial", "norte", *window).status
    no_scope = cli_credential(@actor, scopes: %w[reservations.read], name: "Sem disponibilidade")["token"]

    assert_equal 77, cli("availability", "--filial", "MATRIZ", *window, token: no_scope).status
  end
end
