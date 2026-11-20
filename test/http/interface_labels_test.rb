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
