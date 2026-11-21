# frozen_string_literal: true

require "rack/test"
require "rack/lint"
require_relative "integration_helper"
require "locentra/interfaces/http/app"

# Passo 16 de docs/DEMONSTRACAO.md (configurações da organização e filiais), com dados próprios
# equivalentes aos do seed: a filial NORTE é criada no próprio passo; a política e a validade padrão são
# alteradas depois da pré-visualização; o contrato emitido antes mantém a política registrada e uma
# reserva nova traz a nova; o histórico e a auditoria registram a alteração; a NORTE é desativada e
# reativada, e a Matriz não pode ser desativada.
class DemoOrganizationSettingsTest < DatabaseTest
  include Rack::Test::Methods

  PASSWORD = "senha-muito-segura-1"
  NEW_POLICY = "de 24 h a menos de 48 h antes do início: multa de 50% do valor contratado"
  OLD_POLICY = "de 24 h a menos de 72 h antes do início: multa de 30% do valor contratado"

  def app = @app ||= Rack::Lint.new(Locentra::Interfaces::HTTP::App.build(@system))

  def test_organization_settings_step_of_the_demonstration
    prepare_organization
    sign_in("ana@alfa.test")
    create_the_north_branch
    preview_and_save_the_new_settings
    issued_contract_keeps_the_policy_and_a_new_reservation_brings_the_new_one
    history_and_audit_record_the_change
    deactivate_north_refuse_main_and_reactivate_north
  end

  private

  # Equivalente ao seed: Alfa com a Matriz, cliente, câmera com três ativos e o contrato do passo 7
  # (emitido com a política padrão).
  def prepare_organization
    @alfa = create_organization(name: "Alfa Audiovisual", email: "ana@alfa.test")
    @org = @alfa
    @actor = @alfa[:actor]
    @main = @alfa[:branch]
    @customer = uc(:create_customer).call(@actor, { kind: "company", name: "Produtora Horizonte Ltda.", document: "11222333000181",
                                                    email: "contato@horizonte.test" })
    @camera = create_product(@actor, sku: "CAM-FX6", name: "Câmera Sony FX6", tracking: "serialized", pricing: { "daily_cents" => 45_000 })
    register_assets(@actor, @camera, @main, 3)
    reservation = reserve(@actor, @customer, @main, period("2026-03-10T12:00:00Z", "2026-03-12T12:00:00Z"), [line(@camera, 1)], mode: "confirm")
    @contract = uc(:issue_contract).call(@actor, reservation.id)
  end

  # (1) Organização → Nova filial: "Unidade Norte", código NORTE.
  def create_the_north_branch
    page("/organizacao")
    submit("/organizacao/filiais", { "nome" => "Unidade Norte", "codigo" => "norte", "endereco" => "Av. Norte, 100" })

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Filial criada."
    assert_includes last_response.body, "<code>NORTE</code>"
    @north = uc(:get_organization).call(@actor)[:branches].find { |branch| branch.code == "NORTE" }
  end

  # (2) Editar configurações: faixas 48 h/0%, 24 h/50% e 0 h/100%, validade 45 minutos; pré-visualizar e salvar.
  def preview_and_save_the_new_settings
    form = page("/organizacao/configuracoes")

    assert_includes form, "Validade padrão do bloqueio temporário (minutos)"
    settings = { "nome" => "Alfa Audiovisual", "fuso_horario" => "America/Sao_Paulo", "validade_bloqueio" => "45", "versao" => "1",
                 "antecedencia_horas" => %w[48 24 0], "multa_percentual" => %w[0 50 100] }
    submit("/organizacao/configuracoes", settings.merge("acao" => "previsualizar"))

    assert_equal 200, last_response.status
    assert_includes last_response.body, NEW_POLICY
    assert_includes last_response.body, "<td>de 24 h a menos de 48 h</td><td class=\"num\">50%</td><td class=\"num\">R$ 500,00</td>"
    assert_includes last_response.body, "Bloqueios criados sem validade informada vencem em 45 minutos."
    submit("/organizacao/configuracoes", settings.merge("acao" => "salvar"))

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Configurações salvas. Reservas, orçamentos e contratos já registrados mantêm a política e os valores do registro."
  end

  # (3) O contrato do passo 7 mantém a política da emissão; uma reserva nova traz a política nova.
  def issued_contract_keeps_the_policy_and_a_new_reservation_brings_the_new_one
    contract = page("/contratos/#{@contract.id}")

    assert_includes contract, OLD_POLICY
    refute_includes contract, NEW_POLICY
    form = page("/reservas/nova")

    assert_includes form, %(name="validade_bloqueio" type="number" min="5" max="1440" value="45")
    submit("/reservas", { "cliente_id" => @customer.id, "filial_id" => @main.id, "inicio" => "2026-03-22T09:00", "fim" => "2026-03-24T09:00",
                          "produto" => [@camera.id], "quantidade" => ["1"], "modo" => "confirm", "fuso" => "America/Sao_Paulo" })

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Política de cancelamento desta reserva"
    assert_includes last_response.body, NEW_POLICY
  end

  # (4) Histórico na tela de configurações e o evento na auditoria, com a proprietária como autora.
  def history_and_audit_record_the_change
    assert_match(%r{Configurações da organização alteradas</strong>\s+\(validade padrão do bloqueio, política de cancelamento\)},
                 page("/organizacao/configuracoes"))
    assert_includes page("/auditoria"), "organization.settings_updated"
  end

  # (5) e (6) NORTE sem pendências é desativada; a Matriz, única ativa, não; a NORTE é reativada.
  def deactivate_north_refuse_main_and_reactivate_north
    page("/organizacao/filiais/#{@north.id}")
    submit("/organizacao/filiais/#{@north.id}/desativar", {})
    follow_redirect!

    assert_includes last_response.body, "Filial desativada."
    page("/organizacao/filiais/#{@main.id}")
    submit("/organizacao/filiais/#{@main.id}/desativar", {})

    assert_equal 409, last_response.status
    assert_includes last_response.body, "A organização precisa de ao menos uma filial ativa."
    refute_includes page("/reservas/nova"), "Unidade Norte"
    page("/organizacao/filiais/#{@north.id}")
    submit("/organizacao/filiais/#{@north.id}/reativar", {})
    follow_redirect!

    assert_includes last_response.body, "Filial reativada."
    assert_equal [true, true], uc(:get_organization).call(@actor)[:branches].map(&:active)
  end

  def page(path)
    get path

    assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
    last_response.body
  end

  def csrf = last_response.body[/name="_csrf" value="([^"]+)"/, 1] || page("/")[/name="_csrf" value="([^"]+)"/, 1]

  def submit(path, params) = post(path, params.merge("_csrf" => csrf))

  def sign_in(email)
    post "/entrar", { "email" => email, "senha" => PASSWORD }

    assert_equal 303, last_response.status, last_response.body[0, 400]
    follow_redirect!
  end
end
