# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/organization_settings_support"

# Gestão de filiais de ponta a ponta: edição sem efeito nos contratos emitidos, desativação recusada pelos
# compromissos em aberto (com os códigos e a orientação de cada tipo) ou aceita sem eles, operações
# recusadas e aceitas numa filial inativa, filial inexistente e reativação no limite do plano.
class OrganizationBranchesTest < DatabaseTest
  include OrganizationSettingsSupport

  INACTIVE = { "filial" => ["filial inativa: escolha uma filial ativa"] }.freeze

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @main = @org[:branch]
    @north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE", address: "Av. Norte, 100")
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-FIL", tracking: "serialized", pricing: { "daily_cents" => 10_000 })
    @chairs = create_product(@actor, sku: "CAD-FIL", tracking: "bulk", pricing: { "daily_cents" => 1_000 })
  end

  def window(day) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def book(branch, day: 10, mode: "confirm", product: @chairs) = reserve(@actor, @customer, branch, window(day), [line(product, 1)], mode: mode)
  def deactivate(branch = @north) = uc(:set_branch_active).call(@actor, branch.id, active: false)
  def reactivate(branch = @north) = uc(:set_branch_active).call(@actor, branch.id, active: true)
  def refused(&) = assert_raises(D::Conflict, &)
  def invalid(&) = assert_raises(D::ValidationError, &).errors

  def quote_input(branch, day: 12)
    { customer_id: @customer.id, branch_id: branch.id, period: window(day), lines: [line(@chairs, 1)], valid_until: t("2026-03-05T12:00:00Z") }
  end

  def test_editing_the_branch_keeps_the_name_registered_in_issued_contracts
    stock(@actor, @chairs, @north, 5)
    contract = uc(:issue_contract).call(@actor, book(@north).id)
    result = uc(:update_branch).call(@actor, @north.id, name: "Unidade Norte II", address: "Av. Norte, 200", lock_version: "1")

    assert_equal [true, "Unidade Norte II", "NORTE", 2], [result.changed, result.record.name, result.record.code, result.record.lock_version]
    assert_equal({ "name" => "Unidade Norte", "code" => "NORTE", "address" => "Av. Norte, 100" },
                 uc(:get_contract).call(@actor, contract.id)[:contract].terms["branch"])
    assert_equal "stale_branch", refused { uc(:update_branch).call(@actor, @north.id, name: "Outra", address: nil, lock_version: "1") }.code
    assert_equal({ "endereco" => ["até 300 caracteres"] }, invalid { uc(:update_branch).call(@actor, @north.id, name: "Norte", address: "x" * 301) })
  end

  def test_last_active_branch_cannot_be_deactivated
    deactivate

    error = refused { deactivate(@main) }

    assert_equal ["last_active_branch", "A organização precisa de ao menos uma filial ativa."], [error.code, error.message]
  end

  def test_open_reservations_and_quotes_and_incoming_transfers_block_the_deactivation
    stock(@actor, @chairs, @north, 5)
    stock(@actor, @chairs, @main, 5)
    reservation = book(@north)
    sent = uc(:create_quote).call(@actor, quote_input(@north))
    uc(:send_quote).call(@actor, sent.id)
    approved = uc(:create_quote).call(@actor, quote_input(@north, day: 14))
    uc(:send_quote).call(@actor, approved.id)
    uc(:approve_quote).call(@actor, approved.id, version: 1, approver_name: "Maria Compradora")
    transfer = uc(:request_transfer).call(@actor, to_branch_id: @north.id, product_id: @chairs.id, from_branch_id: @main.id, quantity: 1)
    error = refused { deactivate }

    assert_equal "branch_in_use", error.code
    assert_equal "Não é possível desativar a filial NORTE: 1 reserva em aberto (#{reservation.code}): conclua ou cancele; " \
                 "1 orçamento enviado (#{sent.code}): aguarde a decisão, registre a recusa ou crie nova versão em outra filial; " \
                 "1 orçamento aprovado (#{approved.code}): converta em reserva e conclua ou cancele a reserva; " \
                 "1 transferência pendente com destino à filial (#{transfer.code}): registre o recebimento ou cancele.", error.message
    assert_match(/R-\d{6}.*Q-\d{6}.*Q-\d{6}.*TR-\d{6}/, error.message)
  end

  def test_each_kind_of_commitment_blocks_on_its_own
    stock(@actor, @chairs, @north, 5)
    stock(@actor, @chairs, @main, 5)
    reservation = book(@north)

    assert_includes refused { deactivate }.message, "1 reserva em aberto (#{reservation.code})"
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Desistência")
    transfer = uc(:request_transfer).call(@actor, to_branch_id: @north.id, product_id: @chairs.id, from_branch_id: @main.id, quantity: 1)

    assert_includes refused { deactivate }.message, "1 transferência pendente com destino à filial (#{transfer.code})"
    uc(:cancel_transfer).call(@actor, transfer.id, reason: "Pedido duplicado")

    assert deactivate.changed
  end

  def test_deactivation_is_accepted_with_assets_stock_outgoing_transfers_drafts_and_expired_holds
    register_assets(@actor, @camera, @north, 2)
    stock(@actor, @chairs, @north, 5)
    outgoing = uc(:request_transfer).call(@actor, to_branch_id: @main.id, product_id: @chairs.id, from_branch_id: @north.id, quantity: 1)
    uc(:create_quote).call(@actor, quote_input(@north))
    book(@north, mode: "hold")
    @clock.travel_to(@clock.now + 3600)
    result = deactivate

    assert_equal [true, false, @clock.now], [result.changed, result.record.active, result.record.deactivated_at]
    data = uc(:get_branch).call(@actor, @north.id)

    assert_equal [{ assets: 2, stock_units: 5 }, "inactive"], [data[:usage], data[:branch].status]
    assert_equal "requested", outgoing.status
    refute deactivate.changed, "desativar de novo não muda nada"
  end

  def test_inactive_branch_refuses_new_commitments
    stock(@actor, @chairs, @main, 5)
    draft = uc(:create_quote).call(@actor, quote_input(@north))
    revisable = uc(:create_quote).call(@actor, quote_input(@main))
    deactivate

    assert_equal(INACTIVE, invalid { book(@north) })
    assert_equal(INACTIVE, invalid { uc(:create_quote).call(@actor, quote_input(@north)) })
    assert_equal(INACTIVE, invalid { uc(:revise_quote).call(@actor, revisable.id, quote_input(@north)) })
    assert_equal(INACTIVE, invalid { uc(:send_quote).call(@actor, draft.id) })
    assert_equal(INACTIVE, invalid { uc(:register_asset).call(@actor, { product_id: @camera.id, branch_id: @north.id, tag: "CAM-N1" }) })
    assert_equal(INACTIVE, invalid { stock(@actor, @chairs, @north, 1) })
    assert_equal(INACTIVE, invalid { uc(:adjust_stock).call(@actor, product_id: @chairs.id, branch_id: @north.id, quantity: 2, kind: "adjustment") })
    assert_equal({ "destino" => INACTIVE["filial"] },
                 invalid { uc(:request_transfer).call(@actor, to_branch_id: @north.id, product_id: @chairs.id, from_branch_id: @main.id, quantity: 1) })
    portal = portal_actor(@customer)

    assert_equal(INACTIVE, invalid { uc(:portal_availability).call(portal, branch_id: @north.id, period: window(10)) })
    assert_equal(INACTIVE, invalid { uc(:portal_request_reservation).call(portal, branch_id: @north.id, period: window(10), lines: [line(@chairs, 1)]) })
  end

  def test_inactive_branch_accepts_stock_reductions_maintenance_and_outgoing_transfers
    stock(@actor, @chairs, @north, 10)
    deactivate
    reductions = [["write_off", 1], ["loss", 1], ["adjustment", -1]].map do |kind, quantity|
      uc(:adjust_stock).call(@actor, product_id: @chairs.id, branch_id: @north.id, quantity: quantity, kind: kind).total_quantity
    end

    assert_equal [9, 8, 7], reductions
    order = uc(:open_maintenance_order).call(@actor, product_id: @chairs.id, branch_id: @north.id, quantity: 1, description: "Reparo do assento")

    assert_equal 1, order.quantity
    transfer = uc(:request_transfer).call(@actor, to_branch_id: @main.id, product_id: @chairs.id, from_branch_id: @north.id, quantity: 2)

    assert_equal [@north.id, @main.id], [transfer.from_branch_id, transfer.to_branch_id]
  end

  def test_missing_branch_is_reported_in_the_feminine
    missing = SecureRandom.uuid
    errors = [
      lambda {
        reserve(@actor, @customer, D::Organizations::Branch.new(id: missing, organization_id: nil, name: "", code: "", address: nil, active: true),
                window(10), [line(@chairs, 1)])
      },
      -> { uc(:adjust_stock).call(@actor, product_id: @chairs.id, branch_id: missing, quantity: 1, kind: "write_off") },
      -> { uc(:get_branch).call(@actor, missing) }
    ].map { |call| assert_raises(D::NotFound, &call).message }

    assert_equal ["filial não encontrada"] * 3, errors
  end

  def test_reactivation_respects_the_plan_limit
    third = uc(:create_branch).call(@actor, name: "Unidade Sul", code: "SUL")
    deactivate
    uc(:create_branch).call(@actor, name: "Unidade Leste", code: "LESTE")
    error = assert_raises(D::PlanLimitExceeded) { reactivate }

    assert_equal "Limite de filiais do plano Profissional atingido (3)", error.message
    deactivate(third)

    assert reactivate.changed, "com uma vaga, a reativação é aceita no limite"
    assert_equal 3, uc(:get_organization).call(@actor)[:branches].count(&:active)
  end
end
