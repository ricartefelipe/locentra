# frozen_string_literal: true

require_relative "browser_helper"

# Reservas no navegador: módulo de itens (adicionar e remover linhas), confirmação e formulários
# com confirmação por diálogo (data-confirm).
class ReservationsBrowserTest < BrowserTest
  def setup
    super
    seed_tenants
    login_as("dona@alfa.test", organization: "Locadora Alfa")
  end

  def lines = @page.css("[data-lines] [data-line]")

  def test_new_reservation_uses_the_line_items_module
    visit "/reservas/nova"
    choose("#cliente_id", @customer.id)
    set_value("#inicio", "2026-03-10T09:00")
    set_value("#fim", "2026-03-12T09:00")
    choose("#produto-0", @camera.id)

    assert_equal 1, lines.size
    added = add_line(2)

    assert_equal added.at_css("select").attribute("id"), active_element, "o foco vai para o produto da nova linha"
    assert_accessible_lines
    assert_equal ["", "1"], [added.at_css("select").value, added.at_css("input").value], "a nova linha começa vazia, com quantidade 1"
    added.at_css("select").select(@tripods.id)
    quantity = added.at_css("input")
    quantity.focus
    quantity.evaluate("this.value = ''")
    quantity.type("3")
    press(add_line(3).at_css("[data-remove-line]"))
    wait_until("linha removida") { lines.size == 2 }

    assert @page.evaluate("document.activeElement.hasAttribute('data-add-line')"), "foco volta ao botão de adicionar"
    navigating { click("form[action='/reservas'] button[type=submit]") }

    assert_match %r{\A/reservas/\h{8}-}, current_path
    assert_includes text_of("[data-flash]"), "registrada (Bloqueio temporário)"
    items = owner_query("SELECT product_id, quantity FROM reservation_items ORDER BY quantity")

    assert_equal([[@camera.id, 1], [@tripods.id, 3]], items.map { |row| [row["product_id"], row["quantity"].to_i] })
    assert_includes body_text, "Câmera de navegação"
    assert_includes body_text, "Tripé de navegação"
    assert_clean_console
  end

  def test_held_reservation_is_confirmed_from_its_page
    reservation = held_reservation
    visit "/reservas/#{reservation.id}"

    assert_includes text_of("main h1"), "Bloqueio temporário"
    navigating { click("form[action='/reservas/#{reservation.id}/confirmar'] button") }

    assert_equal "/reservas/#{reservation.id}", current_path
    assert_includes text_of("[data-flash]"), "Reserva confirmada com disponibilidade revalidada."
    assert_includes text_of("main h1"), "Confirmada"
    assert_nil @page.at_css("form[action='/reservas/#{reservation.id}/confirmar']"), "a ação some depois de confirmada"
    assert_equal "confirmed", owner_query("SELECT status FROM reservations WHERE id = $1", [reservation.id]).first["status"]
    assert_clean_console
  end

  def test_data_confirm_dialog_cancels_or_submits_the_form
    reservation = held_reservation
    uc(:confirm_reservation).call(@actor, reservation.id)
    visit "/reservas/#{reservation.id}"
    form = "form[action='/reservas/#{reservation.id}/cancelar']"
    message = find(form).attribute("data-confirm")
    click("details:has(#{form}) summary")
    fill("#{form} #motivo", "Cliente desistiu")
    marker = SecureRandom.hex(8)
    @page.evaluate("window.__marcadorDocumento = '#{marker}'")
    @dialog_answer = :dismiss
    click("#{form} button[type=submit]")
    wait_until("diálogo de confirmação exibido") { @dialogs.size == 1 }

    assert_equal [message], @dialogs
    assert same_document?(marker), "cancelar o diálogo mantém a página"
    assert_equal "confirmed", owner_query("SELECT status FROM reservations WHERE id = $1", [reservation.id]).first["status"]
    @dialog_answer = :accept
    navigating { click("#{form} button[type=submit]") }

    assert_equal [message, message], @dialogs
    assert_includes text_of("[data-flash]"), "Reserva cancelada."
    assert_equal "cancelled", owner_query("SELECT status FROM reservations WHERE id = $1", [reservation.id]).first["status"]
    assert_equal 1, requests("POST", "/reservas/:id/cancelar"), "somente o envio aceito chegou ao servidor"
    assert_clean_console
  end

  private

  # Cada campo das linhas tem identificador único e rótulo associado (for = id).
  def assert_accessible_lines
    ids = @page.css("[data-lines] select, [data-lines] input").map { |field| field.attribute("id") }

    assert_equal ids.uniq, ids, "identificadores únicos em cada linha"
    lines.each do |row|
      row.css("select, input").each do |field|
        refute_nil row.at_css("label[for='#{field.attribute("id")}']"), "rótulo associado a #{field.attribute("id")}"
      end
    end
  end

  def add_line(expected)
    click("[data-add-line]")
    wait_until("linha #{expected} de item") { lines.size == expected }
    lines.last
  end
end
