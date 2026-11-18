# frozen_string_literal: true

require_relative "cli_helper"

# `reservations list` e `reservations show`: ListReservations e GetReservation, com as permissões
# e o isolamento por organização da aplicação.
class CliReservationsTest < CliTest
  def setup
    super
    catalog_setup
    @alice = create_customer(@actor, name: "Cliente Teste")
    @bruna = create_customer(@actor, name: "Outra Cliente", document: "11144477735")
    @confirmed = reserve(@actor, @alice, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z"), [line(@camera, 1)],
                         mode: "confirm")
    @held = reserve(@actor, @bruna, @org[:branch], period("2026-03-20T08:00:00Z", "2026-03-20T10:00:00Z"), [line(@chairs, 2)])
  end

  def codes(outcome) = outcome.json["data"].map { |row| row["code"] }

  def test_list_human_output
    outcome = cli("reservations", "list")

    assert_equal 0, outcome.status, outcome.err
    lines = outcome.out.lines.map(&:rstrip)

    assert_match(/^Código\s+Situação\s+Cliente\s+Retirada\s+Devolução\s+Total$/, lines.first)
    assert_match(%r{^#{@held.code}\s+Bloqueio temporário\s+Outra Cliente\s+20/03/2026 05:00\s+20/03/2026 07:00\s+#{Regexp.escape(@held.total.format_brl)}$},
                 lines[2])
    assert_match(%r{^#{@confirmed.code}\s+Confirmada\s+Cliente Teste\s+10/03/2026 05:00\s+10/03/2026 09:00\s+#{Regexp.escape(@confirmed.total.format_brl)}$},
                 lines[3])
    assert_includes outcome.out, "Exibindo 1–2 de 2 (horários em America/Sao_Paulo)."
    paged = cli("reservations", "list", "--limite", "1", "--ordem=code")

    assert_includes paged.out, "Exibindo 1–1 de 2 (horários em America/Sao_Paulo). Próxima página: --deslocamento 1."
    assert_includes cli("reservations", "list", "--situacao", "cancelled").out, "Nenhuma reserva encontrada."
  end

  def test_list_json_with_filters_and_pagination
    outcome = cli("reservations", "list", "--json", "--situacao", "confirmed")

    assert_equal 0, outcome.status, outcome.err
    data = outcome.json

    assert_equal [@confirmed.code], codes(outcome)
    assert_equal({ "limit" => 25, "offset" => 0, "total" => 1, "next_offset" => nil }, data["pagination"])
    row = data["data"].first

    assert_equal %w[id code status status_label source customer_id branch_id period hold_expires_at total deposit version customer_name], row.keys
    assert_equal ["confirmed", "Cliente Teste", @confirmed.total.to_h, @confirmed.period.to_h],
                 row.values_at("status", "customer_name", "total", "period")
    assert_equal [@held.code], codes(cli("reservations", "list", "--json", "--cliente", @bruna.id))
    assert_equal [@held.code], codes(cli("reservations", "list", "--json", "--de", "2026-03-15", "--ate", "2026-03-25"))
    assert_equal [@confirmed.code], codes(cli("reservations", "list", "--json", "--ate", "2026-03-10T05:30"))
    assert_equal [@held.code], codes(cli("reservations", "list", "--json", "--busca", "outra"))
    assert_equal 2, cli("reservations", "list", "--json", "--de", "2020-01-01", "--ate", "2030-01-01").json["pagination"]["total"],
                 "a janela do filtro não tem duração máxima"
    second = cli("reservations", "list", "--json", "--ordem=code", "--limite", "1", "--deslocamento", "1")

    assert_equal [[@held.code], { "limit" => 1, "offset" => 1, "total" => 2, "next_offset" => nil }], [codes(second), second.json["pagination"]]
  end

  def test_list_validation_errors_are_business_errors
    [%w[--situacao apagada], %w[--limite 1000], %w[--cliente abc], %w[--ordem=valor], %w[--de 2026-03-20 --ate 2026-03-10],
     %w[--de 2026-02-30]].each do |filters|
      outcome = cli("reservations", "list", "--json", *filters)

      assert_equal [1, "validation_error"], [outcome.status, outcome.error["code"]], filters.inspect
    end
  end

  def test_show_by_code_human_output
    outcome = cli("reservations", "show", @confirmed.code.downcase)

    assert_equal 0, outcome.status, outcome.err
    assert_includes outcome.out, "Reserva #{@confirmed.code} · Confirmada"
    assert_includes outcome.out, "Cliente: Cliente Teste (id #{@alice.id})"
    assert_includes outcome.out, "Filial: MATRIZ (Matriz)"
    assert_includes outcome.out, "Período: 10/03/2026 05:00 → 10/03/2026 09:00 (America/Sao_Paulo)"
    assert_includes outcome.out, "Total: #{@confirmed.total.format_brl} · caução: #{@confirmed.deposit.format_brl} · origem: #{@confirmed.source}"
    assert_match(/^CAM-CLI\s+Câmera CLI\s+1\s+#{Regexp.escape(@confirmed.total.format_brl)}$/, outcome.out)
    assert_match(%r{^ativo CAM-CLI-\d\s+1\s+10/03/2026 05:00\s+10/03/2026 09:00\s+sim$}, outcome.out)
    held = cli("reservations", "show", @held.code)

    assert_includes held.out, "Bloqueio temporário até: #{@held.hold_expires_at.getlocal("-03:00").strftime("%d/%m/%Y %H:%M")}"
    assert_match(%r{^estoque\s+2\s+20/03/2026 05:00\s+20/03/2026 07:00\s+sim$}, held.out)
  end

  def test_show_by_id_json_output
    outcome = cli("reservations", "show", @held.id, "--json")

    assert_equal 0, outcome.status, outcome.err
    data = outcome.json

    assert_equal %w[reservation customer branch items allocations], data.keys
    assert_equal [@held.code, "held", @held.hold_expires_at.iso8601, nil], data["reservation"].values_at("code", "status", "hold_expires_at", "notes")
    assert_equal({ "id" => @bruna.id, "name" => "Outra Cliente" }, data["customer"])
    assert_equal "MATRIZ", data["branch"]["code"]
    assert_equal([["CAD-CLI", 2, "bulk"]], data["items"].map { |item| item.values_at("sku", "quantity", "tracking") })
    assert_empty data["allocations"]["assets"]
    assert_equal([[2, true, { "starts_at" => "2026-03-20T08:00:00Z", "ends_at" => "2026-03-20T10:00:00Z" }]],
                 data["allocations"]["stock"].map { |s| s.values_at("quantity", "active", "period") })
    limited = cli_credential(@actor, scopes: %w[reservations.read], name: "Sem clientes")["token"]

    assert_equal({ "id" => @bruna.id }, cli("reservations", "show", @held.code, "--json", token: limited).json["customer"],
                 "sem customers.read, o nome do cliente não é exibido")
  end

  def test_human_output_neutralizes_control_characters_from_stored_data
    noisy = reserve(@actor, @alice, @org[:branch], period("2026-03-25T08:00:00Z", "2026-03-25T10:00:00Z"), [line(@chairs, 1)],
                    notes: "Entrega\n\e[2JReserva R-000009 · Cancelada")
    outcome = cli("reservations", "show", noisy.code)

    assert_equal 0, outcome.status, outcome.err
    refute_includes outcome.out, "\e"
    refute_match(/^Reserva R-000009/, outcome.out, "dados gravados não forjam linhas da saída")
    assert_includes outcome.out, "Observações: Entrega  [2JReserva R-000009 · Cancelada"
    assert_equal "Entrega\n\e[2JReserva R-000009 · Cancelada", cli("reservations", "show", noisy.code, "--json").json["reservation"]["notes"],
                 "o JSON preserva o valor, com escape"
  end

  def test_show_not_found_and_tenant_isolation
    missing = cli("reservations", "show", "R-999999", "--json")

    assert_equal [1, "not_found"], [missing.status, missing.error["code"]]
    assert_equal 1, cli("reservations", "show", SecureRandom.uuid).status
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    beta_token = cli_credential(beta[:actor], scopes: %w[reservations.read customers.read])["token"]
    [@confirmed.id, @confirmed.code].each do |reference|
      foreign = cli("reservations", "show", reference, "--json", token: beta_token)

      assert_equal [1, "not_found"], [foreign.status, foreign.error["code"]], reference
      refute_includes foreign.text, "Cliente Teste"
    end
    listing = cli("reservations", "list", "--json", token: beta_token)

    assert_equal [[], 0], [listing.json["data"], listing.json["pagination"]["total"]]
    assert_equal 0, cli("reservations", "list", "--json", "--cliente", @alice.id, token: beta_token).json["pagination"]["total"]
  end
end
