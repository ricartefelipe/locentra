# frozen_string_literal: true

require_relative "commercial_terms_http_helper"

# Páginas da organização e das filiais (Rack::Lint): detalhe com vínculos, edição com controle otimista,
# desativação recusada e aceita, reativação, isolamento entre organizações, criação com erro no campo,
# formulários que listam só as filiais ativas e a visão de quem só lê a organização.
class OrganizationBranchesPagesTest < CommercialTermsHttpTest
  def setup
    super
    @north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE", address: "Av. Norte, 100")
  end

  def branch_path(branch = @north) = "/organizacao/filiais/#{branch.id}"
  def branch_row(branch = @north) = owner_query("SELECT name, active, lock_version FROM branches WHERE id = $1", [branch.id]).first

  def test_detail_edit_and_stale_version
    body = get_ok(branch_path)

    assert_includes body, "<h1>Filial NORTE"
    assert_includes body, "Código (não muda)"
    assert_includes body, "0 ativos · 0 unidades em estoque · 0 reservas em aberto · 0 orçamentos enviados ou aprovados · " \
                          "0 transferências pendentes com destino à filial"
    assert_includes body, %(data-confirm="Desativar a filial NORTE? Novas reservas)
    assert_includes body, "<strong>Filial criada</strong>"
    post_form branch_path, { "nome" => "Unidade Norte II", "endereco" => "Av. Norte, 200", "versao" => "1" }

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Filial atualizada."
    assert_includes last_response.body, "<strong>Filial alterada</strong>"
    post_form branch_path, { "nome" => "Outro nome", "endereco" => "", "versao" => "1" }

    assert_equal 409, last_response.status
    assert_includes last_response.body, "a filial foi alterada por outra operação; revise os valores atuais"
    assert_includes last_response.body, %(value="Unidade Norte II")
    post_form branch_path, { "nome" => "N", "endereco" => "x" * 301, "versao" => "2" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "até 300 caracteres"
    assert_includes last_response.body, %(<details open>)
    assert_equal({ "name" => "Unidade Norte II", "active" => "t", "lock_version" => "2" }, branch_row)
  end

  def test_deactivation_refused_with_an_open_reservation_then_accepted_and_reactivated
    register_assets(@actor, @camera, @north, 1, prefix: "CAM-N")
    reservation = reserve(@actor, @customer, @north, rental, [line(@camera, 1)], mode: "confirm")
    get_ok(branch_path)
    post_form "#{branch_path}/desativar", {}

    assert_equal 409, last_response.status
    assert_includes last_response.body, "Não é possível desativar a filial NORTE: 1 reserva em aberto (#{reservation.code}): conclua ou cancele."
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Desistência")
    post_form "#{branch_path}/desativar", {}

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Filial desativada. Reservas, orçamentos e contratos já registrados não mudam; ativos e estoque continuam " \
                                        "vinculados e podem ser transferidos."
    assert_includes last_response.body, "Reativar filial"
    assert_includes get_ok("/organizacao"), "Inativa desde 02/03/2026"
    post_form "#{branch_path}/desativar", {}
    follow_redirect!

    assert_includes last_response.body, "A filial já estava inativa."
    post_form "#{branch_path}/reativar", {}
    follow_redirect!

    assert_includes last_response.body, "Filial reativada."
    post_form "#{branch_path}/reativar", {}
    follow_redirect!

    assert_includes last_response.body, "A filial já estava ativa."
  end

  def test_last_active_branch_and_other_organizations
    uc(:set_branch_active).call(@actor, @north.id, active: false)
    get_ok(branch_path(@branch))
    post_form "#{branch_path(@branch)}/desativar", {}

    assert_equal 409, last_response.status
    assert_includes last_response.body, "A organização precisa de ao menos uma filial ativa."
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    get branch_path(beta[:branch])

    assert_equal 404, last_response.status
    post_form "#{branch_path(beta[:branch])}/desativar", {}

    assert_equal 404, last_response.status
    assert_equal "t", owner_query("SELECT active FROM branches WHERE id = $1", [beta[:branch].id], tenant: beta[:organization_id]).first["active"]
  end

  # Limite de filiais do plano Profissional (3): a criação acima dele volta ao formulário com o erro geral
  # e os valores, e a reativação acima dele responde 409 na página da filial, sem alterar nada.
  def test_plan_limit_refuses_the_creation_and_the_reactivation_on_the_pages
    uc(:set_branch_active).call(@actor, @north.id, active: false)
    uc(:create_branch).call(@actor, name: "Unidade Sul", code: "SUL")
    uc(:create_branch).call(@actor, name: "Unidade Leste", code: "LESTE")
    limit = "Limite de filiais do plano Profissional atingido (3)"
    get_ok("/organizacao")
    post_form "/organizacao/filiais", { "nome" => "Unidade Oeste", "codigo" => "OESTE", "endereco" => "Rua Oeste, 9" }

    assert_equal 422, last_response.status
    assert_includes last_response.body[%r{<div class="form-errors".*?</div>}m], limit
    refute_includes last_response.body, %(id="erro-codigo")
    assert_includes last_response.body, %(value="Unidade Oeste")
    post_form "#{branch_path}/reativar", {}

    assert_equal 409, last_response.status
    assert_includes last_response.body, "<h1>Filial NORTE"
    assert_includes last_response.body, limit
    assert_includes last_response.body, "Reativar filial"
    assert_equal "f", branch_row["active"]
  end

  def test_failed_creation_keeps_the_values_and_marks_the_code
    get_ok("/organizacao")
    post_form "/organizacao/filiais", { "nome" => "Unidade Sul", "codigo" => "NORTE", "endereco" => "Rua Sul, 5" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-codigo")
    assert_includes last_response.body, %(value="Unidade Sul")
    assert_includes last_response.body, %(value="Rua Sul, 5")
    assert_match(/id="codigo"[^>]*value="NORTE"[^>]*aria-invalid="true"/, last_response.body)
  end

  def test_creation_forms_list_only_active_branches_and_stock_forms_mark_the_inactive_one
    chairs = create_product(@actor, sku: "CAD-BR", tracking: "bulk")
    uc(:set_branch_active).call(@actor, @north.id, active: false)
    new_reservation = get_ok("/reservas/nova")

    assert_includes new_reservation, "Matriz (MATRIZ)"
    refute_includes new_reservation, "NORTE"
    camera_page = get_ok("/produtos/#{@camera.id}")

    refute_includes camera_page, "Unidade Norte"
    stock_page = get_ok("/produtos/#{chairs.id}")

    assert_includes stock_page, "Unidade Norte (inativa)"
    assert_includes stock_page, "Filiais inativas aceitam somente baixa e perda."
    transfers = get_ok("/transferencias")

    assert_match(/id="origem_id".*Unidade Norte \(inativa\)/m, transfers)
    refute_match(/id="destino-ativo"[^\n]*Unidade Norte/, transfers)
  end

  # A nova versão de um orçamento cuja filial foi desativada mantém a filial atual selecionada, marcada como
  # inativa e com aviso; o envio sem trocar de filial é recusado no campo, em vez de gravar em outra filial.
  def test_quote_revision_keeps_the_inactive_branch_selected_and_refuses_it
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @north.id, period: rental, lines: [line(@camera, 1)],
                                             valid_until: t("2026-03-05T12:00:00Z") })
    uc(:set_branch_active).call(@actor, @north.id, active: false)
    body = get_ok("/orcamentos/#{quote.id}/nova-versao")
    select = body[%r{<select id="filial_id".*?</select>}m]

    assert_includes select, %(<option value="#{@north.id}" selected>Unidade Norte (NORTE) (inativa)</option>)
    assert_includes select, "Matriz (MATRIZ)"
    assert_includes body, %(aria-describedby="ajuda-filial")
    assert_includes body, "A filial deste orçamento está inativa: escolha uma filial ativa para a nova versão."
    post_form "/orcamentos/#{quote.id}/versoes", { "filial_id" => @north.id, "inicio" => "2026-03-10T09:00", "fim" => "2026-03-12T09:00",
                                                   "validade" => "2026-03-05T09:00", "produto" => [@camera.id], "quantidade" => ["1"],
                                                   "politica_bloqueio" => "none" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "filial inativa: escolha uma filial ativa"
    assert_match(/id="filial_id"[^>]*aria-invalid="true"/, last_response.body)
    assert_equal 1, owner_query("SELECT count(*) AS n FROM quote_versions WHERE quote_id = $1", [quote.id]).first["n"].to_i
  end

  # A primeira filial pelo nome está inativa: o calendário abre na primeira ativa e continua aceitando a
  # inativa quando escolhida.
  def test_calendar_defaults_to_the_first_active_branch
    depot = uc(:create_branch).call(@actor, name: "Almoxarifado", code: "ALMOX")
    uc(:set_branch_active).call(@actor, depot.id, active: false)
    calendar = get_ok("/disponibilidade")[%r{<select id="filial".*?</select>}m]

    assert_includes calendar, %(<option value="#{@branch.id}" selected>Matriz</option>)
    assert_includes calendar, %(<option value="#{depot.id}">Almoxarifado (inativa)</option>)
    assert_includes get_ok("/disponibilidade?filial=#{depot.id}"), %(<option value="#{depot.id}" selected>Almoxarifado (inativa)</option>)
  end

  def test_reader_sees_the_organization_without_forms_or_subscription
    sign_in_as("manager")
    home = get_ok("/")

    assert_includes home, %(<a href="/organizacao">Organização</a>)
    body = get_ok("/organizacao")

    assert_includes body, "Unidade Norte"
    assert_includes body, "Detalhes"
    ["Nova filial", "Editar configurações", "Assinatura", "Profissional"].each { |text| refute_includes body, text }
    detail = get_ok(branch_path)

    refute_includes detail, "Desativar filial"
    refute_includes detail, "Histórico"
    post_form "/organizacao/filiais", { "nome" => "Unidade Sul", "codigo" => "SUL" }

    assert_equal 403, last_response.status
    post_form branch_path, { "nome" => "Invasão", "endereco" => "", "versao" => "1" }

    assert_equal 403, last_response.status
    post_form "#{branch_path}/desativar", {}

    assert_equal 403, last_response.status
    sign_in_as("auditor")

    assert_includes get_ok(branch_path), "Histórico"
    assert_equal({ "name" => "Unidade Norte", "active" => "t", "lock_version" => "1" }, branch_row)
  end
end
