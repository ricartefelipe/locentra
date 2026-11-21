# frozen_string_literal: true

require "rack/test"
require "rack/lint"
require_relative "integration_helper"
require_relative "../support/commercial_terms_support"
require_relative "../support/portal_support"
require "locentra/interfaces/http/app"

# Passo 15 de docs/DEMONSTRACAO.md (condições comerciais), com dados próprios equivalentes aos do
# seed: a reserva pela interface web combina a condição negociada do cliente, um cupom e uma tarifa do
# catálogo; o cancelamento libera o uso do cupom; o atendente aplica a tarifa somente pelo valor
# padrão; e o cupom de uma organização não existe na outra.
class DemoCommercialTermsTest < DatabaseTest
  include Rack::Test::Methods
  include CommercialTermsSupport
  include PortalHelpers

  PASSWORD = "senha-muito-segura-1"
  MEMBER_PASSWORD = "senha-muito-segura-7"
  ATTENDANT_NOTICE = "Tarifas são aplicadas pelo valor padrão. Valor diferente e tarifa avulsa exigem a permissão de ajustar tarifas " \
                     "(gerente, administrador ou proprietário)."

  def app = @app ||= Rack::Lint.new(Locentra::Interfaces::HTTP::App.build(@system))

  def test_commercial_terms_step_of_the_demonstration
    prepare_organizations
    enter_as_owner_and_review_registrations
    reserve_with_agreement_coupon_and_fee
    cancel_and_release_the_coupon_use
    attendant_applies_the_fee_by_its_default_amount
    coupon_does_not_exist_in_the_other_organization
  end

  private

  # Dados equivalentes aos do seed: câmera com diária de R$ 450,00 e caução de R$ 3.000,00, cliente com
  # condição geral de 8%, cupons e tarifas da Alfa, e a Beta com cliente, produto e cupom próprios.
  def prepare_organizations
    @alfa = create_organization(name: "Alfa Audiovisual", email: "ana@alfa.test")
    @beta = create_organization(name: "Beta Eventos", email: "paulo@beta.test")
    join(@beta[:actor], @alfa[:user_id], "ana@alfa.test", "manager")
    @org = @alfa
    @actor = @alfa[:actor]
    @customer = uc(:create_customer).call(@actor, { kind: "company", name: "Produtora Horizonte Ltda.", document: "11222333000181",
                                                    email: "contato@horizonte.test" })
    @camera = create_product(@actor, sku: "CAM-FX6", name: "Câmera Sony FX6", tracking: "serialized", deposit: D::Money.new(300_000),
                                     pricing: { "daily_cents" => 45_000, "weekly_cents" => 225_000, "hourly_cents" => 9_000 })
    register_assets(@actor, @camera, @alfa[:branch], 3)
    @delivery = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    create_fee("MONTAGEM", "Montagem e desmontagem", 25_000)
    create_fee("LIMPEZA", "Higienização dos equipamentos", 8_000)
    @coupon = create_coupon("BEMVINDO10", description: "Boas-vindas: 10% de desconto", max_redemptions: 100, valid_until: @clock.now + (365 * 86_400))
    create_coupon("PRIMEIRALOCACAO", kind: "fixed", value: 5_000, max_redemptions: 1, min_subtotal_cents: 30_000)
    create_agreement(@customer, 800, notes: "Contrato anual de produção")
    @beta_customer = uc(:create_customer).call(@beta[:actor], { kind: "company", name: "Casamentos Primavera ME", document: "45723174000110" })
    @generator = create_product(@beta[:actor], sku: "GER-5K", name: "Gerador 5 kVA", tracking: "serialized", pricing: { "daily_cents" => 35_000 })
    register_assets(@beta[:actor], @generator, @beta[:branch], 1)
    create_coupon("PRIMAVERA15", actor: @beta[:actor], value: 1_500)
  end

  # (1) e (2) A proprietária entra na Alfa e confere os cadastros: cupons, tarifas e a condição do cliente.
  def enter_as_owner_and_review_registrations
    sign_in("ana@alfa.test", PASSWORD, organization: @alfa)
    coupons = page("/cupons")

    assert_includes coupons, "BEMVINDO10"
    assert_includes coupons, "PRIMEIRALOCACAO"
    refute_includes coupons, "PRIMAVERA15"
    fees = page("/tarifas")

    %w[ENTREGA MONTAGEM LIMPEZA].each { |code| assert_includes fees, code }
    customer = page("/clientes/#{@customer.id}")

    assert_includes customer, "Condições negociadas"
    assert_includes customer, "Todos os produtos"
    assert_includes customer, "Contrato anual de produção"
  end

  # (3) e (4) Reserva de D+20 09:00 a D+22 09:00 com a tarifa de entrega e o cupom digitado em minúsculas.
  def reserve_with_agreement_coupon_and_fee
    form = page("/reservas/nova")

    assert_includes form, "Entrega e retirada no local · R$ 150,00"
    submit "/reservas", reservation_form(@customer, @alfa[:branch], @camera, "tarifa_id" => [@delivery.id], "tarifa_valor" => [""],
                                                                             "cupom" => "bemvindo10")

    assert_equal 303, last_response.status, last_response.body[0, 600]
    follow_redirect!
    shown = last_response.body
    @reservation_id = last_request.path.split("/").last

    assert_match(%r{<dt>Subtotal</dt>\s*<dd>R\$ 828,00<br><span class="muted">o subtotal já considera a condição negociada \(−R\$ 72,00\)</span></dd>}, shown)
    assert_includes shown, %(<dt>Cupom <a href="/cupons/#{@coupon.id}">BEMVINDO10</a> (10%)</dt>)
    assert_includes shown, "<dd>−R$ 82,80</dd>"
    assert_match(%r{<dt>Entrega e retirada no local</dt>\s*<dd>R\$ 150,00</dd>}, shown)
    assert_includes shown, "<dt>Total contratado</dt><dd><strong>R$ 895,20</strong></dd>"
    assert_includes shown, "<dt>Caução prevista</dt><dd>R$ 3.000,00</dd>"
    summary = uc(:get_reservation).call(@actor, @reservation_id)[:pricing][:summary]

    assert_equal [82_800, 8_280, 15_000, 89_520, 300_000],
                 summary.values_at("subtotal_cents", "coupon_discount_cents", "fees_cents", "total_cents", "deposit_cents")
    assert_equal [800, 7_200], uc(:get_reservation).call(@actor, @reservation_id)[:items].first["pricing"]
                                                   .values_at("negotiated_discount_bps", "negotiated_discount_cents")
  end

  # (5) O cupom mostra um uso; cancelar a reserva libera o uso sem apagar o registro.
  def cancel_and_release_the_coupon_use
    used = page("/cupons/#{@coupon.id}")

    assert_includes used, "1 de 100; restantes: 99"
    assert_equal "1 de 100", usage("BEMVINDO10")
    submit "/reservas/#{@reservation_id}/cancelar", { "motivo" => "Cliente desistiu da locação" }

    assert_equal 303, last_response.status, last_response.body[0, 600]
    released = page("/cupons/#{@coupon.id}")

    assert_includes released, "0 de 100; restantes: 100"
    assert_includes released, "Liberado: reserva cancelada"
    assert_equal ["0 de 100", "released_cancelled", 1],
                 [usage("BEMVINDO10"), redemptions_of("BEMVINDO10").first[:state], coupon_data("BEMVINDO10")[:coupon].total_redemptions]
  end

  # (6) O atendente vê a tarifa somente pelo valor padrão, com o aviso sobre valor diferente e tarifa avulsa.
  def attendant_applies_the_fee_by_its_default_amount
    staff_member(@alfa, "bruno@alfa.test", "attendant")
    sign_out
    sign_in("bruno@alfa.test", MEMBER_PASSWORD)
    form = page("/reservas/nova")

    assert_includes form, "Entrega e retirada no local · R$ 150,00"
    assert_includes form, ATTENDANT_NOTICE
    refute_includes form, %(placeholder="padrão")
    refute_includes form, "Tarifas avulsas"
    submit "/reservas", reservation_form(@customer, @alfa[:branch], @camera, "tarifa_id" => [@delivery.id], "tarifa_valor" => ["100,00"])

    assert_equal 422, last_response.status
    assert_includes last_response.body, "exige a permissão de ajustar tarifas"
  end

  # (7) Na Beta, a mesma usuária (gerente) não consegue usar o cupom da Alfa: ele não existe ali.
  def coupon_does_not_exist_in_the_other_organization
    sign_out
    sign_in("ana@alfa.test", PASSWORD, organization: @beta)
    coupons = page("/cupons")

    assert_includes coupons, "PRIMAVERA15"
    refute_includes coupons, "BEMVINDO10"
    submit "/reservas", reservation_form(@beta_customer, @beta[:branch], @generator, "cupom" => "BEMVINDO10")

    assert_equal 422, last_response.status
    assert_includes last_response.body, "cupom inexistente"
    assert_empty owner_query("SELECT id FROM reservations", [], tenant: @beta[:organization_id])
    assert_raises(D::NotFound) { uc(:get_coupon).call(@beta[:actor], "BEMVINDO10") }
    assert_equal 1, owner_query("SELECT count(*) AS n FROM coupon_redemptions").first["n"].to_i, "o livro de usos da Alfa não mudou"
  end

  def reservation_form(customer, branch, product, extra = {})
    { "cliente_id" => customer.id, "filial_id" => branch.id, "inicio" => "2026-03-22T09:00", "fim" => "2026-03-24T09:00",
      "produto" => [product.id], "quantidade" => ["1"], "modo" => "confirm" }.merge(extra)
  end

  def page(path)
    get path

    assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
    last_response.body
  end

  def csrf = last_response.body[/name="_csrf" value="([^"]+)"/, 1] || page("/")[/name="_csrf" value="([^"]+)"/, 1]

  def submit(path, params) = post(path, params.merge("_csrf" => csrf))

  # Com mais de uma organização, a escolha é explícita depois da entrada.
  def sign_in(email, password, organization: nil)
    post "/entrar", { "email" => email, "senha" => password }

    assert_equal 303, last_response.status, last_response.body[0, 400]
    follow_redirect!
    return unless organization

    post "/organizacoes/ativar", { "_csrf" => csrf, "organizacao_id" => organization[:organization_id] }
    follow_redirect!

    assert_equal 200, last_response.status
  end

  def sign_out = submit("/sair", {})

  def join(inviter, user_id, email, role)
    invitation = uc(:invite_member).call(inviter, email: email, role: role)
    token = "#{inviter.organization_id}.demo-#{SecureRandom.hex(12)}"
    @system.uow.run(inviter) do |tx, _|
      tx.execute("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]])
    end
    uc(:accept_invitation).call(token: token, user_id: user_id)
  end
end
