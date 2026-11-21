# frozen_string_literal: true

require_relative "api_v1_helper"

# Operação na API v1 (Rack::Lint): separação 201/200, conferência com erros reunidos, entrega, cancelamento,
# retirantes autorizados condicionados ao escopo, itens a devolver, devolução parcial e total com inspeção,
# inspeções e alertas paginados, idempotência, escopos, isolamento entre organizações e conformidade com o
# OpenAPI.
class OperationsApiTest < ApiV1TestCase
  SCOPES = %w[fulfillment.write inspections.write reservations.read customers.read].freeze

  def setup
    super
    @token = token(SCOPES)
  end

  def rental = confirmed([line(@camera, 1), line(@chairs, 4)])
  def asset_line(body) = body["lines"].find { |row| row["allocated_asset_id"] }
  def stock_line(body) = body["lines"].find { |row| row["allocated_asset_id"].nil? }

  def check_body(body)
    { "items" => [{ "line_id" => asset_line(body)["id"], "tag" => asset_line(body)["allocated_tag"] },
                  { "line_id" => stock_line(body)["id"], "quantity" => stock_line(body)["expected_quantity"] }] }
  end

  # Separação e conferência pela API, prontas para a entrega.
  def checked_pickup(reservation = rental)
    body = post!(201, "/reservations/#{reservation.id}/pickups")
    post!(200, "/pickups/#{body["id"]}/check", check_body(body))
  end

  def delivered(reservation = rental)
    pickup = checked_pickup(reservation)
    post!(200, "/pickups/#{pickup["id"]}/deliver", { "picker" => { "kind" => "customer" } })
  end

  def entries_for(reservation, **extra)
    get!(200, "/reservations/#{reservation.id}/return-items")["lines"].map do |row|
      { "pickup_line_id" => row["id"], "outcome" => "ok", "quantity" => row["pending_quantity"] }.merge(extra.transform_keys(&:to_s))
    end
  end

  # Retirada, devolução com inspeção e alerta de atraso na Beta, para conferir o isolamento.
  def beta_records
    actor = @beta[:actor]
    reservation = beta_reservation
    pickup = uc(:start_pickup).call(actor, reservation.id)
    uc(:check_pickup).call(actor, pickup.id, check_entries(actor, pickup))
    uc(:deliver_pickup).call(actor, pickup.id, picker: { kind: "customer" })
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    uc(:detect_overdue).call(A::Actor.system(organization_id: @beta[:organization_id]))
    lines = uc(:return_form).call(actor, reservation.id)[:lines]
    entry = { pickup_line_id: lines.first["id"], outcome: "ok", quantity: 1, requires_inspection: true }
    row = uc(:register_return).call(actor, reservation.id, entries: [entry])
    ids = owner_query("SELECT (SELECT id FROM inspections) AS inspection, (SELECT id FROM reservation_alerts LIMIT 1) AS alert",
                      [], tenant: @beta[:organization_id]).first
    { reservation: reservation.id, pickup: pickup.id, return: row["id"], inspection: ids["inspection"], alert: ids["alert"] }
  end

  # Retirada ---------------------------------------------------------------------------------------

  def test_start_pickup_creates_then_returns_the_same_separation
    reservation = rental
    body = post!(201, "/reservations/#{reservation.id}/pickups")

    assert_conforms body, "Pickup"
    assert_equal "/api/v1/pickups/#{body["id"]}", location
    assert_equal ["picking", reservation.code, 2, nil], [body["status"], body["reservation"]["code"], body["lines"].size, body["picker"]]
    assert_equal [@camera.id, @chairs.id].sort, body["lines"].map { |row| row["product_id"] }.sort
    again = post!(200, "/reservations/#{reservation.id}/pickups")

    assert_equal [body["id"], "/api/v1/pickups/#{body["id"]}"], [again["id"], location]
    assert_equal 1, count("SELECT count(*) FROM pickups")
    assert_conforms get!(200, "/pickups/#{body["id"]}"), "Pickup"
    post!(403, "/reservations/#{reservation.id}/pickups", {}, token: token(%w[reservations.read]))

    assert_error "forbidden"
    assert_idempotent("/reservations/#{rental.id}/pickups", {}, 201)
  end

  def test_check_gathers_errors_and_refuses_text_quantities
    body = post!(201, "/reservations/#{rental.id}/pickups")
    post!(422, "/pickups/#{body["id"]}/check", { "items" => [{ "line_id" => asset_line(body)["id"], "tag" => "CAM-INEXISTENTE" },
                                                             { "line_id" => stock_line(body)["id"], "quantity" => 9 }] })

    assert_error "validation_error"

    assert_equal({ "patrimonio" => ["patrimônio CAM-INEXISTENTE não encontrado"], "quantidade" => ["entre 0 e 4"] }, fields)
    post!(422, "/pickups/#{body["id"]}/check", { "items" => [{ "line_id" => stock_line(body)["id"], "quantity" => "4" }] })

    assert_equal({ "quantidade" => ["informe um número inteiro"] }, fields)
    post!(422, "/pickups/#{body["id"]}/check", { "items" => "tudo" })

    assert_equal ["itens"], fields.keys
    post!(422, "/pickups/#{body["id"]}/check", { "items" => [] })

    assert_equal({ "itens" => ["informe ao menos um item conferido"] }, fields)
    checked = assert_idempotent("/pickups/#{body["id"]}/check", check_body(body), 200)

    assert_conforms checked, "Pickup"
    assert_equal(%w[checked checked], checked["lines"].map { |row| row["status"] })
    assert_equal [1, 4], [asset_line(checked)["checked_quantity"], stock_line(checked)["checked_quantity"]]
  end

  def test_delivery_rules_and_duplicate_delivery
    reservation = rental
    body = post!(201, "/reservations/#{reservation.id}/pickups")
    post!(422, "/pickups/#{body["id"]}/deliver", { "picker" => { "kind" => "customer" } })

    assert_equal({ "itens" => ["confira ao menos um item antes da entrega"] }, fields)
    post!(200, "/pickups/#{body["id"]}/check", check_body(body))
    post!(422, "/pickups/#{body["id"]}/deliver", { "picker" => { "kind" => "contact", "contact_id" => SecureRandom.uuid } })

    assert_equal({ "retirante" => ["contato não encontrado"] }, fields)
    post!(422, "/pickups/#{body["id"]}/deliver", { "picker" => "cliente", "notes" => 3 })

    assert_equal %w[observacoes retirante], fields.keys.sort
    delivered = assert_idempotent("/pickups/#{body["id"]}/deliver", { "picker" => { "kind" => "customer" }, "notes" => "Retirou no balcão" }, 200,
                                  changed_body: { "picker" => { "kind" => "customer" }, "notes" => "Outra observação" })

    assert_conforms delivered, "Pickup"
    assert_equal ["delivered", { "kind" => "customer", "contact_id" => nil, "name" => "Produtora Horizonte" }, "Retirou no balcão"],
                 delivered.values_at("status", "picker", "notes")
    refute_includes last_response.body, "52998224725", "o documento do retirante não é exposto"
    post!(409, "/pickups/#{body["id"]}/deliver", { "picker" => { "kind" => "customer" } })

    assert_error "already_picked_up"
    assert_equal "in_progress", reservation_status(reservation)
  end

  def test_cancel_pickup
    reservation = rental
    body = post!(201, "/reservations/#{reservation.id}/pickups")
    post!(422, "/pickups/#{body["id"]}/cancel", {})

    assert_equal ["motivo"], fields.keys
    cancelled = assert_idempotent("/pickups/#{body["id"]}/cancel", { "reason" => "Cliente não compareceu" }, 200)

    assert_conforms cancelled, "Pickup"
    assert_equal ["cancelled", "Cliente não compareceu", %w[cancelled cancelled]], [cancelled["status"], cancelled["notes"],
                                                                                    cancelled["lines"].map { |row| row["status"] }]
    assert_equal "confirmed", reservation_status(reservation)
    later = confirmed([line(@camera, 1), line(@chairs, 4)], after_rental)
    @clock.travel_to(t("2026-03-06T08:30:00Z"))
    pickup = delivered(later)
    post!(409, "/pickups/#{pickup["id"]}/cancel", { "reason" => "Tarde demais" })

    assert_error "already_picked_up"
  end

  def test_authorized_pickers_require_the_customers_scope
    contact = uc(:add_contact).call(@actor, @customer.id, { name: "Carlos Retirante", document: "11144477735", authorized_pickup: true })
    body = post!(201, "/reservations/#{rental.id}/pickups")

    assert_equal [{ "contact_id" => contact.id, "name" => "Carlos Retirante" }], body["authorized_pickers"]
    without = get!(200, "/pickups/#{body["id"]}", {}, token: token(%w[reservations.read]))

    assert_conforms without, "Pickup"
    assert_nil without["authorized_pickers"]
    refute_includes last_response.body, "11144477735"
    post!(200, "/pickups/#{body["id"]}/check", check_body(body))
    picked = post!(200, "/pickups/#{body["id"]}/deliver", { "picker" => { "kind" => "contact", "contact_id" => contact.id } })

    assert_equal({ "kind" => "contact", "contact_id" => contact.id, "name" => "Carlos Retirante" }, picked["picker"])
  end

  # Devolução --------------------------------------------------------------------------------------

  def test_return_items_and_partial_then_total_return_with_inspection
    reservation = rental
    delivered(reservation)
    items = get!(200, "/reservations/#{reservation.id}/return-items")

    assert_conforms items, "ReturnItems"
    assert_equal [[1, 4], []], [items["lines"].map { |row| row["pending_quantity"] }.sort, items["returns"]]
    camera = items["lines"].find { |row| row["product_id"] == @camera.id }
    partial = post!(201, "/reservations/#{reservation.id}/returns", { "entries" => [{ "pickup_line_id" => camera["id"], "outcome" => "ok" }] })

    assert_conforms partial, "Return"
    assert_equal ["/api/v1/returns/#{partial["id"]}", false, "in_progress"], [location, partial["completes_reservation"], reservation_status(reservation)]
    rest = entries_for(reservation, requires_inspection: true).reject { |entry| entry["quantity"].zero? }
    total = post!(201, "/reservations/#{reservation.id}/returns", { "entries" => rest, "notes" => "Conferido no balcão" })

    assert_conforms total, "Return"
    inspections = total["lines"].map { |row| row["requires_inspection"] }

    assert_equal [true, "Conferido no balcão", [true]], [total["completes_reservation"], total["notes"], inspections]
    assert_equal ["completed", 1], [reservation_status(reservation), count("SELECT count(*) FROM inspections WHERE status = 'pending'")]
    detail = get!(200, "/returns/#{partial["id"]}")

    assert_conforms detail, "Return"
    assert_equal [reservation.code, "CAM-API", "ok"], [detail["reservation_code"], detail["lines"].first["sku"], detail["lines"].first["outcome"]]
    assert_equal 2, get!(200, "/reservations/#{reservation.id}/return-items")["returns"].size
  end

  def test_return_validation_conflicts_and_idempotency
    reservation = rental
    delivered(reservation)
    line_id = get!(200, "/reservations/#{reservation.id}/return-items")["lines"].find { |row| row["product_id"] == @chairs.id }["id"]
    post!(422, "/reservations/#{reservation.id}/returns", { "entries" => [{ "pickup_line_id" => line_id, "outcome" => "perfeito" }] })

    assert_equal({ "resultado" => ["use ok, damaged ou missing"] }, fields)
    post!(422, "/reservations/#{reservation.id}/returns", { "entries" => [{ "pickup_line_id" => line_id, "outcome" => "ok", "requires_inspection" => "sim",
                                                                            "quantity" => "2" }] })

    assert_equal %w[inspecao quantidade], fields.keys.sort
    post!(422, "/reservations/#{reservation.id}/returns", { "entries" => [] })

    assert_equal({ "itens" => ["informe ao menos um item devolvido ou faltante"] }, fields)
    post!(422, "/reservations/#{reservation.id}/returns", { "entries" => "todos" })

    assert_equal ["itens"], fields.keys
    body = { "entries" => [{ "pickup_line_id" => line_id, "outcome" => "ok", "quantity" => 4 }] }

    assert_idempotent("/reservations/#{reservation.id}/returns", body, 201, changed_body: { "entries" => [{ "pickup_line_id" => line_id, "outcome" => "ok" }] })
    post!(409, "/reservations/#{reservation.id}/returns", { "entries" => [{ "pickup_line_id" => line_id, "outcome" => "ok", "quantity" => 1 }] })

    assert_error "already_returned"
    post!(403, "/reservations/#{reservation.id}/returns", body, token: token(%w[reservations.read]))
  end

  # Inspeções --------------------------------------------------------------------------------------

  def test_inspections_list_approve_and_reject
    reservation = confirmed([line(@camera, 2), line(@chairs, 3)])
    pick_up(reservation)
    return_all(reservation, requires_inspection: true)
    page = get!(200, "/inspections", { "limit" => "2" })

    assert_conforms page, "InspectionPage"
    assert_equal [2, 3, 2], [page["data"].size, page["pagination"]["total"], page["pagination"]["next_offset"]]
    assert_equal 1, get!(200, "/inspections", { "offset" => "2" })["data"].size
    get!(422, "/inspections", { "status" => "aberta" })

    assert_equal ["situacao"], fields.keys
    ids = page["data"].map { |row| row["id"] } + get!(200, "/inspections", { "offset" => "2" })["data"].map { |row| row["id"] }
    post!(403, "/inspections/#{ids[0]}/approve", {}, token: token(%w[reservations.read fulfillment.write]))

    assert_error "forbidden"
    approved = assert_idempotent("/inspections/#{ids[0]}/approve", { "notes" => "Sem avarias" }, 200)

    assert_conforms approved, "Inspection"
    assert_equal ["approved", "Sem avarias"], approved.values_at("status", "decision_notes")
    post!(422, "/inspections/#{ids[1]}/reject", {})

    assert_equal ["motivo"], fields.keys
    rejected = post!(200, "/inspections/#{ids[1]}/reject", { "notes" => "Peça danificada", "description" => "Trocar a lente" })

    assert_conforms rejected, "InspectionRejection"
    assert_equal ["rejected", rejected["maintenance_order"]["id"]], rejected["inspection"].values_at("status", "maintenance_order_id")
    assert_match(/\AOM-\d{6}\z/, rejected["maintenance_order"]["code"])
    post!(409, "/inspections/#{ids[1]}/approve", {})

    assert_error "invalid_transition"
    decided = get!(200, "/inspections", { "status" => "decided" })

    assert_equal [2, 1], [decided["pagination"]["total"], get!(200, "/inspections")["pagination"]["total"]]
  end

  # Alertas ----------------------------------------------------------------------------------------

  def test_alerts_list_filters_resolve_and_conflict
    late = rental
    other = create_customer(@actor, name: "Agência Norte", document: "11144477735")
    future = confirmed([line(@camera, 3)], after_rental, customer: other)
    delivered(late)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    page = get!(200, "/alerts")

    assert_conforms page, "AlertPage"
    assert_equal %w[affected_by_overdue overdue], page["data"].map { |row| row["kind"] }.sort
    overdue = get!(200, "/alerts", { "kind" => "overdue" })["data"]

    assert_equal [[late.id], late.code], [overdue.map { |row| row["reservation_id"] }, overdue.first["details"]["code"]]
    assert_equal 2, get!(200, "/alerts", { "reservation_id" => late.id })["pagination"]["total"], "a reserva própria e a relacionada"
    affected = get!(200, "/alerts", { "kind" => "affected_by_overdue", "reservation_id" => future.id })["data"]

    assert_equal([future.id], affected.map { |row| row["reservation_id"] })
    second = get!(200, "/alerts", { "limit" => "1", "offset" => "1" })

    assert_equal [1, nil, 1], [second["data"].size, second["pagination"]["next_offset"], get!(200, "/alerts", { "limit" => "1" })["pagination"]["next_offset"]]
    [[{ "kind" => "late" }, "tipo"], [{ "status" => "closed" }, "situacao"], [{ "reservation_id" => "x" }, "reserva"], [{ "limit" => "0" }, "limite"]]
      .each do |params, field|
        get!(422, "/alerts", params)

        assert_equal [field], fields.keys, params.inspect
      end
    post!(422, "/alerts/#{overdue.first["id"]}/resolve", { "resolution" => "ok" })

    assert_equal ["decisao"], fields.keys
    resolved = assert_idempotent("/alerts/#{overdue.first["id"]}/resolve", { "resolution" => "Cliente avisado; devolve amanhã" }, 200)

    assert_conforms resolved, "Alert"
    assert_equal ["resolved", "Cliente avisado; devolve amanhã"], resolved.values_at("status", "resolution")
    post!(409, "/alerts/#{overdue.first["id"]}/resolve", { "resolution" => "Outra decisão" })

    assert_error "invalid_transition"
    assert_equal([overdue.first["id"]], get!(200, "/alerts", { "status" => "resolved" })["data"].map { |row| row["id"] })
    post!(403, "/alerts/#{page["data"].first["id"]}/resolve", { "resolution" => "Sem escopo" }, token: token(%w[reservations.read]))
  end

  # Isolamento -------------------------------------------------------------------------------------

  def test_other_organization_ids_are_not_found_in_every_route
    beta = beta_records
    pickup = "/pickups/#{beta[:pickup]}"
    reservation = "/reservations/#{beta[:reservation]}"
    [[:get, "#{reservation}/return-items"], [:get, pickup], [:get, "/returns/#{beta[:return]}"], [:post, "#{reservation}/pickups", {}],
     [:post, "#{pickup}/check", { "items" => [{ "line_id" => beta[:pickup], "quantity" => 1 }] }],
     [:post, "#{pickup}/deliver", { "picker" => { "kind" => "customer" } }], [:post, "#{pickup}/cancel", { "reason" => "Teste" }],
     [:post, "#{reservation}/returns", { "entries" => [{ "pickup_line_id" => beta[:pickup], "outcome" => "ok" }] }],
     [:post, "/inspections/#{beta[:inspection]}/approve", {}], [:post, "/inspections/#{beta[:inspection]}/reject", { "notes" => "Teste" }],
     [:post, "/alerts/#{beta[:alert]}/resolve", { "resolution" => "Decisão de teste" }]].each do |verb, path, body|
      verb == :get ? get!(404, path) : post!(404, path, body)

      assert_error "not_found"
    end
    assert_equal [0, 0], [get!(200, "/inspections")["pagination"]["total"], get!(200, "/alerts")["pagination"]["total"]]
    get!(422, "/pickups/abc")

    assert_equal({ "id" => ["identificador inválido"] }, fields)
  end
end
