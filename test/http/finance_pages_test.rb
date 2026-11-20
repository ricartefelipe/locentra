# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/finance_support"

# Telas do financeiro, painel na reserva, webhook público do provedor e permissões.
class FinancePagesTest < HttpTest
  include FinanceHelpers

  def setup
    super
    finance_setup(create_organization(email: "dona@alfa.test"))
    @account = simulator_account
    @reservation = booking
    sync(@reservation)
    @rental = rental_of(@reservation)
    login("dona@alfa.test")
  end

  def system_actor = A::Actor.system(organization_id: @org[:organization_id])

  def test_every_finance_page_renders_with_real_data
    manual = pay(@rental, 4_000, method: "pix")
    uc(:request_refund).call(@actor, manual.id, amount: money(1_000), reason: "Ajuste comercial")
    online = request_online(@rental, 2_000)
    uc(:submit_payment).call(system_actor, online.id)
    deposit = uc(:open_deposit).call(@actor, @reservation.id, kind: "paid_deposit")
    uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "cash", amount: money(30_000) })
    invoice = uc(:issue_invoice).call(@actor, @reservation.id)
    report = uc(:reconcile_payments).call(@actor)
    held = booking(mode: "hold", day: 20)
    cancelled = booking(day: 25).tap { |r| sync(r) }
    uc(:cancel_reservation).call(@actor, cancelled.id, reason: "Cliente desistiu")
    pay(rental_of(cancelled), 10_000)

    pages = ["/financeiro", "/financeiro?situacao=partial", "/financeiro/cobrancas/#{@rental.id}", "/financeiro/pagamentos/#{manual.id}",
             "/financeiro/pagamentos/#{online.id}", "/financeiro/caucoes/#{deposit.id}", "/financeiro/faturas/#{invoice["id"]}",
             "/financeiro/conciliacao/#{report}", "/financeiro/provedor", "/reservas/#{@reservation.id}", "/reservas/#{held.id}",
             "/reservas/#{cancelled.id}", "/financeiro/cobrancas/#{rental_of(cancelled).id}"]
    pages.each do |path|
      begin
        get path
      rescue Rack::Lint::LintError => e
        flunk "#{path}: #{e.message}"
      end

      assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
    end
    get "/financeiro"

    assert_includes last_response.body, "Pagamento após cancelamento"
    assert_includes last_response.body, "Cauções retidas"
    get "/financeiro/faturas/#{invoice["id"]}"

    assert_includes last_response.body, "NFS-e"
    get "/financeiro/pagamentos/#{online.id}"

    assert_includes last_response.body, "Simular confirmação pelo provedor"
  end

  def test_empty_states_render
    owner_query("UPDATE payment_provider_accounts SET active = false, deactivated_at = now()")
    get "/financeiro"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Nenhum alerta financeiro em aberto"
    assert_includes last_response.body, "Nenhum pagamento registrado"
    assert_includes last_response.body, "Nenhum provedor de pagamentos configurado"
    get "/financeiro?situacao=paid"

    assert_includes last_response.body, "Nenhuma cobrança encontrada"
  end

  def test_payment_refund_and_cancellation_forms
    post_form "/financeiro/cobrancas/#{@rental.id}/pagamentos", { "metodo" => "pix", "valor" => "40,00" }

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Pagamento registrado"
    post_form "/financeiro/cobrancas/#{@rental.id}/pagamentos", { "metodo" => "pix", "valor" => "999,00" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Valor acima do saldo em aberto"
    paid = uc(:finance).receivable(@actor, @rental.id)[:payments].first[:payment]
    post_form "/financeiro/pagamentos/#{paid.id}/reembolsos", { "valor" => "50,00", "motivo" => "Acima do pago" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "saldo elegível"
    post_form "/financeiro/pagamentos/#{paid.id}/reembolsos", { "valor" => "10,00", "motivo" => "Desconto posterior" }

    assert_equal 303, last_response.status
    post_form "/financeiro/cobrancas/#{@rental.id}/cancelar", { "motivo" => "" }

    assert_equal 422, last_response.status
    post_form "/financeiro/cobrancas/#{@rental.id}/cancelar", { "motivo" => "Cliente desistiu" }
    follow_redirect!

    assert_includes last_response.body, "operação compensatória"
    assert_equal "cancelled", balance_of(@rental).status
  end

  def test_provider_flow_through_the_screens
    post_form "/financeiro/cobrancas/#{@rental.id}/solicitar", { "metodo" => "pix", "valor" => "100,00", "vencimento" => "2026-03-05",
                                                                 "cenario" => "timeout_after_success" }

    assert_equal 303, last_response.status
    payment_id = last_response.location[%r{/financeiro/pagamentos/([0-9a-f-]{36})}, 1]
    uc(:submit_payment).call(system_actor, payment_id)
    get "/financeiro/pagamentos/#{payment_id}"

    assert_includes last_response.body, "Envio sem confirmação"
    post_form "/financeiro/conciliacao", {}
    follow_redirect!

    assert_includes last_response.body, "Atualizado no Locentra"
    post_form "/financeiro/pagamentos/#{payment_id}/simular", {}
    follow_redirect!

    assert_includes last_response.body, "webhook será processado"
    post_form "/financeiro/pagamentos/#{payment_id}/simular", {}
    follow_redirect!

    assert_includes last_response.body, "Evento repetido descartado"
    post_form "/financeiro/cobrancas/#{@rental.id}/solicitar", { "metodo" => "cash", "valor" => "1,00" }

    assert_equal 422, last_response.status
    post_form "/financeiro/cobrancas/#{@rental.id}/solicitar", { "metodo" => "pix", "valor" => "1,00", "vencimento" => "2026-02-01" }

    assert_equal 422, last_response.status
  end

  def test_reservation_panel_charges_and_invoice
    post_form "/financeiro/reservas/#{@reservation.id}/sincronizar", {}
    follow_redirect!

    assert_includes last_response.body, "já estão sincronizadas"
    post_form "/financeiro/reservas/#{@reservation.id}/cobrancas", { "tipo" => "damage", "descricao" => "Assento rasgado", "valor" => "80,00" }
    follow_redirect!

    assert_includes last_response.body, "Cobrança adicional registrada"
    post_form "/financeiro/reservas/#{@reservation.id}/cobrancas", { "tipo" => "rental", "descricao" => "x", "valor" => "1,00" }
    follow_redirect!

    assert_includes last_response.body, "Cobrança não registrada"
    post_form "/financeiro/reservas/#{@reservation.id}/faturas", { "observacoes" => "Vencimento em 5 dias" }
    follow_redirect!

    assert_includes last_response.body, "FAT-000001"
    post_form "/financeiro/reservas/#{booking(day: 27).id}/faturas", {}
    follow_redirect!

    assert_includes last_response.body, "Fatura não emitida"
  end

  def test_deposit_lifecycle_through_the_screens
    damage = uc(:create_manual_charge).call(@actor, @reservation.id, kind: "damage", amount: money(8_000), description: "Assento rasgado")
    post_form "/financeiro/reservas/#{@reservation.id}/caucao", { "tipo" => "card_preauthorization", "valor" => "300,00" }
    follow_redirect!

    assert_includes last_response.body, "não armazena número do cartão"
    post_form "/financeiro/reservas/#{@reservation.id}/caucao", { "tipo" => "paid_deposit", "valor" => "300,00" }

    assert_equal 303, last_response.status
    deposit_path = last_response.location
    post_form "#{deposit_path}/receber", { "metodo" => "pix", "valor" => "300,00" }
    post_form "#{deposit_path}/receber", { "metodo" => "pix", "valor" => "1,00" }

    assert_equal 422, last_response.status
    post_form "#{deposit_path}/aplicar", { "cobranca_id" => damage.id, "valor" => "80,00" }
    post_form "#{deposit_path}/aplicar", { "cobranca_id" => SecureRandom.uuid, "valor" => "1,00" }

    assert_equal 422, last_response.status
    post_form "#{deposit_path}/devolver", { "metodo" => "pix", "valor" => "220,00" }
    follow_redirect!

    assert_includes last_response.body, "Devolução da caução registrada"
    assert_includes last_response.body, "Encerrada"
    post_form "#{deposit_path}/devolver", { "metodo" => "pix", "valor" => "1,00" }

    assert_equal 422, last_response.status
    assert_equal "paid", balance_of(damage).status
  end

  def test_deposit_charged_through_provider_screen
    deposit = uc(:open_deposit).call(@actor, @reservation.id, kind: "paid_deposit")
    post_form "/financeiro/caucoes/#{deposit.id}/solicitar", { "metodo" => "pix", "valor" => "300,00", "cenario" => "success" }

    assert_equal 303, last_response.status
    payment_id = last_response.location[%r{/financeiro/pagamentos/([0-9a-f-]{36})}, 1]
    uc(:submit_payment).call(system_actor, payment_id)
    uc(:simulate_payment).call(@actor, payment_id)
    uc(:process_payment_webhook).call(system_actor, owner_query("SELECT id FROM inbound_webhooks").first["id"])
    get "/financeiro/caucoes/#{deposit.id}"

    assert_includes last_response.body, "Retida"
    post_form "/financeiro/caucoes/#{deposit.id}/solicitar", { "metodo" => "pix", "valor" => "1,00", "vencimento" => "05/03/2026" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "data inválida"
    post_form "/financeiro/pagamentos/#{payment_id}/simular", {}

    assert_equal 303, last_response.status, "simulação repetida de cobrança paga é descartada"
    manual = pay(@rental, 1_000)
    post_form "/financeiro/pagamentos/#{manual.id}/simular", {}

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Somente cobranças registradas no simulador"
  end

  def test_alert_resolution_and_provider_configuration
    reservation = booking(day: 22).tap { |r| sync(r) }
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Cancelada")
    sync(reservation)
    get "/financeiro"
    alert_id = last_response.body[%r{/financeiro/alertas/([0-9a-f-]{36})/resolver}, 1]
    post_form "/financeiro/alertas/#{alert_id}/resolver", { "decisao" => "no_action", "observacao" => "Cobrança mantida", "voltar" => "/financeiro" }
    follow_redirect!

    assert_includes last_response.body, "Decisão registrada"
    post_form "/financeiro/alertas/#{alert_id}/resolver", { "decisao" => "no_action" }
    follow_redirect!

    assert_includes last_response.body, "Alerta já resolvido"
    post_form "/financeiro/provedor", { "provedor" => "asaas", "nome" => "Asaas", "ambiente" => "sandbox", "chave_api" => "" }

    assert_equal 422, last_response.status
    post_form "/financeiro/provedor", { "provedor" => "simulator", "nome" => "Simulador novo" }

    assert_equal 200, last_response.status
    assert_includes last_response.body, "asaas-access-token"
    assert_match(/whk_[A-Za-z0-9_-]{20,}/, last_response.body)
    active = owner_query("SELECT id FROM payment_provider_accounts WHERE active").first["id"]
    post_form "/financeiro/provedor/#{active}/desativar", {}
    follow_redirect!

    assert_includes last_response.body, "Conta do provedor desativada"
    post_form "/financeiro/conciliacao", {}
    follow_redirect!

    assert_includes last_response.body, "Configure um provedor"
  end

  def test_public_webhook_endpoint_authenticates_and_deduplicates
    online = request_online(@rental, 10_000)
    uc(:submit_payment).call(system_actor, online.id)
    body = JSON.generate("id" => "evt_http_1", "event" => "PAYMENT_RECEIVED",
                         "payment" => { "id" => payment(online.id).provider_payment_id, "value" => 100, "externalReference" => online.id })
    headers = { "CONTENT_TYPE" => "application/json", "HTTP_ASAAS_ACCESS_TOKEN" => @account["webhook_token"] }
    clear_cookies
    post "/webhooks/pagamentos/#{@account["id"]}", body, headers

    assert_equal 200, last_response.status
    assert_equal "accepted", json_body["status"]
    post "/webhooks/pagamentos/#{@account["id"]}", body, headers

    assert_equal "duplicate", json_body["status"]
    post "/webhooks/pagamentos/#{@account["id"]}", body, headers.merge("HTTP_ASAAS_ACCESS_TOKEN" => "whk_invalido")

    assert_equal 401, last_response.status
    assert_equal "unauthorized", json_body["error"]["code"]
    post "/webhooks/pagamentos/#{@account["id"]}", "{malformado", headers

    assert_equal 422, last_response.status
    assert_equal 1, count("inbound_webhooks")
    assert_equal 1, count("jobs", "kind = 'payments.process_webhook'")
  end

  def test_finance_navigation_and_permissions
    get "/"

    assert_includes last_response.body, %(href="/financeiro")
    invite = uc(:invite_member).call(@actor, email: "atendente@alfa.test", role: "attendant")
    token = "#{@org[:organization_id]}.segredo-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    uc(:accept_invitation).call(token: token, name: "Atendente", password: "senha-muito-segura-3")
    post_form "/sair", {}
    login("atendente@alfa.test", "senha-muito-segura-3")

    refute_includes last_response.body, %(href="/financeiro")
    get "/financeiro"

    assert_equal 403, last_response.status
    get "/reservas/#{@reservation.id}"

    assert_equal 200, last_response.status
    refute_includes last_response.body, "Sincronizar cobranças"
    post_form "/financeiro/cobrancas/#{@rental.id}/pagamentos", { "metodo" => "pix", "valor" => "1,00" }

    assert_equal 403, last_response.status
  end
end
