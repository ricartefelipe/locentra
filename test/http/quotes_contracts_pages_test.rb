# frozen_string_literal: true

require_relative "http_helper"

# Telas de orçamentos e contratos: renderização (Rack::Lint), fluxo completo por formulários,
# mensagens de erro e permissões.
class QuotesContractsPagesTest < HttpTest
  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @actor = @org[:actor]
    @customer = create_customer(@actor, name: "Cliente <b>Teste</b>")
    @camera = create_product(@actor, sku: "CAM-TELA", tracking: "serialized", pricing: { "daily_cents" => 15_000 })
    register_assets(@actor, @camera, @org[:branch], 1)
    login("dona@alfa.test")
  end

  def form_quote(**extra)
    { "cliente_id" => @customer.id, "filial_id" => @org[:branch].id, "inicio" => "2026-03-10T05:00", "fim" => "2026-03-11T05:00",
      "validade" => "2026-03-06T18:00", "produto" => [@camera.id], "quantidade" => ["1"], "politica_bloqueio" => "none",
      "condicoes" => "<script>alert('x')</script> Entrega inclusa" }.merge(extra)
  end

  def get_ok(path)
    get path
  rescue Rack::Lint::LintError => e
    flunk "#{path}: #{e.message}"
  else
    assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
    last_response.body
  end

  ORDER_COLUMNS = { "quotes" => "created_at", "reservations" => "created_at", "contracts" => "issued_at" }.freeze

  def last_id(table) = owner_query("SELECT id FROM #{table} ORDER BY #{ORDER_COLUMNS.fetch(table)} DESC LIMIT 1").first["id"]

  def test_navigation_and_empty_states
    body = get_ok("/")

    assert_includes body, %(href="/orcamentos")
    assert_includes body, %(href="/contratos")
    assert_includes get_ok("/orcamentos"), "Nenhum orçamento encontrado"
    assert_includes get_ok("/contratos"), "Nenhum contrato encontrado"
    assert_includes get_ok("/orcamentos/novo"), "não garante disponibilidade"
    assert_includes get_ok("/clientes/#{@customer.id}"), "/orcamentos/novo?cliente_id=#{@customer.id}"
    assert_includes get_ok("/orcamentos/novo?cliente_id=#{@customer.id}"), %(value="#{@customer.id}" selected)
  end

  def test_quote_flow_through_the_screens_until_conversion
    post_form "/orcamentos", form_quote

    assert_equal 303, last_response.status, last_response.body[0, 600]
    quote_id = last_id("quotes")
    body = get_ok("/orcamentos/#{quote_id}")

    assert_includes body, "Q-000001"
    assert_includes body, "não garante disponibilidade"
    assert_includes body, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute_includes body, "<script>alert('x')</script>"
    post_form "/orcamentos/#{quote_id}/enviar", {}
    follow_redirect!

    assert_includes last_response.body, "não garante disponibilidade até a conversão"
    assert_includes get_ok("/orcamentos/#{quote_id}/nova-versao"), "Nova versão do orçamento Q-000001"
    post_form "/orcamentos/#{quote_id}/aprovar", { "versao" => "1", "aprovado_por" => "Maria Compradora" }
    follow_redirect!

    assert_includes last_response.body, "Maria Compradora"
    post_form "/orcamentos/#{quote_id}/converter", {}

    assert_equal 303, last_response.status
    assert_match %r{/reservas/}, last_response.location
    follow_redirect!
    reservation_body = last_response.body

    assert_includes reservation_body, "Convertida do orçamento"
    assert_includes reservation_body, "Gerar contrato"
    assert_includes get_ok("/orcamentos?situacao=converted"), "Q-000001"
  end

  def test_contract_flow_through_the_screens
    reservation_id = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)],
                             mode: "confirm").id

    assert_includes get_ok("/reservas/#{reservation_id}"), "Gerar contrato"
    post_form "/contratos", { "reserva_id" => reservation_id, "condicoes" => "Montagem no local" }

    assert_equal 303, last_response.status
    follow_redirect!
    contract_id = last_id("contracts")

    assert_includes last_response.body, "Contrato C-000001"
    assert_includes last_response.body, "aceite eletrônico simples"
    assert_includes last_response.body, "não equivale a assinatura digital certificada"
    assert_includes last_response.body, "Montagem no local"
    post_form "/contratos/#{contract_id}/aceite", { "nome" => "Maria Compradora", "documento" => "52998224725", "declaracao" => "1" }
    follow_redirect!

    assert_includes last_response.body, "Aceite eletrônico simples registrado"
    assert_includes last_response.body, "529.982.247-25"
    post_form "/contratos/#{contract_id}/aditivos", { "fim" => "2026-03-12T05:00", "descricao" => "Evento prorrogado" }
    follow_redirect!

    assert_includes last_response.body, "Aditivo 1 registrado"
    assert_includes last_response.body, "Evento prorrogado"
    assert_includes get_ok("/reservas/#{reservation_id}"), "alterações de prazo são feitas por aditivo"
    post_form "/contratos/#{contract_id}/cancelar", { "motivo" => "Cliente desistiu" }
    follow_redirect!

    assert_includes last_response.body, "Contrato cancelado"
    assert_includes get_ok("/contratos?situacao=cancelled"), "C-000001"
  end

  def test_quote_screens_report_errors_inline
    post_form "/orcamentos", form_quote("validade" => "2026-03-20T00:00")

    assert_equal 422, last_response.status
    assert_includes last_response.body, "deve terminar até o início da locação"
    assert_includes last_response.body, 'aria-invalid="true"'
    post_form "/orcamentos", form_quote("politica_bloqueio" => "hold_on_send", "validade_bloqueio" => "120")
    quote_id = last_id("quotes")
    reserve(@actor, create_customer(@actor, name: "Outro", document: "11144477735"), @org[:branch],
            period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    post_form "/orcamentos/#{quote_id}/enviar", {}

    assert_equal 409, last_response.status
    assert_includes last_response.body, "Sem disponibilidade para o bloqueio temporário"
    post_form "/orcamentos/#{quote_id}/aprovar", { "versao" => "1", "aprovado_por" => "Maria" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Transição inválida"
    post_form "/orcamentos/#{quote_id}/versoes", form_quote("politica_bloqueio" => "hold_on_send", "validade_bloqueio" => "120")

    assert_equal 422, last_response.status
    assert_includes last_response.body, "nenhuma alteração"
  end

  # O formulário de aceite da equipe envia a versão exibida: um aditivo feito depois da abertura da
  # página faz o aceite ser recusado sem gravação.
  def test_staff_acceptance_refuses_a_document_version_created_after_the_page_was_opened
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    contract = uc(:issue_contract).call(@actor, reservation.id)

    assert_includes get_ok("/contratos/#{contract.id}"), %(name="versao" value="1")
    uc(:amend_contract).call(@actor, contract.id, ends_at: t("2026-03-12T08:00:00Z"))
    post_form "/contratos/#{contract.id}/aceite", { "versao" => "1", "nome" => "Maria Compradora", "documento" => "52998224725", "declaracao" => "1" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "não é mais a vigente (versão vigente: 2)"
    assert_includes last_response.body, %(name="versao" value="2")
    assert_equal 0, owner_query("SELECT count(*) AS n FROM contract_documents WHERE accepted_at IS NOT NULL").first["n"].to_i
  end

  # O formulário de rejeição da equipe envia a versão exibida: um reenvio feito depois da abertura
  # da página faz a rejeição ser recusada sem gravação.
  def test_staff_rejection_refuses_a_quote_version_sent_after_the_page_was_opened
    post_form "/orcamentos", form_quote
    quote_id = last_id("quotes")
    post_form "/orcamentos/#{quote_id}/enviar", {}

    assert_equal 2, get_ok("/orcamentos/#{quote_id}").scan(%(name="versao" value="1")).size, "aprovação e rejeição enviam a versão"
    uc(:revise_quote).call(@actor, quote_id, { customer_id: @customer.id, branch_id: @org[:branch].id, lines: [line(@camera, 1)],
                                               period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"),
                                               valid_until: t("2026-03-06T12:00:00Z"), terms: "Retirada na loja." })
    uc(:send_quote).call(@actor, quote_id)
    post_form "/orcamentos/#{quote_id}/rejeitar", { "versao" => "1", "motivo" => "Cliente desistiu" }

    assert_equal 409, last_response.status
    assert_includes last_response.body, "versão atual: 2"
    assert_equal "sent", owner_query("SELECT status FROM quotes WHERE id = $1", [quote_id]).first["status"]
  end

  def test_contract_screens_report_conflicts_and_versions
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    contract = uc(:issue_contract).call(@actor, reservation.id)
    reserve(@actor, @customer, @org[:branch], period("2026-03-11T08:00:00Z", "2026-03-12T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    body = get_ok("/contratos/#{contract.id}")

    assert_includes body, "PDF versão 1"
    assert_includes body, "SHA-256"
    assert_includes body, "Prévia para cancelamento"
    post_form "/contratos/#{contract.id}/aditivos", { "fim" => "2026-03-11T17:00" }

    assert_equal 409, last_response.status
    assert_includes last_response.body, "Aditivo recusado"
    post_form "/contratos/#{contract.id}/aceite", { "nome" => "Maria", "documento" => "123" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "confirme a declaração de aceite"
    assert_includes last_response.body, "<details open>", "o formulário com erro permanece aberto"
    post_form "/reservas/#{reservation.id}/reagendar", { "inicio" => "2026-03-15T05:00", "fim" => "2026-03-16T05:00" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "aditivo"
    post_form "/contratos", { "reserva_id" => reservation.id }

    assert_equal 303, last_response.status
    assert_equal "/contratos/#{contract.id}", URI(last_response.location).path, "emissão repetida leva ao mesmo contrato"
    held = reserve(@actor, @customer, @org[:branch], period("2026-03-20T08:00:00Z", "2026-03-21T08:00:00Z"), [line(@camera, 1)])
    post_form "/contratos", { "reserva_id" => held.id }
    follow_redirect!

    assert_includes last_response.body, "reserva confirmada"
  end

  # A tela da reserva de bloqueio aponta o orçamento e não oferece confirmação, reagendamento nem
  # extensão diretos; a tentativa direta é recusada com a mensagem na própria tela.
  def test_quote_hold_reservation_screen_points_to_the_quote
    post_form "/orcamentos", form_quote("politica_bloqueio" => "hold_on_send", "validade_bloqueio" => "600")
    quote_id = last_id("quotes")
    post_form "/orcamentos/#{quote_id}/enviar", {}
    hold_id = owner_query("SELECT hold_reservation_id FROM quotes WHERE id = $1", [quote_id]).first["hold_reservation_id"]
    body = get_ok("/reservas/#{hold_id}")

    assert_includes body, "bloqueio temporário do orçamento"
    assert_includes body, %(href="/orcamentos/#{quote_id}")
    refute_includes body, "Confirmar reserva"
    refute_includes body, "Reagendar"
    refute_includes body, "Estender devolução"
    assert_includes body, "Cancelar reserva"
    post_form "/reservas/#{hold_id}/confirmar", {}

    assert_equal 422, last_response.status
    assert_includes last_response.body, "conversão do orçamento aprovado"
    body = get_ok("/orcamentos/#{quote_id}")

    assert_includes body, "Enviada ao cliente"
    refute_includes body, "não enviada (interna)"
  end

  # Depois da retirada a tela do contrato explica que não há mais cancelamento; concluída a locação,
  # o encerramento é oferecido mesmo sem aceite registrado.
  def test_contract_screen_after_pickup_offers_closing_instead_of_cancelling
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    contract = uc(:issue_contract).call(@actor, reservation.id)
    owner_query("UPDATE reservations SET status = 'in_progress' WHERE id = $1", [reservation.id])
    body = get_ok("/contratos/#{contract.id}")

    assert_includes body, "não pode mais ser cancelado"
    refute_includes body, "Prévia para cancelamento"
    refute_includes body, "Encerrar contrato"
    post_form "/contratos/#{contract.id}/cancelar", { "motivo" => "Desistência" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "encerrado após a devolução"
    owner_query("UPDATE reservations SET status = 'completed' WHERE id = $1", [reservation.id])
    body = get_ok("/contratos/#{contract.id}")

    assert_includes body, "Nenhum aceite eletrônico simples foi registrado"
    post_form "/contratos/#{contract.id}/encerrar", {}
    follow_redirect!

    assert_includes last_response.body, "Contrato encerrado"
  end

  def test_attendant_sees_quotes_and_contracts_without_cancellation
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    contract = uc(:issue_contract).call(@actor, reservation.id)
    invite = uc(:invite_member).call(@actor, email: "atendente@alfa.test", role: "attendant")
    token = "#{@org[:organization_id]}.segredo-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    uc(:accept_invitation).call(token: token, name: "Atendente", password: "senha-muito-segura-3")
    post_form "/sair", {}
    login("atendente@alfa.test", "senha-muito-segura-3")
    body = get_ok("/contratos/#{contract.id}")

    assert_includes body, "Registrar aceite"
    refute_includes body, "Cancelar contrato"
    post_form "/contratos/#{contract.id}/cancelar", { "motivo" => "sem permissão" }

    assert_equal 403, last_response.status
    assert_includes get_ok("/orcamentos/novo"), "Limite do seu papel: 5%"
  end

  def test_other_organization_resources_are_not_found
    reservation = reserve(@actor, @customer, @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), [line(@camera, 1)], mode: "confirm")
    contract = uc(:issue_contract).call(@actor, reservation.id)
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @org[:branch].id, lines: [line(@camera, 1)],
                                             period: period("2026-03-20T08:00:00Z", "2026-03-21T08:00:00Z"), valid_until: t("2026-03-06T00:00:00Z") })
    create_organization(name: "Locadora Beta", email: "beta@example.test")
    post_form "/sair", {}
    login("beta@example.test")
    get "/contratos/#{contract.id}"

    assert_equal 404, last_response.status
    get "/orcamentos/#{quote.id}"

    assert_equal 404, last_response.status
  end
end
