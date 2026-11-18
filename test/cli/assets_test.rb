# frozen_string_literal: true

require_relative "cli_helper"

# `asset show`: GetAsset por patrimônio ou identificador, com situação física, alocações e histórico.
class CliAssetsTest < CliTest
  def setup
    super
    catalog_setup
    @reservation = reserve(@actor, create_customer(@actor), @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z"),
                           [line(@camera, 1)], mode: "confirm")
    allocated = @system.uow.run(@actor) { |tx, _| @system.repos[:reservations].allocated_asset_ids(tx, @reservation.id) }
    @rented, @spare = @assets.partition { |asset| allocated.include?(asset.id) }.map(&:first)
    uc(:block_availability).call(@actor, asset_id: @spare.id, period: period("2026-03-12T08:00:00Z", "2026-03-12T10:00:00Z"), reason: "Calibração")
    uc(:open_maintenance_order).call(@actor, description: "Troca do sensor", asset_tag: @spare.tag)
  end

  def test_human_output_by_tag
    outcome = cli("asset", "show", @spare.tag.downcase)

    assert_equal 0, outcome.status, outcome.err
    out = outcome.out

    assert_includes out, "Ativo #{@spare.tag} · Em manutenção"
    assert_includes out, "Produto: CAM-CLI Câmera CLI"
    assert_includes out, "Situação física:"
    assert_includes out, "  Situação: Em manutenção · condição: Bom · série: —"
    assert_includes out, "  Filial atual: MATRIZ (Matriz)"
    assert_includes out, "  Aceita novas alocações: não, até a conclusão da operação"
    assert_includes out, "  Controle operacional: ordem de manutenção ativa"
    assert_match(%r{^12/03/2026 05:00\s+12/03/2026 07:00\s+bloqueio: Calibração\s+—\s+sim$}, out)
    assert_match(/^\S+ \S+\s+maintenance_opened\s+available → in_maintenance\s+Troca do sensor$/, out)
    assert_match(/^\S+ \S+\s+registered\s+— → available/, out)
  end

  def test_json_output_by_id
    outcome = cli("asset", "show", @rented.id, "--json")

    assert_equal 0, outcome.status, outcome.err
    data = outcome.json

    assert_equal %w[asset product allocations history], data.keys
    assert_equal [@rented.tag, "available", "Disponível", "good", nil, true, false],
                 data["asset"].values_at("tag", "status", "status_label", "condition", "operational_hold", "allocatable", "operationally_blocked")
    assert_equal({ "id" => @org[:branch].id, "code" => "MATRIZ", "name" => "Matriz" }, data["asset"]["branch"])
    assert_equal({ "id" => @camera.id, "sku" => "CAM-CLI", "name" => "Câmera CLI", "tracking" => "serialized" }, data["product"])
    allocation = data["allocations"].first

    assert_equal ["reservation", true, { "id" => @reservation.id, "code" => @reservation.code, "status" => "confirmed" }],
                 allocation.values_at("kind", "active", "reservation")
    assert_equal({ "starts_at" => "2026-03-10T08:00:00Z", "ends_at" => "2026-03-10T12:00:00Z" }, allocation["period"])
    assert_equal([["registered", nil, "available"]], data["history"].map { |e| e.values_at("kind", "from_status", "to_status") })
    spare = cli("asset", "show", @spare.tag, "--json").json

    assert_equal ["in_maintenance", "maintenance", true, true, nil],
                 spare["asset"].values_at("status", "operational_hold", "allocatable", "operationally_blocked", "unavailable_until")
    assert_equal([%w[block Calibração]], spare["allocations"].map { |a| a.values_at("kind", "reason") })
  end

  def test_not_found_isolation_and_scope
    assert_equal([1, "not_found"], cli("asset", "show", "NAO-EXISTE", "--json").then { |o| [o.status, o.error["code"]] })
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    beta_token = cli_credential(beta[:actor], scopes: %w[catalog.read])["token"]
    [@rented.tag, @rented.id].each do |reference|
      foreign = cli("asset", "show", reference, "--json", token: beta_token)

      assert_equal [1, "not_found"], [foreign.status, foreign.error["code"]], reference
      refute_includes foreign.text, "Câmera CLI"
    end
    no_catalog = cli_credential(@actor, scopes: %w[reservations.read], name: "Sem catálogo")["token"]

    assert_equal 77, cli("asset", "show", @rented.tag, token: no_catalog).status
  end
end
