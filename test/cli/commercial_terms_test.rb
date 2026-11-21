# frozen_string_literal: true

require_relative "cli_helper"
require_relative "../support/commercial_terms_support"

# Comandos de condições comerciais: cupons (consulta, cadastro, desativação e reativação), tarifas
# (consulta) e condições negociadas (consulta, cadastro e encerramento), em saída humana e JSON, com
# os códigos de saída, as permissões, a auditoria e o isolamento da aplicação.
class CliCommercialTermsTest < CliTest
  include CommercialTermsSupport

  SCOPES = %w[coupons.read coupons.write fees.read price_agreements.read price_agreements.write reservations.read customers.read
              catalog.read].freeze
  COUPON_KEYS = %w[id code description kind discount_bps discount valid_from valid_until max_redemptions redemptions total_redemptions
                   remaining min_subtotal active status lock_version created_at updated_at].freeze
  REDEMPTION_KEYS = %w[id reservation_id reservation_code customer_name subtotal discount redeemed_at state released_at].freeze
  FEE_KEYS = %w[id code name description default_amount active status lock_version created_at updated_at].freeze
  AGREEMENT_KEYS = %w[id customer_id scope product_id discount_bps valid_from valid_until notes ended_at end_reason status created_at].freeze
  PAGE = { "limit" => 25, "offset" => 0, "total" => 2, "next_offset" => nil }.freeze

  def setup
    super
    catalog_setup
    @customer = create_customer(@actor)
    @credential = cli_credential(@actor, scopes: SCOPES, name: "Condições comerciais")
    @token = @credential["token"]
  end

  def limited(*scopes) = cli_credential(@actor, scopes: scopes, name: "Limitada #{scopes.join(" ")}")["token"]

  def ok(*argv, **)
    outcome = cli(*argv, **)

    assert_equal 0, outcome.status, "#{argv.inspect}: #{outcome.err}"
    assert_no_secret(outcome, @token)
    outcome
  end

  def failed(status, code, *argv, **)
    outcome = cli(*argv, "--json", **)

    assert_equal [status, code], [outcome.status, outcome.error["code"]], "#{argv.inspect}: #{outcome.err}"
    assert_no_secret(outcome, @token)
    outcome.error
  end

  def test_coupons_create_and_list_in_human_output
    created = ok("coupons", "create", "--codigo", "bemvindo10", "--tipo", "percent", "--valor", "12,5", "--descricao", "Boas-vindas",
                 "--fim-vigencia", "2026-12-01", "--maximo-usos", "100", "--subtotal-minimo", "300,00")

    ["Cupom BEMVINDO10 cadastrado.", "Desconto: 12,5% (percentual)", "Vigência: até 01/12/2026 00:00 (America/Sao_Paulo)",
     "Usos ativos: 0 de 100; restantes: 100 · total de usos: 0", "Subtotal mínimo: R$ 300,00", "Descrição: Boas-vindas",
     "Consultar: bin/locentra coupons show BEMVINDO10"].each { |line| assert_includes created.out, line }
    audit = audit_rows("coupon.created").first

    assert_equal ["cli", @credential["id"]], audit.values_at("actor_type", "actor_id")
    assert audit["request_id"]
    ok("coupons", "create", "--codigo", "FIXO50", "--tipo", "fixed", "--valor", "50,00", "--inicio-vigencia", "2026-04-01T00:00",
       "--fim-vigencia", "2026-05-01T03:00:00Z")
    lines = ok("coupons", "list").out.lines.map(&:rstrip)

    assert_match(/^Código\s+Descrição\s+Desconto\s+Vigência\s+Usos\s+Subtotal mínimo\s+Situação$/, lines.first)
    assert_match(%r{^BEMVINDO10\s+Boas-vindas\s+12,5%\s+até 01/12/2026 00:00\s+0 de 100\s+R\$ 300,00\s+Vigente$}, lines[2])
    assert_match(%r{^FIXO50\s+—\s+R\$ 50,00\s+desde 01/04/2026 00:00 até 01/05/2026 00:00\s+0 \(sem limite\)\s+—\s+Agendado$}, lines[3])
    assert_equal "Exibindo 1–2 de 2 (horários em America/Sao_Paulo).", lines.last
    assert_includes ok("coupons", "list", "--limite", "1").out, "Exibindo 1–1 de 2 (horários em America/Sao_Paulo). Próxima página: --deslocamento 1."
    assert_includes ok("coupons", "list", "--situacao", "inactive").out, "Nenhum cupom encontrado."
    assert_includes ok("coupons", "show", "FIXO50").out.lines.map(&:rstrip), "Subtotal mínimo: —", "sem mínimo, como na listagem"
  end

  def test_coupons_json_has_the_api_fields_and_filters
    ok("coupons", "create", "--codigo", "bemvindo10", "--tipo", "percent", "--valor", "10", "--maximo-usos", "100", "--json")
    fixed = ok("coupons", "create", "--codigo", "FIXO50", "--tipo", "fixed", "--valor", "50,00", "--inicio-vigencia", "2026-04-01T00:00",
               "--fim-vigencia", "2026-05-01T03:00:00Z", "--json").json

    assert_equal %w[coupon], fixed.keys
    assert_equal COUPON_KEYS, fixed["coupon"].keys
    assert_equal ["FIXO50", "fixed", nil, D::Money.new(5000).to_h, "2026-04-01T03:00:00Z", "2026-05-01T03:00:00Z", "scheduled"],
                 fixed["coupon"].values_at("code", "kind", "discount_bps", "discount", "valid_from", "valid_until", "status")
    listing = ok("coupons", "list", "--json").json

    assert_equal [%w[data pagination], PAGE, COUPON_KEYS], [listing.keys, listing["pagination"], listing["data"].first.keys]
    assert_equal [%w[BEMVINDO10 FIXO50], [1000, nil], [100, nil]],
                 [listing["data"].map { |row| row["code"] }, listing["data"].map { |row| row["discount_bps"] },
                  listing["data"].map { |row| row["remaining"] }]
    codes = ->(*filters) { ok("coupons", "list", "--json", *filters).json["data"].map { |row| row["code"] } }

    assert_equal [%w[FIXO50], %w[BEMVINDO10], %w[FIXO50 BEMVINDO10], %w[FIXO50]],
                 [codes.call("--situacao", "scheduled"), codes.call("--busca", "bem"), codes.call("--ordem=valid_until"),
                  codes.call("--limite", "1", "--deslocamento", "1")]
    shown = ok("coupons", "show", fixed["coupon"]["id"], "--json").json

    assert_equal [%w[coupon redemptions], fixed["coupon"], [], 0],
                 [shown.keys, shown["coupon"], shown["redemptions"]["data"], shown["redemptions"]["pagination"]["total"]]
  end

  def test_coupon_show_lists_redemptions_according_to_scopes
    create_coupon("BEMVINDO10", description: "Boas-vindas")
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z"), [line(@camera, 1)],
                          mode: "confirm", coupon_code: "bemvindo10")
    shown = ok("coupons", "show", "bemvindo10").out

    ["Cupom BEMVINDO10 · Vigente", "Desconto: 10% (percentual)", "Vigência: sem prazo (America/Sao_Paulo)",
     "Usos ativos: 1 (sem limite) · total de usos: 1", "Desativar: bin/locentra coupons deactivate BEMVINDO10"].each do |line|
      assert_includes shown, line
    end
    assert_match(%r{^#{reservation.code}\s+Cliente Teste\s+R\$ 200,00\s+R\$ 20,00\s+02/03/2026 09:00\s+Ativo$}, shown)
    row = ok("coupons", "show", "BEMVINDO10", "--json").json["redemptions"]["data"].first

    assert_equal REDEMPTION_KEYS, row.keys
    assert_equal [reservation.id, reservation.code, "Cliente Teste", 20_000, 2000, "2026-03-02T12:00:00Z", "active", nil],
                 [*row.values_at("reservation_id", "reservation_code", "customer_name"), row["subtotal"]["amount_cents"],
                  row["discount"]["amount_cents"], *row.values_at("redeemed_at", "state", "released_at")]
    reader = limited("coupons.read")

    assert_equal REDEMPTION_KEYS - %w[reservation_id reservation_code customer_name],
                 ok("coupons", "show", "BEMVINDO10", "--json", token: reader).json["redemptions"]["data"].first.keys
    hidden = ok("coupons", "show", "BEMVINDO10", token: reader).out

    refute_includes hidden, "Cliente Teste"
    refute_includes hidden, reservation.code
    assert_match(%r{^—\s+—\s+R\$ 200,00\s+R\$ 20,00\s+02/03/2026 09:00\s+Ativo$}, hidden)
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "desistência")
    released = ok("coupons", "show", "BEMVINDO10").out

    assert_includes released, "Usos ativos: 0 (sem limite) · total de usos: 1"
    assert_includes released, "Liberado: reserva cancelada em 02/03/2026 09:00"
  end

  def test_coupon_deactivation_and_reactivation
    create_coupon("BEMVINDO10")
    off = ok("coupons", "deactivate", "bemvindo10").out

    assert_includes off, "Cupom BEMVINDO10 desativado. Reservas já registradas não mudam."
    assert_includes off, "Reativar: bin/locentra coupons reactivate BEMVINDO10"
    assert_equal ["cli", @credential["id"]], audit_rows("coupon.deactivated").first.values_at("actor_type", "actor_id")
    again = ok("coupons", "deactivate", "BEMVINDO10", "--json").json

    assert_equal [%w[coupon changed], false, "inactive", COUPON_KEYS], [again.keys, again["changed"], again["coupon"]["status"], again["coupon"].keys]
    assert_includes ok("coupons", "deactivate", "BEMVINDO10").out, "O cupom BEMVINDO10 já estava desativado; nenhuma alteração."
    assert_equal 1, audit_rows("coupon.deactivated").size, "operação nula não é auditada"
    assert_includes ok("coupons", "show", "BEMVINDO10").out, "Cupom BEMVINDO10 · Desativado"
    on = ok("coupons", "reactivate", "BEMVINDO10", "--json").json

    assert_equal [true, "active", true], [on["changed"], on["coupon"]["status"], on["coupon"]["active"]]
    assert_includes ok("coupons", "reactivate", "BEMVINDO10").out, "O cupom BEMVINDO10 já estava ativo; nenhuma alteração."
    assert_equal 1, audit_rows("coupon.reactivated").size
  end

  def test_fees_list_and_show
    entrega = create_fee("ENTREGA", "Entrega e retirada no local", 15_000, description: "Até 30 km")
    montagem = create_fee("MONTAGEM", "Montagem e desmontagem", 25_000)
    uc(:set_fee_active).call(@actor, montagem.id, active: false)
    lines = ok("fees", "list").out.lines.map(&:rstrip)

    assert_match(/^Código\s+Nome\s+Valor padrão\s+Situação$/, lines.first)
    assert_match(/^ENTREGA\s+Entrega e retirada no local\s+R\$ 150,00\s+Ativa$/, lines[2])
    assert_match(/^MONTAGEM\s+Montagem e desmontagem\s+R\$ 250,00\s+Inativa$/, lines[3])
    assert_equal "Exibindo 1–2 de 2 (horários em America/Sao_Paulo).", lines.last
    listing = ok("fees", "list", "--json").json

    assert_equal [%w[data pagination], PAGE, FEE_KEYS, %w[ENTREGA MONTAGEM]],
                 [listing.keys, listing["pagination"], listing["data"].first.keys, listing["data"].map { |row| row["code"] }]
    codes = ->(*filters) { ok("fees", "list", "--json", *filters).json["data"].map { |row| row["code"] } }

    assert_equal [%w[MONTAGEM], %w[ENTREGA], %w[MONTAGEM]],
                 [codes.call("--situacao", "inactive"), codes.call("--busca", "entr"), codes.call("--limite", "1", "--deslocamento", "1")]
    assert_includes ok("fees", "list", "--busca", "inexistente").out, "Nenhuma tarifa encontrada."
    shown = ok("fees", "show", "entrega").out

    ["Tarifa ENTREGA · Ativa", "Nome: Entrega e retirada no local", "Valor padrão: R$ 150,00", "Descrição: Até 30 km"].each do |line|
      assert_includes shown, line
    end
    data = ok("fees", "show", entrega.id, "--json").json

    assert_equal [%w[fee], FEE_KEYS, "ENTREGA", D::Money.new(15_000).to_h], [data.keys, data["fee"].keys, data["fee"]["code"], data["fee"]["default_amount"]]
  end

  def test_agreements_create_list_and_end
    created = ok("agreements", "create", "--cliente", @customer.id, "--desconto", "8", "--observacoes", "Contrato anual").out

    assert_includes created, "Condição negociada cadastrada (vigente): 8% em todos os produtos."
    assert_includes created, "Vigência: desde 02/03/2026 09:00 (America/Sao_Paulo)"
    assert_equal ["cli", @credential["id"]], audit_rows("price_agreement.created").first.values_at("actor_type", "actor_id")
    product = ok("agreements", "create", "--cliente", @customer.id, "--desconto", "12,5", "--produto", "cam-cli", "--inicio-vigencia", "2026-04-01",
                 "--fim-vigencia", "2026-05-01T00:00", "--json").json

    assert_equal [%w[agreement], AGREEMENT_KEYS], [product.keys, product["agreement"].keys]
    assert_equal ["product", @camera.id, 1250, "2026-04-01T03:00:00Z", "2026-05-01T03:00:00Z", "scheduled"],
                 product["agreement"].values_at("scope", "product_id", "discount_bps", "valid_from", "valid_until", "status")
    listing = ok("agreements", "list", "--cliente", @customer.id, "--json").json
    general = listing["data"].last

    assert_equal [PAGE, { "sku" => "CAM-CLI", "name" => "Câmera CLI" }, AGREEMENT_KEYS, ["general", 800, "Contrato anual", "active"]],
                 [listing["pagination"], listing["data"].first["product"], general.keys, general.values_at("scope", "discount_bps", "notes", "status")]
    scheduled = ok("agreements", "end", general["id"], "--motivo", "Troca de tabela", "--encerrar-em", "2026-04-01T00:00").out

    assert_includes scheduled, "Encerramento agendado para 01/04/2026 00:00 (America/Sao_Paulo)."
    assert_includes scheduled, "Motivo: Troca de tabela"
    ended = audit_rows("price_agreement.ended").first

    assert_equal ["cli", true], [ended["actor_type"], JSON.parse(ended["details"])["scheduled"]]
    human = ok("agreements", "list", "--cliente", @customer.id).out

    assert_match(/^Id\s+Escopo\s+Desconto\s+Vigência\s+Situação\s+Observações$/, human.lines.first.rstrip)
    assert_match(%r{^#{product["agreement"]["id"]}\s+Câmera CLI \(CAM-CLI\)\s+12,5%\s+desde 01/04/2026 00:00 até 01/05/2026 00:00\s+Agendada\s+—$}, human)
    scheduled_status = Regexp.escape("Vigente (encerramento agendado para 01/04/2026 00:00)")

    assert_match(%r{^#{general["id"]}\s+Todos os produtos\s+8%\s+desde 02/03/2026 09:00\s+#{scheduled_status}\s+Contrato anual$}, human)
    now = ok("agreements", "end", product["agreement"]["id"], "--motivo", "Fim da parceria", "--json").json["agreement"]

    assert_equal ["2026-03-02T12:00:00Z", "Fim da parceria", "ended"], now.values_at("ended_at", "end_reason", "status")
    assert_includes ok("agreements", "list", "--cliente", @customer.id, token: limited("price_agreements.read")).out, "Produto #{@camera.id}"
  end

  def test_conflicts_are_unavailable_exit
    create_coupon("BEMVINDO10")
    general = create_agreement(@customer, 800)

    failed(69, "coupon_code_taken", "coupons", "create", "--codigo", "BemVindo10", "--tipo", "percent", "--valor", "10")
    failed(69, "price_agreement_overlap", "agreements", "create", "--cliente", @customer.id, "--desconto", "5")
    ok("agreements", "end", general.id, "--motivo", "Encerramento")
    failed(69, "invalid_transition", "agreements", "end", general.id, "--motivo", "De novo")
    human = cli("agreements", "end", general.id, "--motivo", "De novo")

    assert_equal 69, human.status
    assert_includes human.err, "erro: Transição inválida em condição negociada: Encerrada → Encerrada"
  end

  def test_validation_and_missing_resources_are_business_errors
    coupon = %w[coupons create --codigo NOVO10 --tipo percent]
    { [*coupon, "--valor", "abc"] => "valor", [*coupon, "--valor", "12,555"] => "valor", [*coupon, "--valor", "0"] => "valor",
      %w[coupons create --codigo NOVO10 --tipo outro --valor 10] => "tipo", %w[coupons create --codigo NOVO10 --tipo fixed --valor dez] => "valor",
      %w[coupons create --codigo x --tipo fixed --valor 10] => "codigo", [*coupon, "--valor", "10", "--fim-vigencia", "2026-02-30"] => "valido_ate",
      [*coupon, "--valor", "10", "--fim-vigencia", "2026-03-01"] => "valido_ate", [*coupon, "--valor", "10", "--inicio-vigencia", "ontem"] => "valido_de",
      [*coupon, "--valor", "10", "--subtotal-minimo", "muito"] => "subtotal_minimo", [*coupon, "--valor", "10", "--maximo-usos", "abc"] => "maximo_usos",
      %w[coupons list --situacao apagado] => "situacao", %w[coupons list --ordem=valor] => "ordenacao", %w[fees list --situacao apagada] => "situacao",
      ["agreements", "create", "--cliente", @customer.id, "--desconto", "95"] => "desconto",
      ["agreements", "create", "--cliente", @customer.id, "--desconto", "oito"] => "desconto",
      ["agreements", "create", "--cliente", "abc", "--desconto", "8"] => "cliente" }.each do |argv, field|
      error = failed(1, "validation_error", *argv)

      assert_includes error["details"]["fields"].keys, field, argv.inspect
    end
    [%w[coupons show INEXISTENTE], %w[coupons deactivate INEXISTENTE], %w[fees show X9], ["agreements", "list", "--cliente", SecureRandom.uuid],
     ["agreements", "create", "--cliente", @customer.id, "--desconto", "8", "--produto", "SEM-SKU"],
     ["agreements", "end", SecureRandom.uuid, "--motivo", "Inexistente"]].each { |argv| failed(1, "not_found", *argv) }

    assert_empty owner_query("SELECT id FROM coupons")
    assert_empty owner_query("SELECT id FROM customer_price_agreements")
  end

  def test_missing_scopes_are_denied_and_usage_errors_are_reported
    create_coupon("BEMVINDO10")
    reader = limited("coupons.read", "fees.read", "price_agreements.read")
    [%w[coupons create --codigo NOVO10 --tipo percent --valor 10], %w[coupons deactivate BEMVINDO10], %w[coupons reactivate BEMVINDO10],
     ["agreements", "create", "--cliente", @customer.id, "--desconto", "8"],
     ["agreements", "end", SecureRandom.uuid, "--motivo", "Sem escopo"]].each { |argv| failed(77, "forbidden", *argv, token: reader) }
    other = limited("reservations.read")
    [%w[coupons list], %w[coupons show BEMVINDO10], %w[fees list], %w[fees show ENTREGA], ["agreements", "list", "--cliente", @customer.id]].each do |argv|
      failed(77, "forbidden", *argv, token: other)
    end

    assert_equal [1, 0], [owner_query("SELECT id FROM coupons WHERE active").size, audit_rows("coupon.deactivated").size]
    [%w[coupons], %w[coupons apagar], %w[coupons show], %w[coupons list --opcao], %w[coupons create --codigo NOVO10], %w[coupons list extra],
     %w[fees], %w[fees show], %w[agreements list], %w[agreements create --desconto 8], ["agreements", "end", SecureRandom.uuid],
     %w[agreements end --motivo Sem-identificador]].each do |argv|
      outcome = cli(*argv)

      assert_equal 64, outcome.status, argv.inspect
      assert_includes outcome.err, "erro:", argv.inspect
    end
    assert_includes cli("coupons", "create", "--codigo", "NOVO10").err, "informe --tipo e --valor"
    assert_includes cli("agreements", "list").err, "informe --cliente"
    assert_includes cli("agreements", "end", SecureRandom.uuid).err, "informe --motivo"
  end

  def test_tenant_isolation
    coupon = create_coupon("BEMVINDO10")
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    agreement = create_agreement(@customer, 800)
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    foreign = cli_credential(beta[:actor], scopes: SCOPES)["token"]
    [["coupons", "show", coupon.id], %w[coupons show BEMVINDO10], %w[coupons deactivate BEMVINDO10], ["fees", "show", fee.id], %w[fees show ENTREGA],
     ["agreements", "list", "--cliente", @customer.id], ["agreements", "create", "--cliente", @customer.id, "--desconto", "5"],
     ["agreements", "end", agreement.id, "--motivo", "Outra organização"]].each { |argv| failed(1, "not_found", *argv, token: foreign) }
    listing = cli("coupons", "list", "--json", token: foreign)

    assert_equal [0, [], 0], [listing.status, listing.json["data"], listing.json["pagination"]["total"]]
    assert_equal ["active", nil], [coupon_data("BEMVINDO10")[:status], uc(:list_price_agreements).call(@actor, @customer.id).items.first[:agreement].ended_at]
  end

  def test_help_lists_the_commands_and_options
    general = cli("--help", token: nil).out

    ["coupons create", "coupons deactivate CÓDIGO|ID", "fees list", "agreements end ID"].each { |usage| assert_includes general, usage }
    assert_includes cli("coupons", "--help", token: nil).out, "coupons reactivate CÓDIGO|ID"
    help = cli("coupons", "create", "--help", token: nil).out

    ["--codigo CÓDIGO", "--tipo TIPO", "--valor VALOR", "--inicio-vigencia INSTANTE", "--fim-vigencia INSTANTE", "--maximo-usos N",
     "--subtotal-minimo VALOR"].each { |option| assert_includes help, option }
    assert_includes cli("agreements", "end", "--help", token: nil).out, "--encerrar-em INSTANTE"
  end
end
