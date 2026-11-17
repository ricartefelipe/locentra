# frozen_string_literal: true

# Atalhos para os fluxos de retirada e devolução usados nos testes de integração, concorrência e telas.
module OperationsSupport
  def rental_period = period("2026-03-03T09:00:00Z", "2026-03-04T09:00:00Z")
  def after_rental = period("2026-03-06T09:00:00Z", "2026-03-07T09:00:00Z")
  def system_actor = Locentra::Application::Actor.system(organization_id: @org[:organization_id])

  def confirmed(lines, window = rental_period, customer: @customer, actor: @actor, branch: @branch)
    reserve(actor, customer, branch, window, lines, mode: "confirm")
  end

  # Separação, conferência (patrimônios alocados e quantidades informadas) e entrega ao cliente.
  def pick_up(reservation, quantities: {}, picker: { kind: "customer" }, actor: @actor)
    pickup = uc(:start_pickup).call(actor, reservation.id)
    uc(:check_pickup).call(actor, pickup.id, check_entries(actor, pickup, quantities))
    uc(:deliver_pickup).call(actor, pickup.id, picker: picker)
  end

  def check_entries(actor, pickup, quantities = {})
    uc(:get_pickup).call(actor, pickup.id)[:lines].map do |line|
      if line["asset_id"]
        { line_id: line["id"], tag: line["allocated_tag"] }
      else
        { line_id: line["id"], quantity: quantities.fetch(line["sku"], line["expected_quantity"]) }
      end
    end
  end

  def pending_lines(reservation, actor: @actor) = uc(:return_form).call(actor, reservation.id)[:lines]

  def pending_of(line) = line["delivered_quantity"] - line["returned_quantity"] - line["missing_quantity"]

  def return_entries(reservation, outcome: "ok", **options)
    pending_lines(reservation).select { |line| pending_of(line).positive? }.map do |line|
      { pickup_line_id: line["id"], outcome: outcome, quantity: pending_of(line), **options }
    end
  end

  def return_all(reservation, outcome: "ok", actor: @actor, **options)
    uc(:register_return).call(actor, reservation.id, entries: return_entries(reservation, outcome: outcome, **options))
  end

  def available(product, window = after_rental, actor: @actor, branch: @branch)
    uc(:check_availability).call(actor, branch_id: branch.id, period: window, product_ids: [product.id]).first["available"]
  end

  def asset_status(asset_id) = owner_query("SELECT status FROM assets WHERE id = $1", [asset_id]).first["status"]

  def reservation_status(reservation) = uc(:get_reservation).call(@actor, reservation.id)[:reservation].status

  def count(sql, params = []) = owner_query(sql, params).first.values.first.to_i
end
