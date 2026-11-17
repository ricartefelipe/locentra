# frozen_string_literal: true

# Cenário financeiro: organização, cliente, produto com diária de R$ 100,00 e caução de R$ 300,00.
module FinanceHelpers
  def finance_setup(org = nil)
    @org = org || create_organization
    @actor = @org[:actor]
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-FIN", tracking: "bulk", pricing: { "daily_cents" => 10_000 }, deposit: money(30_000))
    stock(@actor, @chairs, @org[:branch], 50)
  end

  def money(cents) = Locentra::Domain::Money.new(cents)

  def rental_period(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))

  def booking(mode: "confirm", quantity: 1, day: 10, **extra)
    reserve(@actor, @customer, @org[:branch], rental_period(day), [line(@chairs, quantity)], mode: mode, **extra)
  end

  def sync(reservation, **) = uc(:sync_reservation_charges).call(@actor, reservation.id, **)
  def charges(reservation) = uc(:finance).reservation(@actor, reservation.id)[:receivables]
  def rental_of(reservation) = charges(reservation).find { |row| row[:receivable].kind == "rental" }[:receivable]
  def balance_of(receivable) = uc(:finance).receivable(@actor, receivable.id)[:balance]

  def pay(receivable, cents, method: "cash", actor: @actor, **)
    uc(:register_payment).call(actor, { purpose: "receivable", receivable_id: receivable.id, method: method, amount: money(cents), ** })
  end

  def simulator_account(actor = @actor) = uc(:configure_payment_account).call(actor, provider: "simulator", name: "Simulador local")

  def request_online(receivable, cents, scenario: "success", method: "pix")
    uc(:request_payment).call(@actor, { purpose: "receivable", receivable_id: receivable.id, method: method, amount: money(cents), scenario: scenario })
  end

  def payment(id) = uc(:finance).payment(@actor, id)[:payment]

  def trial_balance = uc(:finance).overview(@actor)[:trial_balance].transform_values(&:cents)

  def unbalanced_transactions
    owner_query(<<~SQL)
      SELECT transaction_id FROM financial_entries GROUP BY transaction_id HAVING sum(debit_cents) <> sum(credit_cents)
    SQL
  end

  def count(table, where = "TRUE", params = [])
    owner_query("SELECT count(*) AS n FROM #{table} WHERE #{where}", params).first["n"].to_i
  end
end
