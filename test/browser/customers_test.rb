# frozen_string_literal: true

require_relative "browser_helper"

# Cadastro de clientes pelo formulário e exibição segura de conteúdo informado pelo usuário.
class CustomersBrowserTest < BrowserTest
  MALICIOUS_NAME = %(<img src=x onerror="document.title='invadido'">Ana)
  MALICIOUS_NOTES = %(<script>window.__invadido = true</script><b>negrito</b>)

  def setup
    super
    seed_tenants
    login_as("dona@alfa.test", organization: "Locadora Alfa")
  end

  def test_customer_registration_with_validation_feedback
    visit "/clientes/novo"
    fill("#nome", "Joana Prado")
    fill("#documento", "11111111111")
    navigating { click("form[action='/clientes'] button[type=submit]") }

    assert_equal "/clientes", current_path
    assert_equal "form-errors", wait_until("foco no resumo de erros") { active_element == "form-errors" && active_element },
                 "o resumo de erros recebe o foco para leitores de tela e teclado"
    assert_equal "true", find("#documento").attribute("aria-invalid")
    assert_equal "Joana Prado", find("#nome").value, "os dados digitados são mantidos"
    fill("#documento", "111.444.777-35")
    fill("#email", "joana@example.test")
    navigating { click("form[action='/clientes'] button[type=submit]") }

    assert_match %r{\A/clientes/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z}, current_path
    assert_includes text_of("[data-flash]"), "Cliente cadastrado."
    assert_includes text_of("main h1"), "Joana Prado"
    stored = owner_query("SELECT name, document, email FROM customers WHERE name = 'Joana Prado'")

    assert_equal [{ "name" => "Joana Prado", "document" => "11144477735", "email" => "joana@example.test" }], stored
    click("[data-flash] [data-dismiss]")

    assert wait_until("mensagem fechada pelo botão") { @page.at_css("[data-flash]").nil? }
    assert_clean_console(expected: [%r{status of 422 .*/clientes\z}])
  end

  def test_malicious_content_is_displayed_as_text
    visit "/clientes/novo"
    fill("#nome", MALICIOUS_NAME)
    fill("#documento", "39053344705")
    fill("#observacoes", MALICIOUS_NOTES)
    navigating { click("form[action='/clientes'] button[type=submit]") }

    assert_match %r{\A/clientes/\h{8}-}, current_path
    assert_includes body_text, MALICIOUS_NAME, "o nome aparece literalmente"
    assert_includes body_text, MALICIOUS_NOTES, "as observações aparecem literalmente"
    assert_equal 0, @page.evaluate("document.querySelectorAll('main img, main script, main b').length"), "nenhum elemento injetado"
    assert_nil @page.evaluate("window.__invadido")
    refute_equal "invadido", @page.evaluate("document.title")
    assert_includes @page.evaluate("document.title"), "<img", "o título da página também é escapado"
    visit "/clientes"

    assert_includes body_text, MALICIOUS_NAME
    assert_equal 0, @page.evaluate("document.querySelectorAll('main img').length")
    assert_empty csp_violations, "conteúdo escapado não chega a ser bloqueado pela CSP: ele nunca vira HTML"
    assert_clean_console
  end
end
