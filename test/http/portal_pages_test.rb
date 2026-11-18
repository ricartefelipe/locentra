# frozen_string_literal: true

require_relative "portal_http_helper"

# Funcionalidades do portal pela interface (Rack::Lint): disponibilidade e solicitação de reserva,
# reservas, orçamentos, contratos com aceite e PDF, cobranças e isolamento entre clientes e organizações.
class PortalPagesTest < PortalHttpTest
  def test_availability_check_and_reservation_request_through_the_screens
    portal_customer(@actor, @customer, email: "paula@cliente.test", name: "Paula Compras")
    portal_login

    assert_includes get_ok("/portal/disponibilidade"), "não garante disponibilidade"
    check = get_ok("/portal/disponibilidade?filial=#{@branch.id}&inicio=2026-03-10T05:00&fim=2026-03-11T05:00")

    assert_includes check, @camera.name
    assert_includes check, "Disponível"
    refute_includes check, "CAM-WEB-1", "nenhum ativo individual é exposto"
    refute_includes check, "Total", "nenhum total de frota é exposto"
    portal_post "/portal/reservas", request_form("")

    assert_equal 422, last_response.status
    assert_includes last_response.body, "informe ao menos um item"
    portal_post "/portal/reservas", request_form("2", "observacoes" => "Entrega <script>x</script>")

    assert_equal 303, last_response.status
    follow_redirect!
    page = last_response.body

    assert_includes page, "registrada. A disponibilidade só é garantida após a confirmação da locadora"
    assert_includes page, Locentra::Domain::Portal::REQUEST_NOTICE
    assert_includes page, "Solicitação pelo portal"
    assert_includes page, "Entrega &lt;script&gt;x&lt;/script&gt;"
    assert_includes get_ok("/portal/reservas"), "Solicitada"
    assert_equal %w[requested portal], owner_query("SELECT status, source FROM reservations").first.values_at("status", "source")
  end

  def test_reservations_and_quotes_through_the_screens
    portal_customer(@actor, @customer, email: "paula@cliente.test", name: "Paula Compras")
    confirmed = reserve(@actor, @customer, @branch, period("2026-03-12T08:00:00Z", "2026-03-13T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    quote = sent_quote(@actor, @customer, @branch, @camera, 20)
    rejected = sent_quote(@actor, @customer, @branch, @camera, 22)
    portal_login

    assert_includes last_response.body, "Orçamentos aguardando sua decisão"
    assert_includes last_response.body, quote.code
    assert_includes get_ok("/portal/reservas?situacao=confirmed"), confirmed.code
    refute_includes get_ok("/portal/reservas/#{confirmed.id}"), "CAM-WEB-", "alocações não aparecem para o cliente"
    assert_includes get_ok("/portal/orcamentos"), quote.code
    quote_page = get_ok("/portal/orcamentos/#{quote.id}")

    assert_includes quote_page, "não garante disponibilidade"
    assert_includes quote_page, "Aprovar versão 1"
    portal_post "/portal/orcamentos/#{quote.id}/aprovar", { "versao" => "1", "nome" => "" }

    assert_equal 422, last_response.status
    portal_post "/portal/orcamentos/#{quote.id}/aprovar", { "versao" => "1", "nome" => "Paula Compras" }
    follow_redirect!

    assert_includes last_response.body, "Orçamento #{quote.code} aprovado (versão 1)"
    assert_equal "customer", owner_query("SELECT approved_by_type FROM quotes WHERE id = $1", [quote.id]).first["approved_by_type"]
    portal_post "/portal/orcamentos/#{rejected.id}/rejeitar", { "motivo" => "Data alterada" }
    follow_redirect!

    assert_includes last_response.body, "Orçamento #{rejected.code} rejeitado"
  end

  def test_contract_acceptance_pdf_download_and_statement_through_the_screens
    portal_customer(@actor, @customer, email: "paula@cliente.test", name: "Paula Compras")
    contract = contract_for(@actor, @customer, @branch, @camera, 12)
    uc(:sync_reservation_charges).call(@actor, contract.reservation_id)
    portal_login

    assert_includes last_response.body, contract.code
    assert_includes get_ok("/portal/contratos"), contract.code
    page = get_ok("/portal/contratos/#{contract.id}")

    assert_includes page, "aceite eletrônico simples"
    assert_includes page, "Baixar PDF da versão 1"
    get "/anexos/#{page[%r{href="/anexos/([0-9a-f-]{36})"}, 1]}"

    assert_equal [200, "application/pdf"], [last_response.status, last_response.headers["content-type"]]
    assert last_response.body.start_with?("%PDF")
    portal_post "/portal/contratos/#{contract.id}/aceite", { "nome" => "Paula Compras", "documento" => "123", "declaracao" => "1" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "CPF ou CNPJ inválido"
    portal_post "/portal/contratos/#{contract.id}/aceite", { "nome" => "Paula Compras", "documento" => "52998224725", "declaracao" => "1" }
    follow_redirect!

    assert_includes last_response.body, "Aceite eletrônico simples registrado"
    assert_equal "portal", owner_query("SELECT accepted_via FROM contract_documents").first["accepted_via"]
    finance = get_ok("/portal/financeiro")

    assert_includes finance, "R$ 150,00"
    assert_includes finance, "Em aberto"
    refute_includes finance, "Diário", "sem dados contábeis internos"
  end

  def test_resources_of_other_customers_and_organizations_are_not_found
    portal_customer(@actor, @customer, email: "paula@cliente.test")
    other_reservation = reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    other_contract = uc(:issue_contract).call(@actor, other_reservation.id)
    other_quote = sent_quote(@actor, @other, @branch, @camera, 20)
    other_pdf = uc(:get_contract).call(@actor, other_contract.id)[:documents].first["attachment_id"]
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")
    beta_customer = create_customer(beta[:actor], name: "Cliente Beta")
    beta_product = create_product(beta[:actor], sku: "CAM-BETA", tracking: "serialized")
    register_assets(beta[:actor], beta_product, beta[:branch], 1)
    beta_contract = contract_for(beta[:actor], beta_customer, beta[:branch], beta_product, 15)
    beta_pdf = uc(:get_contract).call(beta[:actor], beta_contract.id)[:documents].first["attachment_id"]
    portal_login

    ["/portal/reservas/#{other_reservation.id}", "/portal/orcamentos/#{other_quote.id}", "/portal/contratos/#{other_contract.id}",
     "/anexos/#{other_pdf}", "/portal/reservas/#{beta_contract.reservation_id}", "/portal/contratos/#{beta_contract.id}",
     "/anexos/#{beta_pdf}"].each do |path|
      get path

      assert_equal 404, last_response.status, path
      refute_includes last_response.body, "Cliente Vizinho", path
      refute_includes last_response.body, "Cliente Beta", path
    end
    assert_includes last_response.body, %(aria-label="Navegação do portal"), "erros do cliente usam o layout do portal"
    portal_post "/portal/orcamentos/#{other_quote.id}/aprovar", { "versao" => "1", "nome" => "Intruso" }

    assert_equal 404, last_response.status
    portal_post "/portal/contratos/#{other_contract.id}/aceite", { "nome" => "Intruso", "documento" => "52998224725", "declaracao" => "1" }

    assert_equal 404, last_response.status
    portal_post "/portal/reservas", { "filial" => beta[:branch].id, "inicio" => "2026-03-10T05:00", "fim" => "2026-03-11T05:00",
                                      "produto" => [@camera.id], "quantidade" => ["1"] }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "filial não encontrado"
    refute_includes get_ok("/portal/reservas"), other_reservation.code
    refute_includes get_ok("/portal/orcamentos"), other_quote.code
    refute_includes get_ok("/portal/contratos"), other_contract.code
  end
end
