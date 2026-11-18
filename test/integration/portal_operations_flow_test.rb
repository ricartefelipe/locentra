# frozen_string_literal: true

require_relative "portal_flow_helper"

# Operações do cliente no portal pelos casos de uso: escopo por cliente e por organização em
# reservas, orçamentos e contratos, aceite e rejeição vinculados à versão exibida, download restrito
# de documentos, disponibilidade sem dados internos, solicitação de reserva e extrato financeiro.
class PortalOperationsFlowTest < PortalFlowCase
  def test_reservations_and_quotes_are_scoped_to_the_customer
    alfa = portal_customer(@actor, @customer, email: "alfa@cliente.test")
    neighbour = portal_customer(@actor, @other, email: "vizinho@cliente.test")
    own_reservation = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm")
    other_reservation = reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    own_quote = sent_quote(@actor, @customer, @branch, @camera, 20)
    other_quote = sent_quote(@actor, @other, @branch, @camera, 20)
    draft = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, lines: [line(@camera, 1)], period: rental,
                                             valid_until: t("2026-03-06T12:00:00Z") })

    assert_equal([own_reservation.id], uc(:list_reservations).call(alfa).items.map { |row| row[:reservation].id })
    assert_raises(D::NotFound) { uc(:get_reservation).call(alfa, other_reservation.id) }
    assert_equal([own_quote.id], uc(:list_quotes).call(alfa).items.map { |row| row[:quote].id })
    assert_raises(D::NotFound) { uc(:get_quote).call(alfa, draft.id) }
    assert_raises(D::NotFound) { uc(:approve_quote).call(alfa, other_quote.id, version: 1, approver_name: "Intruso") }
    assert_raises(D::NotFound) { uc(:reject_quote).call(alfa, other_quote.id, reason: "Intruso") }
    approved = uc(:approve_quote).call(alfa.with(ip: "203.0.113.30"), own_quote.id, version: 1, approver_name: "Paula Compras")

    assert_equal %w[customer 203.0.113.30], [approved.approved_by_type, approved.approved_ip]
    assert_equal "rejected", uc(:reject_quote).call(neighbour, other_quote.id, reason: "Fora do orçamento").status
    cancelled = reserve(@actor, @customer, @branch, period("2026-03-15T08:00:00Z", "2026-03-16T08:00:00Z"), [line(@camera, 1)], mode: "hold")
    uc(:cancel_reservation).call(@actor, cancelled.id, reason: "Desistência")
    home = uc(:portal_home).call(alfa)

    assert_equal([own_reservation.id], home[:reservations].map { |row| row[:reservation].id }, "a página inicial mostra somente reservas vigentes")
    assert_equal [0, 0], [home[:quotes_total], home[:contracts_total]], "orçamento já aprovado não aguarda decisão"
    assert_raises(D::AccessDenied) { uc(:portal_home).call(alfa.with(customer_id: @other.id)) }
  end

  def test_contracts_and_documents_are_scoped_to_the_customer_and_the_organization
    alfa = portal_customer(@actor, @customer, email: "alfa@cliente.test")
    own_contract = contract_for(@actor, @customer, @branch, @camera, 10)
    other_contract = contract_for(@actor, @other, @branch, @camera, 10)

    assert_equal([own_contract.id], uc(:list_contracts).call(alfa).items.map { |row| row[:contract].id })
    assert_raises(D::NotFound) { uc(:get_contract).call(alfa, other_contract.id) }
    assert_raises(D::NotFound) do
      uc(:accept_contract).call(alfa, other_contract.id, name: "Intruso Silva", document: "52998224725", confirmed: true)
    end
    row, bytes = uc(:download_attachment).call(alfa, document_of(@actor, own_contract))

    assert_equal "application/pdf", row["content_type"]
    assert bytes.start_with?("%PDF")
    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, document_of(@actor, other_contract)) }
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")
    beta_product = create_product(beta[:actor], sku: "CAM-BETA", tracking: "serialized")
    register_assets(beta[:actor], beta_product, beta[:branch], 1)
    beta_contract = contract_for(beta[:actor], create_customer(beta[:actor], name: "Cliente Beta"), beta[:branch], beta_product, 12)

    assert_raises(D::NotFound) { uc(:get_contract).call(alfa, beta_contract.id) }
    assert_raises(D::NotFound) { uc(:get_reservation).call(alfa, beta_contract.reservation_id) }
    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, document_of(beta[:actor], beta_contract)) }
    assert_raises(D::AccessDenied) { uc(:portal_home).call(alfa.with(organization_id: beta[:organization_id])) }
  end

  def test_non_contract_attachments_are_not_downloadable_by_customers
    alfa = portal_customer(@actor, @customer, email: "anexos@cliente.test")
    pdf = "%PDF-1.4 documento interno"
    attachment = uc(:upload_attachment).call(@actor, owner_type: "customer", owner_id: @customer.id, filename: "ficha.pdf", bytes: pdf)
    contract = contract_for(@actor, @customer, @branch, @camera, 14)
    note = uc(:upload_attachment).call(@actor, owner_type: "contract", owner_id: contract.id, filename: "nota-interna.pdf", bytes: pdf)

    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, attachment["id"]) }
    assert_raises(D::NotFound) { uc(:download_attachment).call(alfa, note["id"]) }
    assert_equal pdf, uc(:download_attachment).call(@actor, note["id"]).last
  end

  def test_availability_hides_internal_data_and_request_creates_portal_request
    alfa = portal_customer(@actor, @customer, email: "pedido@cliente.test")
    kit = create_product(@actor, sku: "KIT-INATIVO", tracking: "bulk")
    owner_query("UPDATE products SET active = false WHERE id = $1", [kit.id])
    reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    rows = uc(:portal_availability).call(alfa, branch_id: @branch.id, period: rental)

    assert_equal [@camera.id], rows.map(&:product_id), "somente produtos ativos"
    assert_equal({ product_id: @camera.id, name: @camera.name, description: nil, category: nil, requested: nil, available: true }, rows.first.to_h)
    two = uc(:portal_availability).call(alfa, branch_id: @branch.id, period: rental, lines: [line(@camera, 2)]).first

    assert_equal [2, false], [two.requested, two.available]
    assert_raises(D::ValidationError) { uc(:portal_availability).call(alfa, branch_id: @branch.id, period: period("2026-03-01T08:00:00Z", "2026-03-02T08:00:00Z")) }
    assert_raises(D::ValidationError) { uc(:portal_availability).call(alfa, branch_id: @branch.id, period: period("2026-03-10T08:00:00Z", "2026-07-10T08:00:00Z")) }
    beta = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_raises(D::NotFound) { uc(:portal_availability).call(alfa, branch_id: beta[:branch].id, period: rental) }
    assert_equal [@branch.id], uc(:portal_availability).branches(alfa).map(&:id)
    assert_raises(D::AccessDenied) { uc(:portal_availability).call(@actor, branch_id: @branch.id, period: rental) }
    reservation = uc(:portal_request_reservation).call(alfa, branch_id: @branch.id, period: rental, lines: [line(@camera, 2)], notes: "Entrega às 8h")

    assert_equal %w[requested portal], [reservation.status, reservation.source]
    assert_equal @customer.id, reservation.customer_id
    assert_equal 30_000, reservation.total.cents
    assert_equal 0, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE reservation_id = $1", [reservation.id]).first["n"].to_i,
                 "a solicitação não aloca disponibilidade"
    audit = owner_query("SELECT actor_type, actor_id FROM audit_events WHERE action = 'reservation.created' AND resource_id = $1", [reservation.id]).first

    assert_equal ["customer", alfa.user_id], audit.values_at("actor_type", "actor_id")
    assert_raises(D::AccessDenied) { uc(:portal_request_reservation).call(@actor, branch_id: @branch.id, period: rental, lines: [line(@camera, 1)]) }
    assert_raises(D::ValidationError) { uc(:portal_request_reservation).call(alfa, branch_id: @branch.id, period: rental, lines: []) }
    assert_raises(D::NotFound) { uc(:portal_request_reservation).call(alfa, branch_id: @branch.id, period: rental, lines: [line(kit, 1)]) }
  end

  def test_statement_shows_only_the_customer_charges_and_deposits
    alfa = portal_customer(@actor, @customer, email: "financeiro@cliente.test")
    own = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm")
    other = reserve(@actor, @other, @branch, rental, [line(@camera, 1)], mode: "confirm")
    [own, other].each { |reservation| uc(:sync_reservation_charges).call(@actor, reservation.id) }
    rental_charge = uc(:finance).reservation(@actor, own.id)[:receivables].first[:receivable]
    uc(:register_payment).call(@actor, { purpose: "receivable", receivable_id: rental_charge.id, method: "pix", amount: D::Money.new(5_000) })
    deposit = uc(:open_deposit).call(@actor, own.id, kind: "paid_deposit", amount: D::Money.new(20_000))
    uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: deposit.id, method: "pix", amount: D::Money.new(20_000) })
    statement = uc(:finance).customer_statement(alfa)

    assert_equal([own.id], statement[:receivables].map { |row| row[:receivable].reservation_id })
    assert_equal [10_000, "partial"], [statement[:receivables].first[:balance].outstanding.cents, statement[:receivables].first[:balance].status]
    assert_equal [10_000, 1], [statement[:totals][:open].cents, statement[:totals][:open_count]]
    assert_equal([[own.id, 20_000]], statement[:deposits].map { |row| [row[:deposit].reservation_id, row[:ledger].balance.cents] })
    assert_equal %i[deposits receivables totals], statement.keys.sort, "sem diário, alertas ou dados do provedor"
    staff = uc(:finance).customer_statement(@actor, customer_id: @other.id)

    assert_equal([other.id], staff[:receivables].map { |row| row[:receivable].reservation_id })
    auditor = staff_member(@org, "auditor@alfa.test", "auditor")

    assert uc(:finance).customer_statement(auditor, customer_id: @customer.id)
    assert_raises(D::AccessDenied) { uc(:finance).customer_statement(staff_member(@org, "atende@alfa.test", "attendant"), customer_id: @customer.id) }
    assert_equal 10_000, uc(:portal_home).call(alfa)[:totals][:open].cents
  end
end
