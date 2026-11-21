# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/finance_support"

# Textos da interface: códigos internos exibidos em português, resumo de erros com o nome do campo,
# formulários de detalhe reabertos com os valores enviados quando falham, e envio único dos formulários
# de pagamento.
class InterfaceLabelsTest < HttpTest
  include FinanceHelpers

  def setup
    super
    finance_setup(create_organization(email: "dona@alfa.test"))
    login("dona@alfa.test")
  end

  def count_payments = owner_query("SELECT count(*) AS n FROM payments").first["n"].to_i

  def test_asset_history_and_reservation_details_use_portuguese_labels
    camera = create_product(@actor, sku: "CAM-LBL", tracking: "serialized")
    asset = register_assets(@actor, camera, @org[:branch], 1).first
    get "/ativos/#{asset.id}"

    assert_includes last_response.body, "<strong>Cadastro</strong>"
    assert_includes last_response.body, "→ Disponível"
    refute_match(%r{<strong>registered</strong>|→ available}, last_response.body)
    reservation = booking
    get "/reservas/#{reservation.id}"

    assert_includes last_response.body, "<dd>Equipe</dd>"
    assert_includes last_response.body, "Reserva registrada"
    refute_includes last_response.body, "reservation.created"
    get "/organizacao"

    assert_includes last_response.body, "Em avaliação"
  end

  def test_commercial_terms_actions_statuses_and_fields_have_portuguese_labels
    labels = Locentra::Interfaces::HTTP::Labels
    actions = { "coupon.created" => "Cupom cadastrado", "coupon.updated" => "Cupom alterado", "coupon.deactivated" => "Cupom desativado",
                "coupon.reactivated" => "Cupom reativado", "coupon.deleted" => "Cupom excluído", "fee.created" => "Tarifa cadastrada",
                "fee.updated" => "Tarifa alterada", "fee.deactivated" => "Tarifa desativada", "fee.reactivated" => "Tarifa reativada",
                "price_agreement.created" => "Condição negociada cadastrada", "price_agreement.ended" => "Condição negociada encerrada" }
    fields = { "tarifas" => "Tarifas adicionais", "maximo_usos" => "Máximo de usos", "subtotal_minimo" => "Subtotal mínimo",
               "valido_de" => "Início da vigência", "valido_ate" => "Fim da vigência", "valor_padrao" => "Valor padrão",
               "encerrar_em" => "Encerrar em", "produto" => "Produto" }

    actions.each { |action, text| assert_equal text, labels.label(:audit_action, action) }
    fields.each { |field, text| assert_equal text, labels.label(:field, field) }
    assert_equal(%w[Vigente Agendado Expirado Esgotado Desativado],
                 %w[active scheduled expired exhausted inactive].map { |status| labels.label(:coupon_status, status) })
    assert_equal(%w[Vigente Agendada Expirada Encerrada], %w[active scheduled expired ended].map { |status| labels.label(:agreement_status, status) })
    assert_equal(%w[Ativa Inativa], %w[active inactive].map { |status| labels.label(:fee_status, status) })
    assert_equal "Liberado: bloqueio temporário expirado", labels.label(:redemption_state, "released_expired")
    assert_equal(["Percentual", "Valor fixo"], %w[percent fixed].map { |kind| labels.label(:coupon_kind, kind) })
    assert_equal "valor padrão", labels.label(:changed_field, "default_amount_cents")
  end

  def test_organization_settings_and_branch_labels_are_in_portuguese
    labels = Locentra::Interfaces::HTTP::Labels
    actions = { "organization.created" => "Organização criada", "organization.settings_updated" => "Configurações da organização alteradas",
                "branch.created" => "Filial criada", "branch.updated" => "Filial alterada", "branch.deactivated" => "Filial desativada",
                "branch.reactivated" => "Filial reativada" }
    changed = { "timezone" => "fuso horário", "hold_minutes" => "validade padrão do bloqueio", "cancellation_policy" => "política de cancelamento",
                "address" => "endereço", "name" => "nome" }
    fields = { "fuso_horario" => "Fuso horário", "confirmar_fuso" => "Confirmação da troca de fuso",
               "faixas_cancelamento" => "Faixas da política de cancelamento", "fuso" => "Fuso horário do formulário", "destino" => "Destino",
               "faixas" => "Faixas de desconto" }

    actions.each { |action, text| assert_equal text, labels.label(:audit_action, action) }
    changed.each { |field, text| assert_equal text, labels.label(:changed_field, field) }
    fields.each { |field, text| assert_equal text, labels.label(:field, field) }
  end

  def test_error_summary_shows_field_names_and_transition_errors_use_status_labels
    get "/produtos/novo"
    post_form "/produtos", { "sku" => "X-1", "nome" => "Produto", "rastreamento" => "bulk", "preco_diaria" => "10,00", "caucao" => "-5" }

    assert_equal 422, last_response.status
    assert_match(/<li>Caução: /, last_response.body)
    refute_match(/<li>caucao: /, last_response.body)
    error = Locentra::Domain::InvalidTransition.new("reserva", "cancelled", "confirmed")

    assert_equal "Transição inválida em reserva: Cancelada → Confirmada", error.message
  end

  def test_failed_detail_form_is_reopened_with_the_submitted_values
    customer = @customer
    get "/clientes/#{customer.id}"
    post_form "/clientes/#{customer.id}/contatos", { "nome" => "Maria Retira", "documento" => "12345678900", "telefone" => "11 99999-0000",
                                                     "autorizado" => "1" }

    assert_equal 422, last_response.status
    form = last_response.body[%r{<details open>\s*<summary>Adicionar contato</summary>.*?</details>}m]

    refute_nil form, "o formulário que falhou volta aberto"
    assert_includes form, 'value="Maria Retira"'
    assert_includes form, 'value="11 99999-0000"'
    refute_match(/<details open>\s*<summary>Adicionar endereço/, last_response.body)
  end

  def test_payment_form_submitted_twice_registers_one_payment
    @account = simulator_account
    rental = rental_of(booking.tap { |r| sync(r) })
    get "/financeiro/cobrancas/#{rental.id}"
    key = last_response.body[/name="envio" value="([^"]+)"/, 1]
    token = csrf

    refute_nil key
    2.times { post "/financeiro/cobrancas/#{rental.id}/pagamentos", { "_csrf" => token, "envio" => key, "metodo" => "pix", "valor" => "10,00" } }

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Pagamento já registrado (envio repetido do formulário)."
    assert_equal 1, count_payments
    post "/financeiro/cobrancas/#{rental.id}/solicitar", { "_csrf" => token, "envio" => "#{key}-b", "metodo" => "pix", "valor" => "5,00" }
    post "/financeiro/cobrancas/#{rental.id}/solicitar", { "_csrf" => token, "envio" => "#{key}-b", "metodo" => "pix", "valor" => "5,00" }

    assert_equal 2, count_payments, "a cobrança pelo provedor também é criada uma única vez"
  end
end
