# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/finance_support"

# Contas a receber, pagamentos manuais, reembolsos, cauções e diário com PostgreSQL real.
class FinanceFlowTest < DatabaseTest
  include FinanceHelpers

  def setup
    super
    finance_setup
  end

  def test_sync_creates_rental_and_adjustment_charges_without_duplicates
    reservation = booking

    created = sync(reservation)

    assert_equal([["rental", 10_000]], created.map { |r| [r.kind, r.amount.cents] })
    assert_empty sync(reservation), "a origem única impede duplicar a cobrança"
    uc(:extend_reservation).call(@actor, reservation.id, ends_at: t("2026-03-12T08:00:00Z"))
    extension = sync(reservation)

    assert_equal([["extension", 10_000]], extension.map { |r| [r.kind, r.amount.cents] })
    assert_empty sync(reservation)
    assert_equal 2, count("receivables")
    assert_equal({ "receivable" => 20_000, "rental_revenue" => -20_000 }, trial_balance.reject { |_, v| v.zero? })
    assert_empty unbalanced_transactions
  end

  def test_requests_and_holds_are_charged_only_with_explicit_prepayment
    held = booking(mode: "hold")
    requested = booking(mode: "request", day: 15)

    assert_empty sync(held)
    assert_empty sync(requested)
    assert_equal ["rental"], sync(held, prepayment: true).map(&:kind)
    assert_empty sync(requested, prepayment: true)
  end

  def test_partial_payments_derive_balance_and_overpayment_is_refused
    rental = rental_of(booking.tap { |r| sync(r) })
    pay(rental, 3_000, method: "pix")

    assert_equal %w[partial 7000], [balance_of(rental).status, balance_of(rental).outstanding.cents.to_s]
    error = assert_raises(D::Conflict) { pay(rental, 7_001) }
    assert_equal "amount_exceeds_open_balance", error.code
    assert_raises(D::ValidationError) { pay(rental, 0) }
    assert_raises(D::ValidationError) { pay(rental, 100, method: "cheque") }
    assert_raises(D::ValidationError) { pay(rental, 100, paid_at: @clock.now + 60) }
    pay(rental, 7_000, method: "transfer", paid_at: @clock.now - 3600)

    assert_equal "paid", balance_of(rental).status
    assert_equal({ "cash" => 10_000, "rental_revenue" => -10_000 }, trial_balance.reject { |_, v| v.zero? })
  end

  def test_deposit_is_received_applied_to_damage_and_returned_without_touching_revenue
    reservation = booking
    error = assert_raises(D::ValidationError) { uc(:open_deposit).call(@actor, reservation.id, kind: "card_preauthorization") }
    assert_match(/tokenização/, error.message)
    assert_match(/PAN/, error.message)

    deposit = uc(:open_deposit).call(@actor, reservation.id, kind: "paid_deposit")

    assert_equal 30_000, deposit.expected.cents
    assert_raises(D::Conflict) { uc(:open_deposit).call(@actor, reservation.id, kind: "paid_deposit") }
    uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "pix", amount: money(30_000) })

    assert_equal({ "cash" => 30_000, "deposit_liability" => -30_000 }, trial_balance.reject { |_, v| v.zero? }, "caução é passivo, não receita")
    assert_raises(D::Conflict) { uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "pix", amount: money(1) }) }
    damage = uc(:create_manual_charge).call(@actor, reservation.id, kind: "damage", amount: money(12_000), description: "Cadeira quebrada")
    ledger = uc(:move_deposit).apply(@actor, deposit.id, receivable_id: damage.id, amount: money(12_000))

    assert_equal 18_000, ledger.balance.cents
    assert_equal "paid", balance_of(damage).status
    assert_raises(D::Conflict) { uc(:move_deposit).give_back(@actor, deposit.id, amount: money(18_001), method: "pix") }
    final = uc(:move_deposit).give_back(@actor, deposit.id, amount: money(18_000), method: "pix", notes: "Devolução integral do saldo")

    assert_equal %w[settled 0], [final.status, final.balance.cents.to_s]
    balances = trial_balance

    assert_equal 0, balances["deposit_liability"]
    assert_equal(-12_000, balances["additional_revenue"], "somente a cobrança de avaria é receita")
    assert_equal 0, balances["rental_revenue"]
    assert_equal 12_000, balances["cash"]
    assert_empty unbalanced_transactions
  end

  def test_deposit_application_rules
    reservation = booking
    other = booking(day: 20)
    deposit = uc(:open_deposit).call(@actor, reservation.id, kind: "paid_deposit", amount: money(5_000))
    uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "cash", amount: money(5_000) })
    sync(other)

    assert_raises(D::ValidationError) { uc(:move_deposit).apply(@actor, deposit.id, receivable_id: rental_of(other).id, amount: money(100)) }
    sync(reservation)
    rental = rental_of(reservation)

    assert_raises(D::Conflict) { uc(:move_deposit).apply(@actor, deposit.id, receivable_id: rental.id, amount: money(5_001)) }
    assert_raises(D::ValidationError) { uc(:move_deposit).give_back(@actor, deposit.id, amount: money(100), method: "boleto") }
    uc(:cancel_receivable).call(@actor, rental.id, reason: "Cancelada para teste")

    assert_raises(D::Conflict) { uc(:move_deposit).apply(@actor, deposit.id, receivable_id: rental.id, amount: money(100)) }
    assert_raises(D::NotFound) { uc(:move_deposit).apply(@actor, SecureRandom.uuid, receivable_id: rental.id, amount: money(100)) }
  end

  def test_refunds_respect_the_confirmed_amount_and_reopen_the_balance
    rental = rental_of(booking.tap { |r| sync(r) })
    paid = pay(rental, 10_000, method: "cash")
    refund = uc(:request_refund).call(@actor, paid.id, amount: money(4_000), reason: "Desconto concedido após a locação")

    assert_equal "confirmed", refund.status, "pagamento manual tem reembolso registrado na hora"
    assert_equal 4_000, balance_of(rental).outstanding.cents
    error = assert_raises(D::Conflict) { uc(:request_refund).call(@actor, paid.id, amount: money(6_001), reason: "Acima do saldo") }
    assert_equal "refund_exceeds_eligible", error.code
    uc(:request_refund).call(@actor, paid.id, amount: money(6_000), reason: "Restante devolvido")

    assert_raises(D::Conflict) { uc(:request_refund).call(@actor, paid.id, amount: money(1), reason: "Sem saldo") }
    assert_equal 0, uc(:finance).payment(@actor, paid.id)[:eligible].cents
    assert_equal 10_000, balance_of(rental).outstanding.cents
    assert_equal({ "receivable" => 10_000, "rental_revenue" => -10_000 }, trial_balance.reject { |_, v| v.zero? })
    assert_equal 2, count("outbox_events", "event_type = 'payment.refunded'")
    assert_empty unbalanced_transactions
  end

  def test_refund_requires_permission_and_receivable_payment
    reservation = booking
    deposit = uc(:open_deposit).call(@actor, reservation.id, kind: "paid_deposit")
    deposit_payment = uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "cash", amount: money(1_000) })

    assert_raises(D::ValidationError) { uc(:request_refund).call(@actor, deposit_payment.id, amount: money(100), reason: "Caução") }
    auditor = member("auditor")

    assert_raises(D::AccessDenied) { uc(:request_refund).call(auditor, deposit_payment.id, amount: money(100), reason: "Sem permissão") }
    assert uc(:finance).overview(auditor)
  end

  def test_cancellation_is_a_compensating_operation_and_payments_become_customer_credit
    rental = rental_of(booking.tap { |r| sync(r) })
    paid = pay(rental, 5_000)
    balance = uc(:cancel_receivable).call(@actor, rental.id, reason: "Cliente desistiu da locação")

    assert_equal %w[cancelled 5000], [balance.status, balance.credit.cents.to_s]
    assert_equal 10_000, owner_query("SELECT amount_cents FROM receivables WHERE id = $1", [rental.id]).first["amount_cents"].to_i
    assert_raises(D::Conflict) { uc(:cancel_receivable).call(@actor, rental.id, reason: "De novo") }
    assert_raises(D::Conflict) { pay(rental, 100) }
    uc(:request_refund).call(@actor, paid.id, amount: money(5_000), reason: "Devolução do crédito")

    assert_equal 0, balance_of(rental).outstanding.cents
    assert_equal 0, trial_balance.values.sum(&:abs), "cancelamento e reembolso zeram todas as contas"
  end

  def test_payment_for_cancelled_reservation_requires_review_and_does_not_reactivate_it
    reservation = booking
    rental = rental_of(reservation.tap { |r| sync(r) })
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Evento adiado")
    payment = pay(rental, 10_000, method: "pix")

    assert payment.requires_review
    assert_match(/não foi reativada/, payment.review_reason)
    assert_equal "cancelled", uc(:get_reservation).call(@actor, reservation.id)[:reservation].status
    alerts = uc(:finance).overview(@actor)[:alerts]

    assert_equal(%w[payment_after_cancellation], alerts.map { |a| a["kind"] })
    uc(:resolve_finance_alert).call(@actor, alerts.first["id"], resolution: "refund", notes: "Cliente prefere reembolso")

    assert_empty uc(:finance).overview(@actor)[:alerts]
    assert_raises(D::Conflict) { uc(:resolve_finance_alert).call(@actor, alerts.first["id"], resolution: "refund") }
    assert_raises(D::ValidationError) { uc(:resolve_finance_alert).call(@actor, alerts.first["id"], resolution: "talvez") }
  end

  def test_closed_reservation_with_open_charges_raises_alert_on_sync
    reservation = booking
    sync(reservation)
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Cliente cancelou")
    sync(reservation)
    sync(reservation)

    assert_equal(["reservation_closed_with_charges"], uc(:finance).overview(@actor)[:alerts].map { |a| a["kind"] })
  end

  def test_finance_tables_follow_the_tenant_conventions
    tables = %w[payment_provider_accounts receivables receivable_cancellations deposits payments refunds deposit_entries financial_entries
                finance_alerts payment_simulator_charges reconciliation_reports reconciliation_items invoices]
    rows = owner_query(<<~SQL, ["{#{tables.join(",")}}"])
      SELECT c.relname,
             c.relrowsecurity AND c.relforcerowsecurity AS rls,
             EXISTS (SELECT 1 FROM pg_constraint k
                      WHERE k.conrelid = c.oid AND k.contype IN ('u', 'p')
                        AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a
                              WHERE a.attrelid = c.oid AND a.attnum = ANY(k.conkey)) = ARRAY['id', 'organization_id']) AS tenant_key
        FROM pg_class c WHERE c.relname = ANY($1::text[]) ORDER BY c.relname
    SQL

    assert_equal(tables.sort, rows.map { |r| r["relname"] })
    assert_empty(rows.reject { |r| r["rls"] == "t" && r["tenant_key"] == "t" }, "RLS forçada e UNIQUE (organization_id, id) em toda tabela")
  end

  def test_confirmed_and_financial_records_are_immutable_in_the_database
    rental = rental_of(booking.tap { |r| sync(r) })
    paid = pay(rental, 10_000)
    conn = PG.connect(TestDatabase.app_url)
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [@org[:organization_id]])

    error = assert_raises(PG::RestrictViolation) { conn.exec_params("UPDATE payments SET notes = 'alterado' WHERE id = $1", [paid.id]) }
    assert_match(/imutável/, error.message)
    assert_raises(PG::RestrictViolation) { conn.exec_params("UPDATE receivables SET amount_cents = 1 WHERE id = $1", [rental.id]) }
    assert_raises(PG::InsufficientPrivilege) { conn.exec("UPDATE financial_entries SET debit_cents = debit_cents") }
    assert_raises(PG::InsufficientPrivilege) { conn.exec_params("DELETE FROM payments WHERE id = $1", [paid.id]) }
    assert_raises(PG::InsufficientPrivilege) { conn.exec("DELETE FROM deposit_entries") }
    error = assert_raises(PG::CheckViolation) do
      conn.exec_params(<<~SQL, [SecureRandom.uuid, @org[:organization_id], paid.id])
        INSERT INTO refunds (id, organization_id, payment_id, amount_cents, reason, status, created_at, updated_at)
        VALUES ($1, $2, $3, 10001, 'acima do pago', 'pending', now(), now())
      SQL
    end
    assert_match(/reembolsos acima/, error.message)
  ensure
    conn&.close
  end

  def test_unbalanced_journal_transaction_is_rejected_at_commit
    transaction = SecureRandom.uuid
    error = assert_raises(PG::CheckViolation) do
      @system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
        @system.repos[:ledger_entries].insert(tx, [{ "id" => SecureRandom.uuid, "transaction_id" => transaction, "position" => 1, "account" => "cash",
                                                     "debit_cents" => 100, "credit_cents" => 0, "source_type" => "test", "source_id" => SecureRandom.uuid,
                                                     "memo" => "linha sem contrapartida", "occurred_at" => @clock.now }])
      end
    end
    assert_match(/desbalanceada/, error.message)
    assert_equal 0, count("financial_entries")
  end

  def test_manual_charges_and_commercial_invoice
    reservation = booking
    assert_raises(D::ValidationError) { uc(:issue_invoice).call(@actor, reservation.id) }
    sync(reservation)
    late = uc(:create_manual_charge).call(@actor, reservation.id, kind: "late_fee", amount: money(2_500), description: "Atraso de 2 horas")

    assert_equal "additional_revenue", late.revenue_account
    assert_raises(D::ValidationError) { uc(:create_manual_charge).call(@actor, reservation.id, kind: "rental", amount: money(1), description: "x") }
    assert_raises(D::InvalidTransition) do
      uc(:create_manual_charge).call(@actor, booking(mode: "hold", day: 20).id, kind: "other", amount: money(1), description: "Taxa")
    end
    pay(rental_of(reservation), 10_000)
    invoice = uc(:issue_invoice).call(@actor, reservation.id, notes: "Pagamento em até 5 dias")

    assert_equal "FAT-000001", invoice["number"]
    assert_equal [12_500, 10_000, 2_500], invoice.values_at("total_cents", "settled_cents", "outstanding_cents")
    stored = uc(:finance).invoice(@actor, invoice["id"])

    assert_equal 2, stored["lines"].size
    assert_equal "FAT-000002", uc(:issue_invoice).call(@actor, reservation.id)["number"]
    conn = PG.connect(TestDatabase.app_url)
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [@org[:organization_id]])

    assert_raises(PG::InsufficientPrivilege) { conn.exec("UPDATE invoices SET total_cents = 0") }
  ensure
    conn&.close
  end

  def test_overview_filters_and_totals
    first = booking.tap { |r| sync(r) }
    second = booking(day: 20).tap { |r| sync(r) }
    pay(rental_of(first), 4_000)
    uc(:cancel_receivable).call(@actor, rental_of(second).id, reason: "Cancelada pelo cliente")

    data = uc(:finance).overview(@actor)

    assert_equal 2, data[:receivables].total
    assert_equal 6_000, data[:totals][:open].cents
    assert_equal(["partial"], uc(:finance).overview(@actor, status: "partial")[:receivables].items.map { |row| row[:balance].status })
    assert_equal 1, uc(:finance).overview(@actor, status: "cancelled")[:receivables].total
    assert_raises(D::ValidationError) { uc(:finance).overview(@actor, status: "inventada") }
  end

  def test_organizations_are_isolated
    rental = rental_of(booking.tap { |r| sync(r) })
    paid = pay(rental, 1_000)
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_raises(D::NotFound) { uc(:finance).receivable(other[:actor], rental.id) }
    assert_raises(D::NotFound) { uc(:finance).payment(other[:actor], paid.id) }
    assert_raises(D::NotFound) do
      uc(:register_payment).call(other[:actor], { purpose: "receivable", receivable_id: rental.id, method: "cash", amount: money(100) })
    end
    assert_raises(D::NotFound) { uc(:request_refund).call(other[:actor], paid.id, amount: money(100), reason: "Tentativa indevida") }
    assert_raises(D::NotFound) { uc(:sync_reservation_charges).call(other[:actor], rental.reservation_id) }
    assert_equal 0, uc(:finance).overview(other[:actor])[:receivables].total
    visible = @system.transactor.call(tenant_id: other[:organization_id]) do |tx|
      %w[receivables payments financial_entries].sum { |table| tx.query_value("SELECT count(*) FROM #{table}") }
    end

    assert_equal 0, visible
  end

  private

  def member(role)
    email = "#{role}@alfa.test"
    invite = uc(:invite_member).call(@actor, email: email, role: role)
    token = "#{@org[:organization_id]}.segredo-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    joined = uc(:accept_invitation).call(token: token, name: "Membro #{role}", password: "senha-muito-segura-7")
    A::Actor.user(user_id: joined[:user_id], organization_id: @org[:organization_id], role: role)
  end
end
