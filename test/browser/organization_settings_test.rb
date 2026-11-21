# frozen_string_literal: true

require_relative "browser_helper"

# Configurações da organização e filiais no navegador, sem erros de console nem violações de CSP: nova
# faixa da política pelo módulo de linhas, pré-visualização, salvamento, troca de fuso recusada sem a
# confirmação (foco no resumo de erros) e aceita com ela; edição e desativação de filial com o diálogo de
# confirmação.
class OrganizationSettingsBrowserTest < BrowserTest
  FAIXAS = '[data-line-group="faixas"]'
  SETTINGS = "/organizacao/configuracoes"

  def setup
    super
    seed_tenants
  end

  def policy_lines = @page.css("#{FAIXAS} [data-lines] [data-line]")
  def press_action(value) = navigating { click("button[name='acao'][value='#{value}']") }
  def organization = uc(:get_organization).call(@actor)[:organization]

  # Nova faixa pelo botão do módulo de linhas, preenchida como um usuário digitaria.
  def add_policy_line(hours, fee)
    count = policy_lines.size
    click("#{FAIXAS} [data-add-line]")
    wait_until("nova faixa") { policy_lines.size == count + 1 }
    { "antecedencia_horas[]" => hours, "multa_percentual[]" => fee }.each do |name, value|
      field = policy_lines.last.at_css("input[name='#{name}']")
      field.focus
      field.type(value)
    end
  end

  def test_owner_edits_the_policy_previews_saves_and_changes_the_time_zone
    login_as("dona@alfa.test", organization: "Locadora Alfa")
    navigating { click("nav.sidebar a[href='/organizacao']") }
    navigating { click("a[href='#{SETTINGS}']") }

    assert_equal SETTINGS, current_path
    add_policy_line("168", "0")
    fill("#validade_bloqueio", "45")
    press_action("previsualizar")

    assert_includes text_of("#previa-politica"), "168 h ou mais antes do início: multa de 0% do valor contratado"
    assert_includes text_of("#previa-politica"), "Bloqueios criados sem validade informada vencem em 45 minutos."
    assert_equal 1, organization.lock_version, "a prévia não grava"
    press_action("salvar")

    assert_includes text_of("[data-flash]"), "Configurações salvas."
    assert_equal [2, 45], [organization.lock_version, organization.hold_minutes]
    choose("#fuso_horario", "America/Manaus")
    press_action("salvar")

    assert_equal "form-errors", wait_until("foco no resumo de erros") { active_element == "form-errors" && active_element }
    assert_includes text_of(".form-errors"), "confirme a troca do fuso horário depois de ler as consequências"
    assert_equal "America/Sao_Paulo", organization.timezone
    click("#confirmar_fuso")
    press_action("salvar")

    assert_includes text_of("[data-flash]"), "Configurações salvas."
    assert_equal "America/Manaus", organization.timezone
    assert_match(/Configurações da organização alteradas\s+\(fuso horário\)/, body_text)
    assert_clean_console(expected: [%r{status of 422 .*/organizacao/configuracoes\z}])
  end

  def test_owner_edits_and_deactivates_a_branch_after_the_confirmation_dialog
    north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE")
    login_as("dona@alfa.test", organization: "Locadora Alfa")
    visit "/organizacao"
    navigating { click("a[href='/organizacao/filiais/#{north.id}']") }
    click("details summary")
    fill("#nome", "Unidade Norte II")
    fill("#endereco", "Av. Norte, 200")
    navigating { click("form[action='/organizacao/filiais/#{north.id}'] button[type=submit]") }

    assert_includes text_of("[data-flash]"), "Filial atualizada."
    @dialog_answer = :accept
    navigating { click("form[action='/organizacao/filiais/#{north.id}/desativar'] button[type=submit]") }

    assert_includes @dialogs.last, "Desativar a filial NORTE?"
    assert_includes text_of("[data-flash]"), "Filial desativada."
    assert_includes body_text, "Reativar filial"
    branch = uc(:get_branch).call(@actor, north.id)[:branch]

    assert_equal ["Unidade Norte II", "Av. Norte, 200", false], [branch.name, branch.address, branch.active]
    assert_clean_console
  end
end
