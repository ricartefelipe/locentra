# frozen_string_literal: true

require_relative "browser_helper"

# Condições comerciais no navegador, sem erros de console nem violações de CSP: fluxo principal (cadastro
# de cupom e de tarifa, condição negociada na página do cliente, reserva com tarifa e cupom pelo módulo
# de linhas e conferência dos valores e dos usos) e nova versão de orçamento por atendente, que mantém
# ou remove as tarifas autorizadas na versão anterior.
class CommercialTermsBrowserTest < BrowserTest
  FEES = '[data-line-group="tarifas"]'
  Money = Locentra::Domain::Money
  FeeRequest = Locentra::Domain::Pricing::FeeRequest

  def setup
    super
    seed_tenants
  end

  def fee_lines = @page.css("#{FEES} [data-lines] [data-line]")

  def submit(action) = navigating { click("form[action='#{action}'] button[type=submit]") }

  def test_coupon_fee_and_negotiated_condition_reach_the_reservation
    login_as("dona@alfa.test", organization: "Locadora Alfa")
    coupon_path = register_coupon
    register_fee
    register_agreement
    reserve_with_fee_and_coupon

    assert_match %r{\A/reservas/\h{8}-}, current_path
    assert_includes text_of("[data-flash]"), "registrada (Bloqueio temporário)"
    assert_includes body_text, "−5% (−R$ 20,00)"
    assert_includes body_text, "o subtotal já considera a condição negociada (−R$ 20,00)"
    assert_includes body_text, "Cupom TESTE10"
    assert_includes body_text, "−R$ 38,00"
    assert_includes body_text, "Entrega e retirada no local"
    assert_includes body_text, "R$ 492,00"
    code = owner_query("SELECT code FROM reservations").first["code"]
    visit coupon_path

    assert_includes body_text, "1 (sem limite)"
    assert_includes text_of("#usos table"), code
    assert_includes text_of("#usos table"), "Marina Souza"
    assert_clean_console
  end

  def test_attendant_keeps_or_removes_the_fees_of_the_previous_quote_version
    quote = quote_with_adjusted_fees
    attendant("atendente@alfa.test")
    login_as("atendente@alfa.test")
    visit "/orcamentos/#{quote.id}/nova-versao"
    kept = -> { @page.css("#{FEES} [data-kept-line]") }

    assert_equal 2, kept.call.size
    assert_includes kept.call.first.text, "Entrega e retirada no local · R$ 200,00"
    assert_nil @page.at_css("#{FEES} input[name='tarifa_valor[]']:not([type=hidden])"), "sem a permissão de ajuste não há campo de valor"
    press(kept.call.last.at_css("[data-remove-kept]"))
    wait_until("tarifa avulsa removida") { kept.call.size == 1 }
    submit("/orcamentos/#{quote.id}/versoes")

    assert_equal "/orcamentos/#{quote.id}", current_path
    assert_includes text_of("[data-flash]"), "Versão 2 criada."
    assert_includes body_text, "Entrega e retirada no local"
    refute_includes body_text, "Taxa de estacionamento"
    fees = uc(:get_quote).call(@actor, quote.id)[:current].pricing["fees"]

    assert_equal([[20_000, "catalog"]], fees.map { |fee| fee.values_at("amount_cents", "source") })
    assert_clean_console
  end

  private

  def quote_with_adjusted_fees
    fee = uc(:create_fee).call(@actor, { code: "ENTREGA", name: "Entrega e retirada no local", default_amount: Money.new(15_000) })
    fees = [FeeRequest.catalog(fee_id: fee.id, amount: Money.new(20_000)),
            FeeRequest.custom(description: "Taxa de estacionamento", amount: Money.new(3_000))]
    uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, lines: [line(@camera, 1)], fees: fees,
                                     period: period("2026-03-10T12:00:00Z", "2026-03-12T12:00:00Z"), valid_until: t("2026-03-06T21:00:00Z") })
  end

  # Atendente da organização A, com convite aceito por token conhecido.
  def attendant(email)
    invitation = uc(:invite_member).call(@actor, email: email, role: "attendant")
    token = "#{@org[:organization_id]}.convite-#{SecureRandom.hex(12)}"
    @system.uow.run(@actor) do |tx, _|
      tx.execute("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]])
    end
    uc(:accept_invitation).call(token: token, name: "Bruno Atendente", password: PASSWORD)
  end

  def register_coupon
    visit "/cupons/novo"
    fill("#codigo", "teste10")
    fill("#valor", "10")
    submit("/cupons")

    assert_match %r{\A/cupons/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z}, current_path
    assert_includes text_of("[data-flash]"), "Cupom TESTE10 cadastrado."
    current_path
  end

  def register_fee
    visit "/tarifas/nova"
    fill("#codigo", "entrega")
    fill("#nome", "Entrega e retirada no local")
    fill("#valor_padrao", "150,00")
    submit("/tarifas")

    assert_includes text_of("[data-flash]"), "Tarifa ENTREGA cadastrada."
  end

  def register_agreement
    action = "/clientes/#{@customer.id}/condicoes"
    visit "/clientes/#{@customer.id}"
    click("details:has(form[action='#{action}']) summary")
    fill("#condicao-desconto", "5")
    submit(action)

    assert_includes text_of("[data-flash]"), "Condição negociada cadastrada."
    assert_includes text_of("#condicoes table"), "Todos os produtos"
    assert_includes text_of("#condicoes table"), "5%"
  end

  def reserve_with_fee_and_coupon
    visit "/reservas/nova"
    choose("#cliente_id", @customer.id)
    set_value("#inicio", "2026-03-10T09:00")
    set_value("#fim", "2026-03-12T09:00")
    choose("#produto-0", @camera.id)
    added = add_fee_line(2)

    assert_equal added.at_css("select").attribute("id"), active_element, "o foco vai para a tarifa da nova linha"
    assert_unique_labelled_fields
    press(added.at_css("[data-remove-line]"))
    wait_until("linha de tarifa removida") { fee_lines.size == 1 }
    fee_id = owner_query("SELECT id FROM additional_fees WHERE code = 'ENTREGA'").first["id"]
    choose("#tarifa-0", fee_id)
    fill("#cupom", "teste10")
    submit("/reservas")
  end

  def add_fee_line(expected)
    click("#{FEES} [data-add-line]")
    wait_until("linha #{expected} de tarifa") { fee_lines.size == expected }
    fee_lines.last
  end

  # Identificadores únicos no formulário inteiro (itens, tarifas e avulsas) e rótulo associado a cada
  # campo visível das linhas de tarifa.
  def assert_unique_labelled_fields
    ids = @page.css("form[data-line-items] [data-line] select, form[data-line-items] [data-line] input:not([type=hidden])")
               .map { |field| field.attribute("id") }

    assert_equal ids.uniq, ids, "identificadores únicos em cada linha"
    fee_lines.each do |row|
      row.css("select, input:not([type=hidden])").each do |field|
        refute_nil row.at_css("label[for='#{field.attribute("id")}']"), "rótulo associado a #{field.attribute("id")}"
      end
    end
  end
end
