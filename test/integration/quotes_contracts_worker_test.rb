# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"

# Worker: expiração de orçamentos na rotina por organização e e-mails de orçamento enviado e de
# contrato emitido, derivados dos eventos da outbox.
class QuotesContractsWorkerTest < DatabaseTest
  include WorkerHelpers

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    worker_system
    drain
    @mailer.deliveries.clear
    @customer = create_customer(@actor, name: "Cliente Avisado")
    @camera = create_product(@actor, sku: "CAM-WRK", tracking: "serialized", pricing: { "daily_cents" => 9_000 })
    register_assets(@actor, @camera, @org[:branch], 1)
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def quote(**extra)
    uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @org[:branch].id, lines: [line(@camera, 1)],
                                     period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), valid_until: t("2026-03-04T12:00:00Z"),
                                     **extra })
  end

  def test_scheduler_tick_expires_sent_quotes_once_and_releases_holds
    sent = uc(:send_quote).call(@actor, quote(hold_policy: "hold_on_send", hold_minutes: 1440).id)
    drain
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    2.times { runner.send(:schedule) }
    drain

    assert_equal "expired", uc(:get_quote).call(@actor, sent.id)[:quote].status
    assert_equal "expired", uc(:get_reservation).call(@actor, sent.hold_reservation_id)[:reservation].status, "bloqueio vencido na mesma rotina"
    assert_equal 0, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE active").first["n"].to_i
    assert_equal 1, owner_query("SELECT count(*) AS n FROM audit_events WHERE action = 'quote.expired'").first["n"].to_i
    assert_empty jobs("status = 'dead'")
  end

  def test_sent_quote_email_states_that_availability_is_not_guaranteed
    sent = uc(:send_quote).call(@actor, quote.id)
    drain
    mail = @mailer.deliveries.find { |d| d[:subject].start_with?("Orçamento") }

    assert mail, "e-mail do orçamento enviado"
    assert_equal "cliente@example.test", mail[:to]
    assert_includes mail[:subject], sent.code
    assert_includes mail[:text], "não garante a disponibilidade"
    assert_includes mail[:text], "04/03/2026 09:00"
    assert_includes mail[:text], "R$ 90,00"
    assert_includes mail[:text], "Horários no fuso horário America/Sao_Paulo."
  end

  def test_sent_quote_with_hold_and_issued_contract_send_emails
    sent = uc(:send_quote).call(@actor, quote(hold_policy: "hold_on_send", hold_minutes: 120).id)
    uc(:approve_quote).call(@actor, sent.id, version: 1, approver_name: "Cliente Avisado")
    reservation = uc(:convert_quote).call(@actor, sent.id).reservation
    contract = uc(:issue_contract).call(@actor, reservation.id)
    drain
    subjects = @mailer.deliveries.map { |d| d[:subject] }

    assert_includes @mailer.deliveries.find { |d| d[:subject].start_with?("Orçamento") }[:text], "bloqueio temporário por 120 minutos"
    assert_includes subjects, "Contrato de locação #{contract.code} emitido"
    contract_mail = @mailer.deliveries.find { |d| d[:subject].include?(contract.code) }

    assert_includes contract_mail[:text], "aceite eletrônico simples"
    assert_includes contract_mail[:text], "10/03/2026 05:00"
    assert_includes contract_mail[:text], "Horários no fuso horário America/Sao_Paulo."
    assert_includes subjects, "Reserva #{reservation.code} confirmada"
  end

  def test_released_quote_hold_does_not_email_the_customer_as_a_cancelled_reservation
    sent = uc(:send_quote).call(@actor, quote(hold_policy: "hold_on_send", hold_minutes: 120).id)
    uc(:revise_quote).call(@actor, sent.id, { branch_id: @org[:branch].id, lines: [line(@camera, 1)], valid_until: t("2026-03-04T18:00:00Z"),
                                              period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z") })
    drain

    assert_equal "cancelled", uc(:get_reservation).call(@actor, sent.hold_reservation_id)[:reservation].status
    refute(@mailer.deliveries.any? { |d| d[:subject].start_with?("Reserva") }, "o bloqueio do orçamento não gera e-mail de reserva")
    assert_equal(1, @mailer.deliveries.count { |d| d[:subject].start_with?("Orçamento") })
  end
end
