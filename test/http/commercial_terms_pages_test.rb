# frozen_string_literal: true

require_relative "commercial_terms_http_helper"

# Telas de cupons (Rack::Lint): menu por papel, lista com filtros, cadastro com erros no campo, página
# do cupom com usos e histórico, edição com controle otimista, desativação, reativação e exclusão.
class CommercialTermsPagesTest < CommercialTermsHttpTest
  def coupon_form(**extra)
    { "codigo" => "bemvindo10", "tipo" => "percent", "valor" => "10", "descricao" => "Boas-vindas" }.merge(extra.transform_keys(&:to_s))
  end

  def edit_form(coupon, **extra)
    { "versao" => coupon.lock_version.to_s, "descricao" => coupon.description.to_s, "valido_de" => "", "valido_ate" => "",
      "maximo_usos" => coupon.max_redemptions.to_s, "subtotal_minimo" => "" }.merge(extra.transform_keys(&:to_s))
  end

  def test_menu_and_access_follow_the_role
    body = get_ok("/")

    assert_includes body, %(<a href="/cupons">Cupons</a>)
    assert_includes get_ok("/cupons"), %(href="/cupons/novo")
    sign_in_as("attendant")

    assert_includes get_ok("/"), %(<a href="/cupons">Cupons</a>)
    refute_includes get_ok("/cupons"), "Novo cupom"
    get "/cupons/novo"
    post_form "/cupons", coupon_form

    assert_equal 403, last_response.status
    assert_empty owner_query("SELECT 1 FROM coupons")
    sign_in_as("stock_operator")

    refute_includes get_ok("/"), %(href="/cupons")
    get "/cupons"

    assert_equal 403, last_response.status
  end

  def test_list_filters_sorting_pagination_and_portuguese_statuses
    create_coupon("VIGENTE", description: "Campanha de outono")
    create_coupon("AGENDADO", valid_from: t("2026-04-01T03:00:00Z"))
    create_coupon("EXPIRA", valid_until: t("2026-03-02T12:10:00Z"))
    create_coupon("UNICO", max_redemptions: 1)
    uc(:set_coupon_active).call(@actor, create_coupon("PARADO").id, active: false)
    reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], coupon_code: "UNICO")
    @clock.advance(900)
    body = get_ok("/cupons")

    %w[Vigente Agendado Expirado Esgotado Desativado].each { |status| assert_includes body, ">#{status}</span>" }
    assert_includes body, "desde 01/04/2026 00:00"
    assert_includes body, "até 02/03/2026 09:10"
    assert_includes body, "sem prazo"
    assert_includes body, "<td>1 de 1</td>"
    assert_includes body, "Horários no fuso America/Sao_Paulo."
    refute_match(/>(active|scheduled|expired|exhausted|inactive)</, body)
    scheduled = get_ok("/cupons?situacao=scheduled")

    assert_includes scheduled, "AGENDADO"
    refute_includes scheduled, ">VIGENTE<"
    assert_includes scheduled, %(<option value="scheduled" selected>)
    assert_includes get_ok("/cupons?busca=outono"), ">VIGENTE<"
    refute_includes get_ok("/cupons?busca=outono"), ">UNICO<"
    assert_includes get_ok("/cupons?busca=100%25"), "Nenhum cupom encontrado."
    first = get_ok("/cupons?limite=2&ordem=code")

    assert_equal %w[AGENDADO EXPIRA], first.scan(%r{<td><a href="/cupons/[^"]+">([^<]+)</a>}).flatten
    assert_includes first, "/cupons?ordem=code&amp;inicio=2"
    assert_includes first, "1–2 de 5"
    assert_includes get_ok("/cupons?limite=2&ordem=code&inicio=2"), ">PARADO<"
    get "/cupons?situacao=inexistente"

    assert_equal 422, last_response.status
  end

  def test_format_errors_are_reported_together_on_their_fields
    assert_includes get_ok("/cupons/novo"), %(autocapitalize="characters")
    post_form "/cupons", coupon_form(valor: "abc", valido_de: "2026-02-30T10:00", subtotal_minimo: "x")

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-valor" role="alert">percentual inválido)
    assert_includes last_response.body, %(id="erro-valido_de" role="alert">data e hora inválidas)
    assert_includes last_response.body, %(id="erro-subtotal_minimo" role="alert">formato monetário inválido)
    assert_includes last_response.body, %(value="abc")
    assert_empty owner_query("SELECT 1 FROM coupons")
  end

  def test_creation_errors_keep_values_and_point_to_the_fields
    get "/cupons/novo"
    post_form "/cupons", coupon_form(codigo: "ab", valor: "150", valido_ate: "2026-02-01T10:00", maximo_usos: "0",
                                     descricao: "<script>alert('x')</script>")

    assert_equal 422, last_response.status
    body = last_response.body

    assert_match(/id="codigo"[^>]*value="ab"[^>]*aria-invalid="true" aria-describedby="ajuda-codigo erro-codigo"/, body)
    assert_includes body, %(<p class="field-error" id="erro-codigo" role="alert">use de 3 a 40 caracteres)
    assert_includes body, %(id="erro-valor" role="alert">entre 0,01% e 100%)
    assert_includes body, %(id="erro-maximo_usos" role="alert">entre 1 e 1.000.000)
    assert_includes body, %(id="erro-valido_ate" role="alert">não pode estar no passado)
    assert_includes body, "<li>Máximo de usos: "
    assert_includes body, %(value="2026-02-01T10:00")
    assert_includes body, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute_includes body, "<script>alert('x')</script>"
  end

  def test_creation_redirects_to_the_coupon_and_repeated_code_is_a_field_error
    get "/cupons/novo"
    post_form "/cupons", coupon_form(tipo: "fixed", valor: "50,00", subtotal_minimo: "300,00", maximo_usos: "1")

    assert_equal 303, last_response.status, last_response.body[0, 400]
    assert_match %r{\A/cupons/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z}, last_response.location
    follow_redirect!

    assert_includes last_response.body, "Cupom BEMVINDO10 cadastrado."
    assert_includes last_response.body, "<dd>R$ 50,00</dd>"
    assert_includes last_response.body, "<dd>R$ 300,00</dd>"
    assert_includes last_response.body, "0 de 1; restantes: 1"
    post_form "/cupons", coupon_form(codigo: "BemVindo10", valor: "12,5")

    assert_equal 409, last_response.status
    assert_includes last_response.body, %(id="erro-codigo" role="alert">já existe cupom com o código BEMVINDO10)
    assert_includes last_response.body, %(value="12,5")
    assert_equal 1, owner_query("SELECT count(*) AS n FROM coupons").first["n"].to_i
  end

  def test_requests_without_csrf_token_are_refused
    post "/cupons", coupon_form

    assert_equal 403, last_response.status
    coupon = create_coupon("SEMTOKEN")
    post "/cupons/#{coupon.id}/desativar", {}

    assert_equal 403, last_response.status
    assert coupon_data(coupon.id)[:coupon].active
  end

  def test_coupon_page_shows_uses_and_history
    coupon = create_coupon("TESTE10", description: "Dez <b>por cento</b>")
    reservation = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], coupon_code: "teste10")
    body = get_ok("/cupons/#{coupon.id}")

    assert_includes body, "Cupom TESTE10"
    assert_includes body, ">Vigente</span>"
    assert_includes body, "1 (sem limite)"
    assert_includes body, "Dez &lt;b&gt;por cento&lt;/b&gt;"
    assert_includes body, %(<a href="/reservas/#{reservation.id}">#{reservation.code}</a>)
    assert_includes body, "Produtora Horizonte"
    assert_includes body, "−R$ 90,00"
    assert_includes body, ">Ativo</span>"
    assert_includes body, "<strong>Cupom cadastrado</strong>"
    refute_includes body, "Excluir cupom"
    assert_includes get_ok("/cupons/teste10"), "Cupom TESTE10"
    post_form "/cupons/#{coupon.id}/excluir", {}

    assert_equal 409, last_response.status
    assert_includes last_response.body, "o cupom TESTE10 já foi usado e não pode ser excluído; desative-o"
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "cliente desistiu")
    released = get_ok("/cupons/#{coupon.id}")

    assert_includes released, "0 (sem limite)"
    assert_includes released, "Liberado: reserva cancelada"
  end

  def test_uses_are_paginated_with_their_own_offset
    coupon = create_coupon("MUITOS")
    26.times { reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "request", coupon_code: "MUITOS") }
    first = get_ok("/cupons/#{coupon.id}")

    assert_includes first, "26 (sem limite)"
    assert_includes first, %(aria-label="Paginação dos usos")
    assert_includes first, "1–25 de 26"
    assert_includes first, %(href="/cupons/#{coupon.id}?inicio_usos=25")
    assert_equal 25, first.scan(">Ativo</span>").size
    assert_equal 1, get_ok("/cupons/#{coupon.id}?inicio_usos=25").scan(">Ativo</span>").size
  end

  def test_deactivation_reactivation_and_repeated_action
    coupon = create_coupon("PAUSA")

    assert_includes get_ok("/cupons/#{coupon.id}"), "Desativar o cupom PAUSA? Reservas já registradas não mudam."
    post_form "/cupons/#{coupon.id}/desativar", {}
    follow_redirect!

    assert_includes last_response.body, "Cupom desativado. Reservas já registradas não mudam."
    assert_includes last_response.body, ">Desativado</span>"
    assert_includes last_response.body, "<strong>Cupom desativado</strong>"
    assert_includes last_response.body, "Reativar cupom"
    post_form "/cupons/#{coupon.id}/desativar", {}
    follow_redirect!

    assert_includes last_response.body, "Nenhuma alteração a salvar."
    assert_equal 1, audit_events("coupon.deactivated").size
    post_form "/cupons/#{coupon.id}/reativar", {}
    follow_redirect!

    assert_includes last_response.body, "Cupom reativado."
    assert coupon_data(coupon.id)[:coupon].active
  end

  def test_unused_coupon_is_deleted_and_missing_coupon_is_not_found
    coupon = create_coupon("DESCARTE")
    body = get_ok("/cupons/#{coupon.id}")

    assert_includes body, "Este cupom ainda não foi usado."
    assert_includes body, "Excluir o cupom DESCARTE? Esta ação não pode ser desfeita."
    post_form "/cupons/#{coupon.id}/excluir", {}

    assert_equal "/cupons", last_response.location
    follow_redirect!

    assert_includes last_response.body, "Cupom excluído."
    assert_includes last_response.body, "Nenhum cupom encontrado."
    get "/cupons/#{coupon.id}"

    assert_equal 404, last_response.status
    get "/cupons/NAOEXISTE"

    assert_equal 404, last_response.status
  end

  def test_read_only_roles_and_other_organizations
    coupon = create_coupon("ALFA10")
    sign_in_as("auditor")
    page = get_ok("/cupons/#{coupon.id}")

    refute_includes get_ok("/cupons"), "Novo cupom"
    refute_includes page, "Editar cupom"
    refute_includes page, "Desativar cupom"
    post_form "/cupons/#{coupon.id}", edit_form(coupon, descricao: "Sem permissão")

    assert_equal 403, last_response.status
    post_form "/cupons/#{coupon.id}/excluir", {}

    assert_equal 403, last_response.status
    create_organization(name: "Locadora Beta", email: "dona@beta.test")
    post_form "/sair", {}
    login("dona@beta.test")

    assert_includes get_ok("/cupons"), "Nenhum cupom encontrado."
    get "/cupons/#{coupon.id}"

    assert_equal 404, last_response.status
    get "/cupons/ALFA10"

    assert_equal 404, last_response.status
    post_form "/cupons/#{coupon.id}/desativar", {}

    assert_equal 404, last_response.status
    post_form "/cupons", coupon_form(codigo: "ALFA10")

    assert_equal 303, last_response.status, "o mesmo código é independente em outra organização"
    assert_nil coupon_data(coupon.id)[:coupon].description
  end

  def test_edit_with_optimistic_lock_null_operation_and_field_errors
    coupon = create_coupon("EDITAVEL", description: "Original", max_redemptions: 5, valid_until: t("2026-06-01T03:00:30Z"))
    page = get_ok("/cupons/#{coupon.id}")

    assert_includes page, %(<input type="hidden" name="versao" value="1">)
    assert_includes page, "Código, tipo e desconto não mudam; para outro desconto, cadastre um novo cupom."
    post_form "/cupons/#{coupon.id}", edit_form(coupon, valido_ate: "2026-06-01T00:00")
    follow_redirect!

    assert_includes last_response.body, "Nenhuma alteração a salvar."
    assert_empty audit_events("coupon.updated")
    post_form "/cupons/#{coupon.id}", edit_form(coupon, valido_ate: "2026-06-01T00:00", maximo_usos: "0", descricao: "Tentativa")

    assert_equal 422, last_response.status
    form = block_with(last_response.body, %r{<details open>\s*<summary>Editar cupom</summary>.*?</details>}m)

    assert_includes form, %(id="erro-maximo_usos" role="alert">entre 1 e 1.000.000)
    assert_includes form, %(value="Tentativa")
    assert_match(/id="e-maximo_usos"[^>]*value="0"[^>]*aria-invalid="true"/, form)
    post_form "/cupons/#{coupon.id}", edit_form(coupon, valido_ate: "2026-06-01T00:00", descricao: "Nova descrição", maximo_usos: "")
    follow_redirect!

    assert_includes last_response.body, "Cupom atualizado."
    assert_includes last_response.body, "<strong>Cupom alterado</strong>"
    assert_includes last_response.body, "(descrição, máximo de usos)"
    assert_equal({ "description" => ["Original", "Nova descrição"], "max_redemptions" => [5, nil] }, audit_events("coupon.updated").first["details"]["changes"])
    post_form "/cupons/#{coupon.id}", edit_form(coupon, descricao: "Edição concorrente")

    assert_equal 409, last_response.status
    stale = block_with(last_response.body, %r{<details open>\s*<summary>Editar cupom</summary>.*?</details>}m)

    assert_includes last_response.body, "o cupom foi alterado por outra operação; revise os valores atuais"
    assert_includes stale, %(value="Nova descrição")
    assert_includes stale, %(<input type="hidden" name="versao" value="2">)
    refute_includes stale, "Edição concorrente"
    assert_equal "Nova descrição", coupon_data(coupon.id)[:coupon].description
  end
end
