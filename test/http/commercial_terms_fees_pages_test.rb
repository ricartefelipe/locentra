# frozen_string_literal: true

require_relative "commercial_terms_http_helper"

# Telas do catálogo de tarifas adicionais (Rack::Lint): lista com filtros, cadastro com erros no campo,
# edição com controle otimista, desativação, reativação, histórico e acesso por papel.
class CommercialTermsFeesPagesTest < CommercialTermsHttpTest
  def fee_form(**extra)
    { "codigo" => "entrega", "nome" => "Entrega e retirada no local", "valor_padrao" => "150,00", "descricao" => "" }
      .merge(extra.transform_keys(&:to_s))
  end

  def edit_form(fee, **extra)
    { "versao" => fee.lock_version.to_s, "nome" => fee.name, "descricao" => fee.description.to_s,
      "valor_padrao" => fee.default_amount.to_decimal_string.tr(".", ",") }.merge(extra.transform_keys(&:to_s))
  end

  def test_creation_with_field_errors_and_repeated_code
    body = get_ok("/tarifas")

    assert_includes body, "Nenhuma tarifa encontrada."
    assert_includes body, "exigem a permissão de ajustar tarifas (gerente, administrador ou proprietário)"
    assert_includes get_ok("/tarifas/nova"), "Valor padrão (R$)"
    post_form "/tarifas", fee_form(codigo: "x", nome: "", valor_padrao: "0", descricao: "<b>interna</b>")

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-codigo" role="alert">use de 2 a 30 caracteres)
    assert_includes last_response.body, %(id="erro-nome" role="alert">obrigatório)
    assert_includes last_response.body, %(id="erro-valor_padrao" role="alert">valor positivo)
    assert_match(/id="valor_padrao"[^>]*value="0"[^>]*aria-invalid="true"/, last_response.body)
    assert_includes last_response.body, "&lt;b&gt;interna&lt;/b&gt;"
    post_form "/tarifas", fee_form

    assert_match %r{\A/tarifas/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z}, last_response.location
    follow_redirect!

    assert_includes last_response.body, "Tarifa ENTREGA cadastrada."
    assert_includes last_response.body, "<dd>R$ 150,00</dd>"
    assert_includes last_response.body, "<strong>Tarifa cadastrada</strong>"
    post_form "/tarifas", fee_form(nome: "Outra entrega", valor_padrao: "abc")

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-valor_padrao" role="alert">formato monetário inválido)
    post_form "/tarifas", fee_form(nome: "Outra entrega")

    assert_equal 409, last_response.status
    assert_includes last_response.body, %(id="erro-codigo" role="alert">já existe tarifa com o código ENTREGA)
    assert_includes last_response.body, %(value="Outra entrega")
  end

  def test_edit_with_optimistic_lock_and_null_operation
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    page = get_ok("/tarifas/#{fee.id}")

    assert_includes page, %(<input type="hidden" name="versao" value="1">)
    assert_includes page, "Alterar o valor padrão não muda reservas, orçamentos e contratos já registrados"
    assert_includes get_ok("/tarifas/entrega"), "Tarifa ENTREGA"
    post_form "/tarifas/#{fee.id}", edit_form(fee)
    follow_redirect!

    assert_includes last_response.body, "Nenhuma alteração a salvar."
    assert_empty audit_events("fee.updated")
    post_form "/tarifas/#{fee.id}", edit_form(fee, nome: "E", valor_padrao: "180,00")

    assert_equal 422, last_response.status
    form = block_with(last_response.body, %r{<details open>\s*<summary>Editar tarifa</summary>.*?</details>}m)

    assert_includes form, %(id="erro-nome" role="alert">deve ter entre 2 e 120 caracteres)
    assert_includes form, %(value="180,00")
    post_form "/tarifas/#{fee.id}", edit_form(fee, valor_padrao: "180,00")
    follow_redirect!

    assert_includes last_response.body, "Tarifa atualizada."
    assert_includes last_response.body, "<dd>R$ 180,00</dd>"
    assert_includes last_response.body, "<strong>Tarifa alterada</strong>"
    assert_includes last_response.body, "(valor padrão)"
    post_form "/tarifas/#{fee.id}", edit_form(fee, nome: "Edição concorrente")

    assert_equal 409, last_response.status
    stale = block_with(last_response.body, %r{<details open>\s*<summary>Editar tarifa</summary>.*?</details>}m)

    assert_includes last_response.body, "a tarifa foi alterada por outra operação; revise os valores atuais"
    assert_includes stale, %(value="180,00")
    assert_includes stale, %(<input type="hidden" name="versao" value="2">)
    refute_includes stale, "Edição concorrente"
  end

  # O navegador envia as quebras de linha do textarea como CRLF e conta cada uma como um caractere no
  # maxlength: o servidor normaliza antes de comparar e de medir.
  def test_textarea_line_breaks_do_not_create_false_changes_nor_count_twice
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000, description: "linha 1\nlinha 2")
    post_form "/tarifas/#{fee.id}", edit_form(fee, descricao: "linha 1\r\nlinha 2")
    follow_redirect!

    assert_includes last_response.body, "Nenhuma alteração a salvar."
    assert_empty audit_events("fee.updated")
    long = (["a" * 50] + Array.new(9) { "a" * 49 }).join("\r\n") # 500 caracteres no navegador, 509 bytes enviados
    post_form "/tarifas/#{fee.id}", edit_form(fee, descricao: long)
    follow_redirect!

    assert_includes last_response.body, "Tarifa atualizada."
    assert_equal([500, 0], uc(:get_fee).call(@actor, fee.id)[:fee].description.then { |text| [text.length, text.count("\r")] })
  end

  def test_deactivation_reactivation_and_list_filters
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    @clock.advance(60)
    create_fee("MONTAGEM", "Montagem e desmontagem", 25_000)

    assert_equal %w[ENTREGA MONTAGEM], get_ok("/tarifas").scan(%r{<td><a href="/tarifas/[^"]+">([^<]+)</a>}).flatten
    assert_equal %w[MONTAGEM ENTREGA], get_ok("/tarifas?ordem=-created_at").scan(%r{<td><a href="/tarifas/[^"]+">([^<]+)</a>}).flatten
    assert_includes get_ok("/tarifas/#{fee.id}"), "Desativar a tarifa ENTREGA?"
    post_form "/tarifas/#{fee.id}/desativar", {}
    follow_redirect!

    assert_includes last_response.body, "Tarifa desativada."
    assert_includes last_response.body, ">Inativa</span>"
    assert_includes last_response.body, "<strong>Tarifa desativada</strong>"
    post_form "/tarifas/#{fee.id}/desativar", {}
    follow_redirect!

    assert_includes last_response.body, "Nenhuma alteração a salvar."
    inactive = get_ok("/tarifas?situacao=inactive")

    assert_includes inactive, ">ENTREGA<"
    refute_includes inactive, ">MONTAGEM<"
    assert_includes get_ok("/tarifas?busca=montag"), ">MONTAGEM<"
    post_form "/tarifas/#{fee.id}/reativar", {}
    follow_redirect!

    assert_includes last_response.body, "Tarifa reativada."
    assert_includes last_response.body, ">Ativa</span>"
    assert_equal 1, audit_events("fee.deactivated").size
  end

  def test_access_follows_the_role
    fee = create_fee("ENTREGA", "Entrega e retirada no local", 15_000)
    sign_in_as("stock_operator")

    assert_includes get_ok("/"), %(<a href="/tarifas">Tarifas adicionais</a>)
    assert_includes get_ok("/tarifas"), ">ENTREGA<"
    sign_in_as("attendant")
    page = get_ok("/tarifas/#{fee.id}")

    refute_includes get_ok("/tarifas"), "Nova tarifa"
    refute_includes page, "Editar tarifa"
    refute_includes page, "Desativar tarifa"
    post_form "/tarifas", fee_form(codigo: "LIMPEZA")

    assert_equal 403, last_response.status
    post_form "/tarifas/#{fee.id}/desativar", {}

    assert_equal 403, last_response.status
    post "/tarifas/#{fee.id}", edit_form(fee, nome: "Sem token")

    assert_equal 403, last_response.status
    assert_equal([{ "code" => "ENTREGA", "name" => "Entrega e retirada no local" }], owner_query("SELECT code, name FROM additional_fees WHERE active"))
    get "/tarifas/#{SecureRandom.uuid}"

    assert_equal 404, last_response.status
  end
end
