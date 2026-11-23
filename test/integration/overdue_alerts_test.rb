# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/operations_support"
require_relative "../support/worker_support"

# Atrasos de devolução: alertas únicos, reservas futuras afetadas, e-mail único, resolução com
# registro da decisão, processamento em lotes e execução pelo worker.
class OverdueAlertsTest < DatabaseTest
  include OperationsSupport
  include WorkerHelpers

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-MT", tracking: "serialized")
    @chairs = create_product(@actor, sku: "CAD-MT", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 10)
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  # Reserva em atraso com um ativo e 6 cadeiras; reservas futuras usam o mesmo ativo e 6 cadeiras.
  def overdue_scenario
    asset = register_assets(@actor, @camera, @branch, 1).first
    late = confirmed([line(@camera, 1), line(@chairs, 6)])
    other = create_customer(@actor, name: "Cliente Futuro", document: "11144477735")
    future = confirmed([line(@camera, 1)], after_rental, customer: other)
    stock_future = confirmed([line(@chairs, 6)], after_rental, customer: other)
    pick_up(late)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    { asset: asset, late: late, future: future, stock_future: stock_future }
  end

  def test_overdue_creates_unique_alerts_identifies_affected_reservations_and_emails_once
    s = overdue_scenario

    assert_equal [s[:late].id], uc(:detect_overdue).call(system_actor)
    assert_equal [s[:late].id], uc(:detect_overdue).call(system_actor), "execuções repetidas não duplicam alertas"
    alerts = owner_query("SELECT kind, reservation_id, related_reservation_id, asset_id, stock_pool_id FROM reservation_alerts ORDER BY kind, reservation_id")

    assert_equal(%w[affected_by_overdue affected_by_overdue overdue], alerts.map { |a| a["kind"] })
    affected = alerts.select { |a| a["kind"] == "affected_by_overdue" }

    assert_equal [s[:future].id, s[:stock_future].id].sort, affected.map { |a| a["reservation_id"] }.sort
    assert(affected.all? { |a| a["related_reservation_id"] == s[:late].id })
    assert_equal s[:asset].id, affected.find { |a| a["reservation_id"] == s[:future].id }["asset_id"]
    since = owner_query("SELECT overdue_since FROM reservations WHERE id = $1", [s[:late].id]).first["overdue_since"]

    assert_equal rental_period.ends_at, Time.parse(since)
    assert_equal 1, count("SELECT count(*) FROM jobs WHERE kind = 'email.send' AND payload->>'template' = 'late_return'")
    assert_equal %w[confirmed confirmed], [reservation_status(s[:future]), reservation_status(s[:stock_future])], "nada é cancelado automaticamente"
    board = uc(:operations_board).call(@actor)

    assert_equal([s[:late].id], board[:overdue].map { |r| r["id"] })
    assert_equal 3, board[:alerts].size
  end

  def test_alert_resolution_is_recorded_and_return_resolves_related_alerts
    s = overdue_scenario
    uc(:detect_overdue).call(system_actor)
    overdue_alert = uc(:operations_board).call(@actor)[:alerts].find { |a| a["kind"] == "overdue" }

    assert_raises(D::ValidationError) { uc(:resolve_alert).call(@actor, overdue_alert["id"], resolution: "") }
    resolved = uc(:resolve_alert).call(@actor, overdue_alert["id"], resolution: "Cliente avisado; devolução amanhã às 9h")

    assert_equal "resolved", resolved.status
    again = assert_raises(D::Conflict) { uc(:resolve_alert).call(@actor, overdue_alert["id"], resolution: "outra decisão") }

    assert_equal "alert_resolved", again.code
    uc(:detect_overdue).call(system_actor)

    assert_equal 1, count("SELECT count(*) FROM reservation_alerts WHERE kind = 'overdue'"), "alerta resolvido não é recriado"
    assert_equal "Cliente avisado; devolução amanhã às 9h", owner_query("SELECT resolution FROM reservation_alerts WHERE kind = 'overdue'").first["resolution"]
    return_all(s[:late])

    assert_equal 0, count("SELECT count(*) FROM reservation_alerts WHERE status = 'open'"), "devolução resolve os alertas relacionados"
    assert_empty uc(:detect_overdue).call(system_actor)
  end

  def test_extension_clears_overdue_and_resolves_alerts
    reservation = confirmed([line(@chairs, 2)])
    pick_up(reservation)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-05T12:00:00Z"))

    assert_empty uc(:detect_overdue).call(system_actor)
    assert_nil owner_query("SELECT overdue_since FROM reservations WHERE id = $1", [reservation.id]).first["overdue_since"]
    assert_equal "Prazo de devolução estendido", owner_query("SELECT resolution FROM reservation_alerts").first["resolution"]
  end

  def overdue_count(status = "open") = count("SELECT count(*) FROM reservation_alerts WHERE kind = 'overdue' AND status = $1", [status])

  def test_detect_overdue_covers_every_late_reservation_in_batches
    register_assets(@actor, @camera, @branch, 3)
    lates = %w[09 10 11].map do |hour|
      reservation = confirmed([line(@camera, 1)], period("2026-03-03T09:00:00Z", "2026-03-04T#{hour}:00:00Z"))
      pick_up(reservation)
      reservation
    end
    @clock.travel_to(t("2026-03-04T12:00:00Z"))

    assert_raises(ArgumentError) { uc(:detect_overdue).call(system_actor, limit: 0) }
    assert_equal lates.map(&:id), uc(:detect_overdue).call(system_actor, limit: 2), "o terceiro atraso não fica de fora do lote"
    assert_equal 3, count("SELECT count(*) FROM reservations WHERE overdue_since IS NOT NULL")
    assert_equal 3, overdue_count
    assert_equal 3, count("SELECT count(*) FROM jobs WHERE kind = 'email.send' AND payload->>'template' = 'late_return'")
    last_asset = owner_query("SELECT asset_id FROM pickup_lines WHERE reservation_id = $1", [lates.last.id]).first["asset_id"]
    future = confirmed([line(@camera, 1)], after_rental)
    owner_query("UPDATE asset_allocations SET asset_id = $1 WHERE reservation_id = $2", [last_asset, future.id])

    assert_equal lates.map(&:id), uc(:detect_overdue).call(system_actor, limit: 1), "as já sinalizadas continuam sendo processadas"
    affected = owner_query("SELECT reservation_id, related_reservation_id FROM reservation_alerts WHERE kind = 'affected_by_overdue'")

    assert_equal [[future.id, lates.last.id]], affected.map(&:values), "reserva futura criada depois da sinalização é identificada"
    assert_equal 3, overdue_count
  end

  def test_extension_to_a_date_still_past_keeps_a_single_open_overdue_alert
    reservation = confirmed([line(@chairs, 2)])
    pick_up(reservation)
    @clock.travel_to(t("2026-03-06T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-05T09:00:00Z"))
    2.times { uc(:detect_overdue).call(system_actor) }

    assert_equal [1, 1], [overdue_count, overdue_count("resolved")]
    current = owner_query("SELECT details->>'ends_at' AS ends_at FROM reservation_alerts WHERE kind = 'overdue' AND status = 'open'").first
    replaced = owner_query("SELECT resolution FROM reservation_alerts WHERE kind = 'overdue' AND status = 'resolved'").first

    assert_equal "2026-03-05T09:00:00Z", current["ends_at"]
    assert_includes replaced["resolution"], "Prazo de devolução alterado"
    since = owner_query("SELECT overdue_since FROM reservations WHERE id = $1", [reservation.id]).first["overdue_since"]

    assert_equal t("2026-03-05T09:00:00Z"), Time.parse(since)
    assert_equal 1, count("SELECT count(*) FROM jobs WHERE kind = 'email.send' AND payload->>'template' = 'late_return'")
  end

  def test_worker_tick_detects_overdue_and_sends_late_return_email
    reservation = confirmed([line(@chairs, 2)])
    pick_up(reservation)
    worker_system
    drain
    @mailer.deliveries.clear
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      worker_system.queue.enqueue(tx, "organization.tick", { "bucket" => "teste" })
    end
    drain
    drain

    late = @mailer.deliveries.select { |d| d[:subject].include?("atraso") }

    assert_equal 1, late.size
    assert_includes late.first[:subject], reservation.code
    assert_includes late.first[:text], "04/03/2026 06:00"
  end

  # E-mails de reserva com horários (confirmação, extensão, cancelamento e atraso) informam o fuso em que os
  # horários são exibidos, o fuso atual da organização.
  def test_reservation_emails_state_the_time_zone_of_their_times
    reservation = confirmed([line(@chairs, 2)])
    cancelled = confirmed([line(@chairs, 1)], after_rental)
    pick_up(reservation)
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-05T09:00:00Z"))
    uc(:cancel_reservation).call(@actor, cancelled.id, reason: "Desistência")
    @clock.travel_to(t("2026-03-06T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    worker_system
    drain
    subjects = ["Reserva #{reservation.code} confirmada", "Reserva #{reservation.code} estendida", "Reserva #{cancelled.code} cancelada",
                "Devolução em atraso — reserva #{reservation.code}"]
    stated = subjects.to_h do |subject|
      [subject, @mailer.deliveries.find { |d| d[:subject] == subject }&.dig(:text).to_s.include?("Horários no fuso horário America/Sao_Paulo.")]
    end

    assert_equal(subjects.to_h { |subject| [subject, true] }, stated)
  end
end
