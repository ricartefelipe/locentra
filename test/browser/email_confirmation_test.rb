# frozen_string_literal: true

require_relative "browser_helper"

# Aviso de confirmação de e-mail no navegador real (ADR-031): fixo no topo do layout da equipe, com prazo
# restante; o botão "Reenviar confirmação" envia o formulário com o token CSRF da sessão, volta à mesma
# página com a mensagem de envio e não viola a CSP; o link "Corrigir e-mail" troca o endereço não confirmado.
# Depois do prazo, o aviso informa a conta somente leitura e a tentativa de alteração mostra a mensagem do
# bloqueio.
class EmailConfirmationBrowserTest < BrowserTest
  EC = Locentra::Domain::Identity::EmailConfirmation

  def setup
    super
    @org = create_organization(name: "Locadora Delta", email: "dona@delta.test", confirmed: false)
    create_customer(@org[:actor], name: "Marina Souza")
  end

  def banner_text = text_of("#aviso-confirmacao-email").squeeze(" ")

  def test_banner_stays_on_top_and_resends_the_confirmation
    login_as("dona@delta.test")
    visit "/clientes"

    assert_includes banner_text, "Confirme seu e-mail para liberar convites, credenciais, webhooks, pagamentos e envios a clientes."
    assert_includes banner_text, "restam 7 dias"
    assert_equal "sticky", @page.evaluate("getComputedStyle(document.getElementById('aviso-confirmacao-email')).position")
    @page.mouse.scroll_to(0, 2000)

    assert_predicate find("#aviso-confirmacao-email button[type=submit]"), :in_viewport?
    navigating { click("#aviso-confirmacao-email button[type=submit]") }

    assert_equal "/clientes", current_path
    assert_includes text_of("[data-flash]"), "Enviamos um novo link de confirmação para dona@delta.test."
    assert_equal 1, requests("POST", "/confirmar-email/reenviar")
    assert_includes body_text, "Marina Souza"
    assert_clean_console
  end

  def test_wrong_address_is_corrected_from_the_banner
    login_as("dona@delta.test")
    visit "/clientes"

    assert_includes banner_text, "Enviamos a confirmação para dona@delta.test."
    navigating { click("#aviso-confirmacao-email a[href='/confirmar-email/corrigir']") }
    fill("#email", "dona@delta-correta.test")
    fill("#senha", PASSWORD)
    navigating { click("main form button[type=submit]") }

    assert_equal "/", current_path
    assert_includes text_of("[data-flash]"), "E-mail corrigido. Enviamos o link de confirmação para dona@delta-correta.test."
    assert_includes banner_text, "Enviamos a confirmação para dona@delta-correta.test."
    assert_clean_console
  end

  def test_read_only_banner_and_refused_change
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login_as("dona@delta.test")
    visit "/clientes/novo"

    assert_includes banner_text, "Conta somente leitura até a confirmação."
    fill("#nome", "Cliente Bloqueado")
    fill("#documento", "39053344705")
    navigating { click("main form button[type=submit]") }

    assert_includes body_text, "Conta somente leitura até a confirmação do e-mail: o prazo de confirmação terminou."
    assert_includes banner_text, "Reenviar confirmação"
    assert_clean_console(expected: [/403/])
  end
end
