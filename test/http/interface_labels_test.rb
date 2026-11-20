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
