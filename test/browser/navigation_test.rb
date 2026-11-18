# frozen_string_literal: true

require_relative "browser_helper"

# Entrada, seleção de organização, navegação por teclado, console e CSP no navegador real.
class NavigationBrowserTest < BrowserTest
  def setup
    super
    seed_tenants
  end

  def test_login_and_organization_selection
    visit "/"

    assert_equal "/entrar", current_path, "sem sessão, a área da equipe leva à entrada"
    login_as("dona@alfa.test")

    assert_equal "/organizacoes", current_path
    choices = @page.css("button.choice").map { |button| button.text.squeeze(" ").strip }

    assert_equal 2, choices.size
    assert(choices.any? { |c| c.include?("Locadora Alfa") && c.include?("Proprietário") })
    assert(choices.any? { |c| c.include?("Locadora Beta") && c.include?("Gerente") })
    navigating { click_choice("Locadora Beta") }

    assert_equal "/", current_path
    assert_equal "Locadora Beta", text_of(".org-name")
    assert_includes text_of("[data-flash]"), "Organização ativa: Locadora Beta"
    navigating { click("a[href='/organizacoes']") }
    navigating { click_choice("Locadora Alfa") }

    assert_equal "Locadora Alfa", text_of(".org-name")
    navigating { click("a[href='/clientes']") }

    assert_includes body_text, "Marina Souza", "a lista mostra os clientes da organização ativa"
    assert_clean_console
  end

  def test_skip_link_moves_focus_to_content_and_focus_is_visible
    login_as("dona@alfa.test", organization: "Locadora Alfa")
    visit "/reservas"
    skip = find("a.skip-link")

    refute_predicate skip, :in_viewport?, "o atalho fica fora da tela até receber foco"
    @page.keyboard.type(:Tab)

    assert_equal "skip-link", wait_until("foco no atalho") { active_element == "skip-link" && active_element }
    assert_equal "Ir para o conteúdo", @page.evaluate("document.activeElement.textContent.trim()")
    assert_predicate find("a.skip-link"), :in_viewport?
    assert_equal "solid", @page.evaluate("getComputedStyle(document.activeElement).outlineStyle"), "foco visível no atalho"
    @page.keyboard.type(:Enter)

    assert_equal "conteudo", wait_until("foco no conteúdo principal") { active_element == "conteudo" && active_element }
    assert_equal "conteudo", URI(@page.current_url).fragment
    @page.keyboard.type(:Tab)
    focused = wait_until("próximo elemento focado dentro do conteúdo") do
      @page.evaluate("document.activeElement !== document.body && document.getElementById('conteudo').contains(document.activeElement)")
    end

    assert focused, "a tabulação continua a partir do conteúdo, sem voltar ao menu"
    assert_equal "solid", @page.evaluate("getComputedStyle(document.activeElement).outlineStyle"), "foco visível em controles"
    refute_equal "0px", @page.evaluate("getComputedStyle(document.activeElement).outlineWidth")
    assert_clean_console
  end

  def test_pages_render_without_console_errors_or_csp_violations
    reservation = held_reservation
    login_as("dona@alfa.test", organization: "Locadora Alfa")
    ["/", "/reservas", "/reservas/nova", "/reservas/#{reservation.id}", "/clientes", "/clientes/novo", "/clientes/#{@customer.id}",
     "/produtos", "/ativos", "/disponibilidade", "/orcamentos/novo", "/financeiro", "/operacao", "/usuarios"].each do |path|
      visit path

      assert_equal path, current_path
      refute_includes body_text, "Erro interno", path
    end
    assert_clean_console
  end

  # Controle do detector: um script inline injetado é bloqueado pela CSP e aparece como violação; sem
  # isso, a ausência de violações nos demais testes não provaria nada.
  def test_csp_violation_detector_catches_inline_scripts
    visit "/entrar"

    assert_empty csp_violations
    @page.evaluate(<<~JS)
      (() => { const s = document.createElement("script"); s.textContent = "window.__inline = true"; document.body.appendChild(s); return true; })()
    JS

    assert wait_until("violação registrada") { csp_violations.any? }
    assert_nil @page.evaluate("window.__inline"), "o script inline não executa"
  end
end
