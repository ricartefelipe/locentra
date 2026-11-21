# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/operations_support"
require_relative "../support/organization_settings_support"

# Casos de uso compostos com a transação do chamador (`tx:`), como na idempotência da API: cada operação
# roda dentro de `uow.run` e um erro posterior desfaz tudo (orçamento, contrato e o arquivo do PDF,
# separação, devolução, inspeção, alerta e configurações). A permissão continua conferida no modo composto,
# e a expiração de um orçamento vencido é registrada à parte, sem aprovar.
class ApiCompositionTest < DatabaseTest
  include OperationsSupport
  include OrganizationSettingsSupport

  class Undo < StandardError; end

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-CMP", tracking: "serialized", pricing: { "daily_cents" => 12_000 })
    register_assets(@actor, @camera, @branch, 2)
    @chairs = create_product(@actor, sku: "CAD-CMP", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 10)
  end

  # Executa o bloco na transação da unidade de trabalho e desfaz tudo no fim. Devolve o valor do bloco.
  def composed(actor = @actor)
    value = nil
    assert_raises(Undo) do
      @system.uow.run(actor) do |tx, current|
        value = yield tx, current
        raise Undo
      end
    end
    value
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")

  def quote_input(**extra)
    { customer_id: @customer.id, branch_id: @branch.id, period: rental, lines: [line(@camera, 1)], valid_until: t("2026-03-05T12:00:00Z") }
      .merge(extra)
  end

  def sent_quote(**extra)
    quote = uc(:create_quote).call(@actor, quote_input(**extra))
    uc(:send_quote).call(@actor, quote.id)
  end

  def quote_status(quote) = uc(:get_quote).call(@actor, quote.id)[:quote].status

  def credential(scopes)
    id = uc(:create_credential).call(@actor, name: "Integração #{scopes.join}", scopes: scopes, expires_in_days: 30)["id"]
    A::Actor.credential(kind: "api", credential_id: id, organization_id: @org[:organization_id], scopes: scopes)
  end

  def test_quote_mutations_are_undone_with_the_caller_transaction
    detail = composed do |tx, current|
      quote = uc(:create_quote).call(current, quote_input, tx: tx)
      uc(:get_quote).call(current, quote.id, tx: tx)
    end

    assert_equal [1, "draft"], [detail[:versions].size, detail[:quote].status], "o detalhe é lido na transação ainda aberta"
    assert_equal 0, count("SELECT count(*) FROM quotes")

    quote = uc(:create_quote).call(@actor, quote_input(hold_policy: "hold_on_send", hold_minutes: 120))
    composed { |tx, current| uc(:revise_quote).call(current, quote.id, quote_input(terms: "Outra condição"), tx: tx) }
    composed { |tx, current| uc(:send_quote).call(current, quote.id, tx: tx) }

    assert_equal ["draft", 1], [quote_status(quote), uc(:get_quote).call(@actor, quote.id)[:versions].size]
    assert_equal 0, count("SELECT count(*) FROM reservations"), "o bloqueio do envio também é desfeito"

    uc(:send_quote).call(@actor, quote.id)
    composed { |tx, current| uc(:reject_quote).call(current, quote.id, reason: "Desistiu", tx: tx) }
    composed { |tx, current| uc(:approve_quote).call(current, quote.id, version: 1, approver_name: "Maria", tx: tx) }

    assert_equal "sent", quote_status(quote)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria")
    result = composed { |tx, current| uc(:convert_quote).call(current, quote.id, tx: tx) }

    assert result.created
    assert_equal %w[approved held], [quote_status(quote), owner_query("SELECT status FROM reservations").first["status"]]
  end

  def test_contract_issue_amendment_and_cancellation_are_undone_with_the_pdf_file
    reservation = confirmed([line(@camera, 1)], rental)
    storage = @system.services[:storage]
    key = composed do |tx, current|
      result = uc(:issue_contract).issue(current, reservation.id, tx: tx)
      document = uc(:get_contract).call(current, result.contract.id, tx: tx)[:documents].first

      assert result.created
      assert_equal result.contract.id, uc(:issue_contract).issue(current, reservation.id, tx: tx).contract.id
      refute uc(:issue_contract).issue(current, reservation.id, tx: tx).created
      path = "#{@org[:organization_id]}/#{document["attachment_id"]}"

      assert storage.exist?(path), "o PDF é gravado durante a transação"
      path
    end

    refute storage.exist?(key), "o arquivo do PDF é removido quando a transação é desfeita"
    assert_equal([0, 0, 0], %w[contracts contract_documents attachments].map { |table| count("SELECT count(*) FROM #{table}") })

    contract = uc(:issue_contract).call(@actor, reservation.id)
    composed { |tx, current| uc(:amend_contract).call(current, contract.id, ends_at: t("2026-03-13T08:00:00Z"), tx: tx) }
    composed { |tx, current| uc(:cancel_contract).call(current, contract.id, reason: "Evento adiado", tx: tx) }
    data = uc(:get_contract).call(@actor, contract.id)

    assert_equal ["issued", 1, [], "confirmed"], [data[:contract].status, data[:documents].size, data[:amendments], data[:reservation].status]
    assert_equal 0, count("SELECT count(*) FROM reservation_adjustments")
  end

  def test_pickup_and_return_are_undone
    reservation = confirmed([line(@camera, 1), line(@chairs, 2)])
    opened = composed do |tx, current|
      result = uc(:start_pickup).open(current, reservation.id, tx: tx)
      [result.created, uc(:start_pickup).open(current, reservation.id, tx: tx).created, uc(:get_pickup).call(current, result.pickup.id, tx: tx)]
    end

    assert_equal [true, false, 2], [opened[0], opened[1], opened[2][:lines].size]
    assert_equal 0, count("SELECT count(*) FROM pickups")

    pickup = uc(:start_pickup).call(@actor, reservation.id)
    entries = check_entries(@actor, pickup)
    composed { |tx, current| uc(:check_pickup).call(current, pickup.id, entries, tx: tx) }

    assert_equal 0, count("SELECT count(*) FROM pickup_lines WHERE status = 'checked'")
    uc(:check_pickup).call(@actor, pickup.id, entries)
    composed { |tx, current| uc(:deliver_pickup).call(current, pickup.id, picker: { kind: "customer" }, tx: tx) }
    composed { |tx, current| uc(:cancel_pickup).call(current, pickup.id, reason: "Cliente não compareceu", tx: tx) }

    assert_equal %w[picking confirmed], [owner_query("SELECT status FROM pickups").first["status"], reservation_status(reservation)]
    uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })
    pending = return_entries(reservation)
    detail = composed do |tx, current|
      row = uc(:register_return).call(current, reservation.id, entries: pending, tx: tx)
      uc(:get_return).call(current, row["id"], tx: tx)
    end

    assert_equal 2, detail[:lines].size
    assert_equal [0, "in_progress"], [count("SELECT count(*) FROM returns"), reservation_status(reservation)]
  end

  def test_inspection_alert_and_settings_are_undone
    reservation = confirmed([line(@camera, 1)])
    pick_up(reservation)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    alert_id = owner_query("SELECT id FROM reservation_alerts WHERE kind = 'overdue'").first["id"]
    composed { |tx, current| uc(:resolve_alert).call(current, alert_id, resolution: "Cliente avisado", tx: tx) }

    assert_equal "open", owner_query("SELECT status FROM reservation_alerts WHERE id = $1", [alert_id]).first["status"]
    uc(:register_return).call(@actor, reservation.id, entries: return_entries(reservation, requires_inspection: true))
    inspection_id = owner_query("SELECT id FROM inspections").first["id"]
    composed { |tx, current| uc(:approve_inspection).call(current, inspection_id, notes: "Sem avarias", tx: tx) }
    composed { |tx, current| uc(:reject_inspection).call(current, inspection_id, notes: "Lente riscada", tx: tx) }

    assert_equal [["pending"], 0], [owner_query("SELECT status FROM inspections").map { |r| r["status"] }, count("SELECT count(*) FROM maintenance_orders")]
    org = current_organization
    revised = composed do |tx, current|
      uc(:update_organization_settings).call(current, settings_attrs(org, hold_minutes: "90"), lock_version: 1, via: "api", tx: tx)
      uc(:get_organization).call(current, tx: tx)[:organization]
    end

    assert_equal [90, 2], [revised.hold_minutes, revised.lock_version], "a leitura composta vê a alteração ainda não confirmada"
    assert_equal [30, 1], [current_organization.hold_minutes, current_organization.lock_version]
    assert_empty owner_query("SELECT id FROM audit_events WHERE action = 'organization.settings_updated'")
  end

  def test_permission_is_checked_in_the_composed_mode
    reader = credential(%w[quotes.read reservations.read])
    quote = uc(:create_quote).call(@actor, quote_input)
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Maria")
    writer = credential(%w[quotes.write quotes.read])
    denied = [
      -> { @system.uow.run(reader) { |tx, current| uc(:create_quote).call(current, quote_input, tx: tx) } },
      -> { @system.uow.run(writer) { |tx, current| uc(:convert_quote).call(current, quote.id, tx: tx) } },
      -> { @system.uow.run(reader) { |tx, current| uc(:start_pickup).open(current, quote.id, tx: tx) } },
      -> { @system.uow.run(reader) { |tx, current| uc(:get_contract).call(current, quote.id, tx: tx) } },
      -> { @system.uow.run(credential(%w[organization.manage])) { |tx, current| uc(:update_organization_settings).call(current, {}, tx: tx) } }
    ]

    denied.each { |call| assert_raises(D::AccessDenied, &call) }
    assert_equal "approved", quote_status(quote)
    assert_equal 0, count("SELECT count(*) FROM reservations")
  end

  def test_record_expiration_expires_without_approving_and_is_a_no_op_otherwise
    valid = sent_quote
    expiring = sent_quote(valid_until: t("2026-03-03T12:00:00Z"))
    @clock.travel_to(t("2026-03-03T13:00:00Z"))
    error = assert_raises(D::Conflict) do
      @system.uow.run(@actor) { |tx, current| uc(:approve_quote).call(current, expiring.id, version: 1, approver_name: "Maria", tx: tx) }
    end

    assert_equal "quote_expired", error.code
    assert_equal "sent", quote_status(expiring), "a expiração gravada na tentativa composta é desfeita"
    refute uc(:approve_quote).record_expiration(@actor, valid.id), "orçamento vigente não expira"
    assert uc(:approve_quote).record_expiration(@actor, expiring.id)
    refute uc(:approve_quote).record_expiration(@actor, expiring.id), "orçamento já expirado não muda"

    assert_equal %w[sent expired], [quote_status(valid), quote_status(expiring)]
    assert_nil uc(:get_quote).call(@actor, expiring.id)[:quote].approved_at
    assert_equal 1, count("SELECT count(*) FROM audit_events WHERE action = 'quote.expired' AND details->>'trigger' = 'approval_attempt'")
    assert_raises(D::AccessDenied) { uc(:approve_quote).record_expiration(credential(%w[quotes.read]), expiring.id) }
  end
end
