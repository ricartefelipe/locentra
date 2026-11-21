# frozen_string_literal: true

require_relative "commercial_terms_http_helper"

# Condições negociadas na página do cliente (Rack::Lint): seção por permissão, cadastro com erros no
# campo e formulário reaberto, sobreposição, encerramento imediato e agendado e troca sem intervalo.
class CommercialTermsAgreementsPagesTest < CommercialTermsHttpTest
  NEW_FORM = %r{<details open>\s*<summary>Nova condição negociada</summary>.*?</details>}m
  END_FORM = %r{<details open>\s*<summary>Encerrar</summary>.*?</details>}m

  def customer_path = "/clientes/#{@customer.id}"
  def agreements_path = "#{customer_path}/condicoes"

  def agreement_form(**extra)
    { "produto" => "", "desconto" => "8", "valido_de" => "", "valido_ate" => "", "observacoes" => "Contrato anual" }
      .merge(extra.transform_keys(&:to_s))
  end

  def agreements = uc(:list_price_agreements).call(@actor, @customer.id).items

  def test_section_follows_the_permissions
    create_agreement(@customer, 800, notes: "Contrato <b>anual</b>")
    body = get_ok(customer_path)

    assert_includes body, %(<h2 id="condicoes-titulo">Condições negociadas</h2>)
    assert_includes body, "Todos os produtos"
    assert_includes body, "Contrato &lt;b&gt;anual&lt;/b&gt;"
    assert_includes body, "Dona Locadora Alfa"
    assert_includes body, %(<option value="CAM-CT">Câmera FX</option>)
    assert_includes body, "Vale o maior desconto entre a condição do produto e a geral"
    sign_in_as("attendant")
    read_only = get_ok(customer_path)

    assert_includes read_only, "Condições negociadas"
    refute_includes read_only, "Nova condição negociada"
    refute_includes read_only, "Encerrar condição"
    post_form agreements_path, agreement_form(produto: "CAM-CT")

    assert_equal 403, last_response.status
    post_form "#{agreements_path}/#{agreements.first[:agreement].id}/encerrar", { "motivo" => "sem permissão" }

    assert_equal 403, last_response.status
    sign_in_as("stock_operator")

    refute_includes get_ok(customer_path), "Condições negociadas"
    assert_equal 1, agreements.size
    assert_nil agreements.first[:agreement].ended_at
  end

  def test_creation_errors_reopen_the_form_with_the_submitted_values
    assert_includes get_ok(customer_path), "Nenhuma condição negociada para este cliente."
    post_form agreements_path, agreement_form(desconto: "95", valido_de: "2026-02-20T10:00", valido_ate: "2026-03-01T10:00")

    assert_equal 422, last_response.status
    form = block_with(last_response.body, NEW_FORM)

    assert_includes form, %(id="erro-desconto" role="alert">entre 0,01% e 90%)
    assert_includes form, %(id="erro-valido_de" role="alert">o início não pode estar mais de 24 horas no passado)
    assert_match(/id="condicao-desconto"[^>]*value="95"[^>]*aria-invalid="true"/, form)
    assert_includes form, %(value="2026-03-01T10:00")
    assert_includes form, ">Contrato anual</textarea>"
    assert_includes last_response.body, "<li>Início da vigência: "
    post_form agreements_path, agreement_form(desconto: "8,123", valido_ate: "amanhã")

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-desconto" role="alert">percentual inválido)
    assert_includes last_response.body, %(id="erro-valido_ate" role="alert">data e hora inválidas)
    post_form agreements_path, agreement_form(produto: "NAO-EXISTE")

    assert_equal 422, last_response.status
    assert_includes block_with(last_response.body, NEW_FORM), %(id="erro-produto" role="alert">produto não encontrado)
    assert_empty agreements
  end

  def test_general_and_product_agreements_and_overlap_on_the_start_field
    get customer_path
    post_form agreements_path, agreement_form

    assert_equal customer_path, last_response.location, "sem âncora, para que o aviso no topo fique visível"
    follow_redirect!

    assert_includes last_response.body, "Condição negociada cadastrada."
    assert_includes last_response.body, "<td>8%</td>"
    assert_includes last_response.body, "desde 02/03/2026 09:00"
    assert_includes last_response.body, ">Vigente</span>"
    post_form agreements_path, agreement_form(desconto: "5", valido_de: "2026-04-01T00:00")

    assert_equal 409, last_response.status
    overlap = block_with(last_response.body, NEW_FORM)

    assert_includes overlap, %(id="erro-valido_de" role="alert">já existe condição vigente ou agendada para este cliente e escopo no período)
    assert_includes overlap, %(value="2026-04-01T00:00")
    post_form agreements_path, agreement_form(produto: "cam-ct", desconto: "12,5", valido_de: "2026-04-01T00:00", valido_ate: "2026-05-01T00:00")
    follow_redirect!

    assert_includes last_response.body, "Câmera FX (CAM-CT)"
    assert_includes last_response.body, "<td>12,5%</td>"
    assert_includes last_response.body, "desde 01/04/2026 00:00 até 01/05/2026 00:00"
    assert_includes last_response.body, ">Agendada</span>"
    assert_equal 2, audit_events("price_agreement.created").size
  end

  def test_ending_requires_a_reason_and_can_be_scheduled_for_a_seamless_replacement
    agreement = create_agreement(@customer, 800)
    end_path = "#{agreements_path}/#{agreement.id}/encerrar"
    get customer_path
    post_form end_path, { "motivo" => "", "encerrar_em" => "2026-04-01T00:00" }

    assert_equal 422, last_response.status
    form = block_with(last_response.body, END_FORM)

    assert_includes form, %(id="erro-motivo" role="alert">obrigatório)
    assert_includes form, %(value="2026-04-01T00:00")
    refute_match(/<details open>\s*<summary>Nova condição negociada/, last_response.body)
    post_form end_path, { "motivo" => "Renegociação anual", "encerrar_em" => "2026-04-01T00:00" }

    assert_equal customer_path, last_response.location
    follow_redirect!

    assert_includes last_response.body, "Encerramento agendado para 01/04/2026 00:00."
    assert_includes last_response.body, "encerramento agendado para 01/04/2026 00:00 por Dona Locadora Alfa: Renegociação anual"
    assert_includes last_response.body, ">Vigente</span>"
    refute_includes last_response.body, "Encerrar condição"
    post_form agreements_path, agreement_form(desconto: "10", valido_de: "2026-04-01T00:00")
    follow_redirect!

    assert_includes last_response.body, ">Agendada</span>"
    assert_equal([[1000, "scheduled"], [800, "active"]], agreements.map { |row| [row[:agreement].discount_bps, row[:status]] })
    assert audit_events("price_agreement.ended").first["details"]["scheduled"]
  end

  def test_ending_now_allows_a_new_agreement_and_cannot_be_repeated
    agreement = create_agreement(@customer, 800)
    end_path = "#{agreements_path}/#{agreement.id}/encerrar"
    get customer_path
    post_form end_path, { "motivo" => "Contrato rescindido", "encerrar_em" => "" }
    follow_redirect!

    assert_includes last_response.body, "Condição negociada encerrada."
    assert_includes last_response.body, "Encerrada em 02/03/2026 09:00 por Dona Locadora Alfa: Contrato rescindido"
    assert_includes last_response.body, ">Encerrada</span>"
    post_form agreements_path, agreement_form(desconto: "6")

    assert_equal 303, last_response.status, last_response.body[0, 400]
    post_form end_path, { "motivo" => "De novo" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Transição inválida em condição negociada: Encerrada → Encerrada"
    other = create_customer(@actor, name: "Cliente Vizinho", document: "11144477735")
    post_form "/clientes/#{other.id}/condicoes/#{agreements.first[:agreement].id}/encerrar", { "motivo" => "Cliente errado" }

    assert_equal 404, last_response.status
    assert_nil agreements.first[:agreement].ended_at
  end

  # A condição expirada não oferece o encerramento, que o domínio recusaria.
  def test_expired_agreement_has_no_end_action
    create_agreement(@customer, 800, valid_until: @clock.now + 3_600)

    assert_includes get_ok(customer_path), "Encerrar condição"
    @clock.advance(3_600)
    page = get_ok(customer_path)

    assert_includes page, ">Expirada</span>"
    refute_includes page, "Encerrar condição"
  end

  def test_long_history_shows_the_first_hundred_with_a_notice
    owner_query(<<~SQL, [@org[:organization_id], @customer.id, t("2026-01-10T12:00:00Z")])
      INSERT INTO customer_price_agreements (id, organization_id, customer_id, discount_bps, valid_from, created_at, ended_at, end_reason)
      SELECT gen_random_uuid(), $1, $2, 100, $3::timestamptz + (n || ' minutes')::interval, $3, $3::timestamptz + (n || ' minutes')::interval, 'carga de teste'
        FROM generate_series(1, 101) AS n
    SQL
    body = get_ok(customer_path)

    assert_includes body, "Mostrando 100 de 101 condições"
    assert_equal 100, body.scan(">Encerrada</span>").size
  end
end
