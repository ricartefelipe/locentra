# frozen_string_literal: true

require_relative "commercial_terms_http_helper"
require_relative "../support/organization_settings_support"

# Tela de configurações da organização (Rack::Lint): campos e acessibilidade, salvamento com aviso,
# recusa com os valores e a versão enviados, pré-visualização e restauração dos valores padrão sem
# gravar, controle otimista entre abas, confirmação da troca de fuso, efeito nos formulários de reserva,
# histórico e formulários abertos antes de uma troca de fuso.
class OrganizationSettingsPagesTest < CommercialTermsHttpTest
  include OrganizationSettingsSupport

  PATH = "/organizacao/configuracoes"
  SAVED = "Configurações salvas. Reservas, orçamentos e contratos já registrados mantêm a política e os valores do registro."

  def settings_form(**extra)
    { "acao" => "salvar", "versao" => "1", "nome" => "Locadora Alfa", "fuso_horario" => "America/Sao_Paulo", "validade_bloqueio" => "30",
      "antecedencia_horas" => %w[72 24 0], "multa_percentual" => %w[0 30 100] }.merge(extra.transform_keys(&:to_s))
  end

  def lock_version = owner_query("SELECT lock_version FROM organizations WHERE id = $1", [@org[:organization_id]]).first["lock_version"].to_i
  def settings_events = owner_query("SELECT count(*) AS n FROM audit_events WHERE action = 'organization.settings_updated'").first["n"].to_i

  def save(**extra)
    get_ok(PATH)
    post_form PATH, settings_form(**extra)
  end

  def test_owner_sees_an_accessible_form_and_the_manager_is_refused
    body = get_ok(PATH)

    %w[nome fuso_horario confirmar_fuso validade_bloqueio antecedencia_horas[] multa_percentual[] versao].each do |field|
      assert_includes body, %(name="#{field}"), field
    end
    assert_includes body, "<h1>Configurações da organização</h1>"
    assert_includes body, %(aria-describedby="consequencias-fuso")
    assert_includes body, %(id="consequencias-fuso")
    assert_includes body, "Há 0 reservas em aberto, 0 contratos em aberto e 0 cupons e condições negociadas com vigência futura."
    assert_includes body, "Brasília (SP, RJ, MG, ES, PR, SC, RS, GO, DF) — UTC−03:00 (atual)"
    assert_includes body, "Manaus (leste do AM) — UTC−04:00"
    assert_includes body, %(<span class="sr-only">Faixa 2: </span>Antecedência mínima (horas))
    assert_includes body, %(<span class="sr-only">Nova faixa: </span>Multa (%))
    assert_includes body, %(aria-label="Remover nova faixa")
    assert_includes body, "Adicionar faixa"
    assert_match(/<section id="previa-politica"[^>]*aria-live="polite"/, body)
    assert_includes body, "Exemplo sobre um contrato de R$ 1.000,00"
    refute_match(/<script(?![^>]*\ssrc=)[^>]*>/, body)
    refute_match(/\son[a-z]+="/, body)
    sign_in_as("manager")
    get PATH

    assert_equal 403, last_response.status
    post_form PATH, settings_form(validade_bloqueio: "45")

    assert_equal 403, last_response.status
    assert_equal 1, lock_version
  end

  def test_saving_redirects_with_the_notice_and_renaming_keeps_the_defaults
    save(nome: "Locadora Alfa Eventos")

    assert_equal 303, last_response.status
    assert_equal PATH, URI(last_response.location).path
    follow_redirect!

    assert_includes last_response.body, SAVED
    assert_equal 2, lock_version
    body = get_ok("/organizacao")

    assert_includes body, "<h1>Locadora Alfa Eventos</h1>"
    assert_includes body, "30 minutos (padrão)"
    assert_includes body, "Política de cancelamento (padrão)"
    save(nome: "Locadora Alfa Eventos", versao: "2")
    follow_redirect!

    assert_includes last_response.body, "Nenhuma alteração a salvar."
    assert_equal [2, 1], [lock_version, settings_events]
  end

  def test_invalid_submission_keeps_every_value_and_marks_the_line
    save(nome: "Locadora Renomeada", validade_bloqueio: "60", antecedencia_horas: ["72", "", "9999", "0"], multa_percentual: ["0", "", "30", "100"])

    assert_equal 422, last_response.status
    body = last_response.body

    assert_includes body, "faixa 2: antecedência deve ser um número inteiro de horas entre 0 e 8760"
    assert_includes body, %(id="erro-faixa-2")
    assert_match(/id="antecedencia-1"[^>]*value="9999" aria-invalid="true" aria-describedby="erro-faixa-2"/, body)
    refute_match(/id="antecedencia-0"[^>]*aria-invalid/, body)
    assert_includes body, %(value="Locadora Renomeada")
    assert_includes body, %(name="validade_bloqueio" type="number" min="5" max="1440" step="1" inputmode="numeric" required value="60")
    assert_equal(%w[72 9999 0], body.scan(/name="antecedencia_horas\[\]"[^>]*value="([^"]*)"/).flatten.reject(&:empty?))
    assert_includes body, %(<input type="hidden" name="versao" value="1">)
    assert_equal [1, 0], [lock_version, settings_events]
  end

  def test_preview_shows_the_policy_in_canonical_order_without_saving
    get_ok(PATH)
    post_form PATH, settings_form(acao: "previsualizar", validade_bloqueio: "90", antecedencia_horas: %w[0 48], multa_percentual: ["50", "12,5"])

    assert_equal 200, last_response.status
    body = last_response.body

    assert_includes body, "48 h ou mais antes do início: multa de 12,5% do valor contratado"
    assert_includes body, "menos de 48 h antes do início (ou após o início): multa de 50% do valor contratado"
    assert_includes body, "<td>menos de 48 h ou após o início</td><td class=\"num\">50%</td><td class=\"num\">R$ 500,00</td>"
    assert_includes body, "Bloqueios criados sem validade informada vencem em 90 minutos."
    assert_equal(%w[48 0], body.scan(/name="antecedencia_horas\[\]"[^>]*value="([^"]*)"/).flatten.reject(&:empty?))
    refute_includes body, "Agora:"
    assert_equal [1, 0], [lock_version, settings_events]
  end

  def test_preview_of_a_time_zone_change_needs_no_confirmation_and_shows_the_comparison
    get_ok(PATH)
    post_form PATH, settings_form(acao: "previsualizar", fuso_horario: "America/Manaus")

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Agora: 02/03/2026 09:00 em America/Sao_Paulo → 02/03/2026 08:00 em America/Manaus"
    assert_includes last_response.body, "Para salvar, marque a confirmação da troca do fuso horário."
    assert_includes last_response.body, %(<option value="America/Manaus" selected>)
    assert_equal 1, lock_version
  end

  def test_restoring_the_defaults_fills_the_fields_without_saving
    change_settings(hold_minutes: "60", cancellation_rows: [%w[0 50]])
    get_ok(PATH)
    post_form PATH, settings_form(acao: "restaurar_padrao", versao: "2", nome: "Nome Digitado", validade_bloqueio: "60",
                                  antecedencia_horas: ["0"], multa_percentual: ["50"])

    assert_equal 200, last_response.status
    body = last_response.body

    assert_includes body, %(required value="30")
    assert_equal(%w[72 24 0], body.scan(/name="antecedencia_horas\[\]"[^>]*value="([^"]*)"/).flatten.reject(&:empty?))
    assert_equal(%w[0 30 100], body.scan(/name="multa_percentual\[\]"[^>]*value="([^"]*)"/).flatten.reject(&:empty?))
    assert_includes body, %(value="Nome Digitado")
    assert_includes body, %(<input type="hidden" name="versao" value="2">)
    assert_equal [2, 60], [lock_version, current_organization.hold_minutes]
  end

  def test_tab_opened_before_another_save_gets_a_conflict
    get_ok(PATH)
    admin = staff_member(@org, "admin@alfa.test", "admin")
    change_settings(actor: admin, hold_minutes: "45")
    post_form PATH, settings_form(acao: "previsualizar", validade_bloqueio: "60")

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(<input type="hidden" name="versao" value="1">)
    post_form PATH, settings_form(validade_bloqueio: "60")

    assert_equal 409, last_response.status
    assert_includes last_response.body, "as configurações da organização foram alteradas por outra operação; revise os valores atuais"
    assert_includes last_response.body, %(<input type="hidden" name="versao" value="2">)
    assert_includes last_response.body, %(required value="45")
    assert_equal [2, 1, 45], [lock_version, settings_events, current_organization.hold_minutes]
  end

  def test_time_zone_change_requires_the_confirmation_and_applies_to_the_reservation_form
    save(fuso_horario: "America/Manaus")

    assert_equal 422, last_response.status
    assert_includes last_response.body, %(id="erro-confirmar_fuso")
    assert_includes last_response.body, "confirme a troca do fuso horário depois de ler as consequências"
    assert_includes last_response.body, %(aria-describedby="consequencias-fuso erro-confirmar_fuso")
    assert_equal 1, lock_version
    save(fuso_horario: "America/Manaus", confirmar_fuso: "1", validade_bloqueio: "45")

    assert_equal 303, last_response.status
    body = get_ok("/reservas/nova")

    assert_includes body, "horário local America/Manaus"
    assert_includes body, %(name="validade_bloqueio" type="number" min="5" max="1440" value="45")
    assert_includes body, %(<input type="hidden" name="fuso" value="America/Manaus">)
    assert_includes get_ok("/organizacao"), "Manaus (leste do AM)"
  end

  def registered_policy(path) = get_ok(path)[%r{<details class="cancellation-policy">.*?</details>}m] || flunk("#{path}: política não exibida")

  # Cada versão do orçamento e a reserva exibem a política registrada, não a atual da organização.
  def test_quote_versions_and_reservation_show_the_registered_cancellation_policy
    previous = "de 24 h a menos de 72 h antes do início: multa de 30% do valor contratado"
    current = "48 h ou mais antes do início: multa de 10% do valor contratado"
    input = { customer_id: @customer.id, branch_id: @branch.id, period: rental, lines: [line(@camera, 1)], valid_until: t("2026-03-05T12:00:00Z") }
    quote = uc(:create_quote).call(@actor, input)
    reservation = reserve(@actor, @customer, @branch, rental(20), [line(@camera, 1)], mode: "confirm")
    change_settings(cancellation_rows: [%w[48 10], %w[0 50]])
    uc(:revise_quote).call(@actor, quote.id, input)

    { "/orcamentos/#{quote.id}?versao=1" => [previous, current], "/orcamentos/#{quote.id}?versao=2" => [current, previous],
      "/reservas/#{reservation.id}" => [previous, current] }.each do |path, (shown, hidden)|
      policy = registered_policy(path)

      assert_includes policy, path.start_with?("/reservas") ? "Política de cancelamento desta reserva" : "Política de cancelamento desta versão", path
      assert_includes policy, shown, path
      refute_includes policy, hidden, path
    end
  end

  def test_history_lists_the_changed_fields
    change_settings(cancellation_rows: [%w[48 0], %w[0 50]])
    body = get_ok(PATH)

    assert_includes body, "<strong>Configurações da organização alteradas</strong>"
    assert_includes body, "(política de cancelamento)"
  end

  def test_requests_without_the_csrf_token_are_refused
    get_ok(PATH)
    post PATH, settings_form(validade_bloqueio: "45")

    assert_equal 403, last_response.status
    assert_equal 1, lock_version
  end

  def test_forms_opened_before_a_time_zone_change_are_refused
    coupon = create_coupon("OUTONO", valid_until: t("2026-03-31T02:59:00Z"))
    reservation_page = get_ok("/reservas/nova")

    assert_includes reservation_page, %(<input type="hidden" name="fuso" value="America/Sao_Paulo">)
    assert_includes get_ok("/cupons/#{coupon.id}"), %(<input type="hidden" name="fuso" value="America/Sao_Paulo">)
    change_settings(timezone: "America/Manaus", confirm_timezone_change: true)
    message = "o fuso horário da organização mudou de America/Sao_Paulo para America/Manaus enquanto o formulário estava aberto; " \
              "confira os horários e envie novamente"
    post_form "/reservas", reservation_form("fuso" => "America/Sao_Paulo")

    assert_equal 422, last_response.status
    assert_includes last_response.body, message
    assert_includes last_response.body, %(<input type="hidden" name="fuso" value="America/Manaus">)
    assert_empty owner_query("SELECT 1 FROM reservations")
    post_form "/cupons/#{coupon.id}", edit_coupon_form(coupon, "fuso" => "America/Sao_Paulo", "valido_ate" => "2026-03-30T23:59")

    assert_equal 422, last_response.status
    assert_includes last_response.body, message
    assert_equal t("2026-03-31T02:59:00Z"), uc(:get_coupon).call(@actor, coupon.id)[:coupon].valid_until
    post_form "/reservas", reservation_form("fuso" => "America/Manaus")

    assert_equal 303, last_response.status
  end

  def edit_coupon_form(coupon, extra)
    { "versao" => coupon.lock_version.to_s, "descricao" => "", "valido_de" => "", "valido_ate" => "", "maximo_usos" => "",
      "subtotal_minimo" => "" }.merge(extra)
  end
end
