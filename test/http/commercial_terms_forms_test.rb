# frozen_string_literal: true

require_relative "commercial_terms_http_helper"

# Tarifas e cupom nos formulários de reserva e orçamento (Rack::Lint): valor padrão, ajuste somente com
# permissão, tarifa avulsa, continuidade das tarifas na nova versão do orçamento e detalhamento de valores
# nas páginas da reserva, do orçamento e do contrato.
class CommercialTermsFormsTest < CommercialTermsHttpTest
  DENIED = "valor diferente do padrão ou tarifa avulsa exige a permissão de ajustar tarifas (gerente, administrador ou proprietário)"

  def setup
    super
    @fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
  end

  def quote_form(**extra)
    { "cliente_id" => @customer.id, "filial_id" => @branch.id, "inicio" => "2026-03-10T09:00", "fim" => "2026-03-12T09:00",
      "validade" => "2026-03-06T18:00", "produto" => [@camera.id], "quantidade" => ["1"], "politica_bloqueio" => "none" }
      .merge(extra.transform_keys(&:to_s))
  end

  def last_quote_id = owner_query("SELECT id FROM quotes ORDER BY created_at DESC, code DESC LIMIT 1").first["id"]
  def current_fees(quote_id) = uc(:get_quote).call(@actor, quote_id)[:current].pricing["fees"]

  def test_reservation_with_catalog_fee_coupon_and_negotiated_agreement
    create_agreement(@customer, 800)
    coupon = create_coupon("TESTE10")
    form = get_ok("/reservas/nova")

    assert_includes form, %(<fieldset class="full" data-line-group="itens">)
    refute_includes form, "Variáveis: @fees", "comentários dos templates não chegam à página"
    assert_includes form, %(<fieldset class="full" data-line-group="tarifas">)
    assert_includes form, "Entrega e retirada no local · R$ 150,00"
    assert_includes form, %(placeholder="padrão")
    assert_includes form, %(aria-describedby="ajuda-cupom")
    assert_includes form, "Cupons valem para reservas, não para orçamentos."
    assert_includes form, %(href="/cupons?situacao=active")
    post_form "/reservas", reservation_form(tarifa_id: [@fee.id], tarifa_valor: [""], cupom: "teste10")

    assert_equal 303, last_response.status, last_response.body[0, 600]
    follow_redirect!
    page = last_response.body

    assert_match(%r{<dt>Subtotal</dt>\s*<dd>R\$ 828,00<br><span class="muted">o subtotal já considera a condição negociada \(−R\$ 72,00\)</span></dd>}, page)
    assert_includes page, %(<dt>Cupom <a href="/cupons/#{coupon.id}">TESTE10</a> (10%)</dt>)
    assert_includes page, "<dd>−R$ 82,80</dd>"
    assert_match(%r{<dt>Entrega e retirada no local</dt>\s*<dd>R\$ 150,00</dd>}, page)
    assert_includes page, "<dt>Total contratado</dt><dd><strong>R$ 895,20</strong></dd>"
    assert_includes page, "<td>−8% (−R$ 72,00)</td>"
    refute_includes page, "valor ajustado"
    assert_equal "1 (sem limite)", usage("TESTE10")
  end

  def test_attendant_applies_the_default_value_and_cannot_adjust_it
    sign_in_as("attendant")
    form = get_ok("/reservas/nova")

    assert_includes form, "Tarifas são aplicadas pelo valor padrão."
    assert_includes form, %(<input type="hidden" name="tarifa_valor[]" value="">)
    refute_includes form, %(placeholder="padrão")
    refute_includes form, "Tarifas avulsas"
    post_form "/reservas", reservation_form(tarifa_id: [@fee.id], tarifa_valor: ["200,00"], observacoes: "Entregar pela manhã")

    assert_equal 422, last_response.status
    assert_includes last_response.body, "<li>#{DENIED}: Entrega e retirada no local R$ 200,00 (padrão R$ 150,00)</li>"
    assert_includes last_response.body, %(<option value="#{@customer.id}" selected>)
    assert_includes last_response.body, %(name="tarifa_valor[]" value="200,00")
    assert_includes last_response.body, ">Entregar pela manhã</textarea>"
    post_form "/reservas", reservation_form(avulsa_descricao: ["Taxa de estacionamento"], avulsa_valor: ["30,00"])

    assert_equal 422, last_response.status
    assert_includes last_response.body, "#{DENIED}: Taxa de estacionamento R$ 30,00 (avulsa)"
    assert_empty owner_query("SELECT 1 FROM reservations")
    post_form "/reservas", reservation_form(tarifa_id: [@fee.id], tarifa_valor: [""])

    assert_equal 303, last_response.status, last_response.body[0, 600]
    assert_equal 15_000, summary_of(Struct.new(:id).new(last_reservation_id))["fees_cents"]
  end

  def test_manager_adjusts_values_and_adds_custom_fees_within_the_role_limit
    sign_in_as("manager")

    assert_includes get_ok("/reservas/nova"), %(<fieldset class="full" data-line-group="avulsas">)
    post_form "/reservas", reservation_form(avulsa_descricao: ["Taxa de estacionamento"], avulsa_valor: [""])

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-tarifas" role="alert">informe descrição e valor da tarifa avulsa)
    assert_includes last_response.body, %(value="Taxa de estacionamento")
    assert_includes last_response.body, "<li>Tarifas adicionais: "
    post_form "/reservas", reservation_form(tarifa_id: [@fee.id], tarifa_valor: ["abc"])

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-tarifas" role="alert">formato monetário inválido)
    post_form "/reservas", reservation_form(tarifa_id: [@fee.id], tarifa_valor: ["100,00"])

    assert_equal 422, last_response.status
    assert_includes last_response.body, "redução da tarifa ENTREGA acima do limite autorizado para o papel (20%)"
    post_form "/reservas", reservation_form(tarifa_id: ["", @fee.id], tarifa_valor: ["", "200,00"],
                                            avulsa_descricao: ["", "Taxa de estacionamento"], avulsa_valor: ["", "30,00"])

    assert_equal 303, last_response.status, last_response.body[0, 600]
    follow_redirect!

    assert_includes last_response.body, %(<dt>Entrega e retirada no local <span class="muted">(valor ajustado; padrão R$ 150,00)</span></dt>)
    assert_includes last_response.body, %(<dt>Taxa de estacionamento <span class="muted">(avulsa)</span></dt>)
    assert_includes last_response.body, "<strong>R$ 1.130,00</strong>"
    assert_equal([20_000, 3_000], audit_events("reservation.created").last["details"]["fee_overrides"].map { |entry| entry["amount_cents"] })
  end

  def test_form_without_active_fees_points_to_the_catalog
    uc(:set_fee_active).call(@actor, @fee.id, active: false)
    form = get_ok("/reservas/nova")

    assert_includes form, "Nenhuma tarifa ativa."
    assert_includes form, %(<a href="/tarifas/nova">Cadastrar tarifa</a>)
    refute_includes form, "Adicionar tarifa</button>"
    assert_includes get_ok("/orcamentos/novo"), "Nenhuma tarifa ativa."
    sign_in_as("attendant")

    refute_includes get_ok("/reservas/nova"), "Cadastrar tarifa"
  end

  def test_quote_with_fees_shows_the_breakdown_and_converts_with_the_same_values
    create_agreement(@customer, 800)

    assert_includes get_ok("/orcamentos/novo"), "Entrega e retirada no local · R$ 150,00"
    post_form "/orcamentos", quote_form(tarifa_id: [@fee.id], tarifa_valor: ["200,00"], avulsa_descricao: ["Taxa de estacionamento"],
                                        avulsa_valor: ["30,00"])

    assert_equal 303, last_response.status, last_response.body[0, 600]
    follow_redirect!
    page = last_response.body

    assert_includes page, "o subtotal já considera a condição negociada (−R$ 72,00)"
    assert_includes page, "(valor ajustado; padrão R$ 150,00)"
    assert_includes page, %(<dt>Taxa de estacionamento <span class="muted">(avulsa)</span></dt>)
    assert_includes page, "<td>−8% (−R$ 72,00)</td>"
    assert_includes page, "<dt>Total</dt><dd><strong>R$ 1.058,00</strong></dd>"
    assert_equal 2, audit_events("quote.created").first["details"]["fee_overrides"].size
    create_coupon("TESTE10")
    reservation = reserve(@actor, @customer, @branch, rental(20), [line(@camera, 1)], mode: "confirm", fees: [catalog_fee(@fee)], coupon_code: "TESTE10")
    contract = uc(:issue_contract).call(@actor, reservation.id)
    body = get_ok("/contratos/#{contract.id}")

    assert_includes body, "<h3>Valores na emissão</h3>"
    assert_includes body, "condição negociada −8% (−R$ 72,00)"
    assert_match(%r{<dt>Entrega e retirada no local</dt>\s*<dd>R\$ 150,00</dd>}, body)
    assert_includes body, "TESTE10</a> (10%)</dt>"
    assert_includes body, "<dt>Total</dt><dd><strong>R$ 895,20</strong></dd>"
  end

  def test_attendant_revises_a_quote_keeping_the_fees_authorized_by_the_manager
    assembly = create_fee("MONTAGEM", "Montagem e desmontagem", 25_000)
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, lines: [line(@camera, 1)], period: rental,
                                             valid_until: t("2026-03-06T21:00:00Z"),
                                             fees: [catalog_fee(@fee, 20_000), catalog_fee(assembly), custom_fee("Taxa de estacionamento", 3_000)] })
    uc(:set_fee_active).call(@actor, assembly.id, active: false)

    assert_match(/id="tarifa-valor-0"[^>]*value="200,00"/, get_ok("/orcamentos/#{quote.id}/nova-versao"), "quem pode ajustar edita o valor")
    sign_in_as("attendant")
    form = get_ok("/orcamentos/#{quote.id}/nova-versao")

    assert_includes form, %(<input type="hidden" name="tarifa_id[]" value="#{@fee.id}"><input type="hidden" name="tarifa_valor[]" value="200,00">)
    assert_match(%r{Entrega e retirada no local · R\$ 200,00\s*<span class="muted">\(valor ajustado; padrão R\$ 150,00\)</span>}, form)
    assert_includes form, %(name="avulsa_descricao[]" value="Taxa de estacionamento"><input type="hidden" name="avulsa_valor[]" value="30,00">)
    assert_includes form, %(<option value="#{assembly.id}" selected>Montagem e desmontagem (inativa)</option>)
    assert_includes form, "data-remove-kept"
    kept = { tarifa_id: [@fee.id, assembly.id], tarifa_valor: ["200,00", ""], avulsa_descricao: ["Taxa de estacionamento"], avulsa_valor: ["30,00"] }
    post_form "/orcamentos/#{quote.id}/versoes", quote_form(**kept, tarifa_valor: ["180,00", ""])

    assert_equal 422, last_response.status
    assert_includes last_response.body, "#{DENIED}: Entrega e retirada no local R$ 180,00 (padrão R$ 150,00)"
    assert_includes last_response.body, %(name="tarifa_valor[]" value="180,00")
    post_form "/orcamentos/#{quote.id}/versoes", quote_form(**kept, avulsa_descricao: ["Taxa de estacionamento"] * 3, avulsa_valor: ["30,00"] * 3)

    assert_equal 422, last_response.status, "cada tarifa mantida vale uma vez; as cópias são ajustes novos"
    assert_includes last_response.body, "#{DENIED}: Taxa de estacionamento R$ 30,00 (avulsa); Taxa de estacionamento R$ 30,00 (avulsa)"
    post_form "/orcamentos/#{quote.id}/versoes", quote_form(**kept, condicoes: "Entrega no período da manhã")

    assert_equal 303, last_response.status, last_response.body[0, 600]
    assert_equal([[20_000, "catalog"], [25_000, "catalog"], [3_000, "custom"]],
                 current_fees(quote.id).map { |fee| fee.values_at("amount_cents", "source") })
    refute audit_events("quote.revised").first["details"].key?("fee_overrides")
    assert_equal 2, uc(:get_quote).call(@actor, quote.id)[:quote].current_version
  end

  # As tarifas mantidas aparecem como valor (com separador de milhar); o campo oculto guarda o texto do
  # formulário.
  def test_kept_fees_are_displayed_as_money_values
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, lines: [line(@camera, 1)], period: rental,
                                             valid_until: t("2026-03-06T21:00:00Z"),
                                             fees: [catalog_fee(@fee, 160_000), custom_fee("Taxa de palco <i>", 123_456)] })
    sign_in_as("attendant")
    form = get_ok("/orcamentos/#{quote.id}/nova-versao")

    assert_includes form, %(<input type="hidden" name="tarifa_valor[]" value="1600,00">)
    assert_match(%r{Entrega e retirada no local · R\$ 1\.600,00\s*<span class="muted">\(valor ajustado; padrão R\$ 150,00\)</span>}, form)
    assert_includes form, "Taxa de palco &lt;i&gt; · R$ 1.234,56 <span class=\"muted\">(avulsa)</span>"
    refute_includes form, "R$ 1600,00"
    post_form "/orcamentos/#{quote.id}/versoes", quote_form(tarifa_id: [@fee.id], tarifa_valor: ["1.600,0x"])

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Entrega e retirada no local · R$ 1.600,0x", "texto inválido reexibido como veio"
  end
end
