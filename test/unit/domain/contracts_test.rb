# frozen_string_literal: true

require_relative "../unit_helper"

class ContractsDomainTest < UnitTest
  C = Domain::Contracts
  POLICY = Domain::Organizations::CancellationPolicy::DEFAULT

  def now = t("2026-03-02T12:00:00Z")
  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")
  def zone = Domain::TimeZone.new("America/Sao_Paulo")

  def reservation(status: "confirmed")
    Domain::Reservations::Reservation.new(id: "r1", organization_id: "o1", branch_id: "b1", customer_id: "c1", code: "R-000001", status: status,
                                          source: "staff", period: rental, hold_expires_at: nil, quote_id: nil, notes: nil,
                                          total: Domain::Money.new(20_000), deposit: Domain::Money.new(5_000), version: 2)
  end

  def terms
    { "contracted_total_cents" => 20_000, "period" => C::Terms.period(rental, zone), "cancellation_policy" => POLICY }
  end

  def issued = C::Contract.issue(id: "k1", organization_id: "o1", reservation: reservation, terms: terms, now: now)

  def test_issue_requires_confirmed_or_in_progress_reservation
    contract = issued

    assert_equal ["issued", "PEND-k1", 1, "r1", "c1"], [contract.status, contract.code, contract.current_document_version, contract.reservation_id,
                                                        contract.customer_id]
    started = C::Contract.issue(id: "k2", organization_id: "o1", reservation: reservation(status: "in_progress"), terms: terms, now: now)

    assert_equal "issued", started.status
    assert_predicate started, :amendable?
  end

  def test_issue_refuses_reservations_that_are_not_confirmed
    %w[requested held cancelled expired completed].each do |status|
      error = assert_raises(Domain::Conflict) { C::Contract.issue(id: "k", organization_id: "o1", reservation: reservation(status: status), terms: terms, now: now) }

      assert_equal "reservation_not_confirmed", error.code
    end
  end

  def test_acceptance_activates_once_and_amendments_follow_sequence
    active = issued.accept(now)

    assert_equal ["active", now], [active.status, active.activated_at]
    assert_same active, active.accept(now + 60)
    amended = active.amend(2)

    assert_equal 2, amended.current_document_version
    assert_raises(Domain::InvariantViolation) { amended.amend(4) }
    closed = amended.close(now)

    assert_raises(Domain::InvalidTransition) { closed.accept(now) }
    assert_raises(Domain::InvalidTransition) { closed.amend(3) }
    refute_predicate closed, :open?
    assert_equal "Encerrado", closed.status_label
  end

  def test_acceptance_is_bound_to_the_current_document_version
    amended = issued.amend(2)

    assert_equal 2, amended.acceptable_version!(2)
    stale = assert_raises(Domain::Conflict) { amended.acceptable_version!(1) }

    assert_equal "stale_document_version", stale.code
    assert_includes stale.message, "A versão 1 do documento não é mais a vigente (versão vigente: 2)"
    assert_raises(Domain::Conflict) { issued.acceptable_version!(2) }
  end

  def test_cancellation_records_reason_and_fee
    cancelled = issued.cancel(now: now, reason: " Evento   adiado ", fee: Domain::Money.new(6_000), reservation: reservation)

    assert_equal ["cancelled", "Evento adiado", 6_000, now], [cancelled.status, cancelled.cancellation_reason, cancelled.cancellation_fee_cents,
                                                              cancelled.cancelled_at]
    assert_raises(Domain::ValidationError) { issued.cancel(now: now, reason: "", fee: Domain::Money.zero, reservation: reservation) }
    assert_raises(Domain::InvalidTransition) do
      cancelled.cancel(now: now, reason: "de novo", fee: Domain::Money.zero, reservation: reservation(status: "cancelled"))
    end
    assert_equal 20_000, issued.contracted_total.cents
    assert_equal rental.starts_at, issued.starts_at
  end

  # Depois da retirada o contrato não é cancelado (a reserva em andamento só pode ser concluída): a
  # recusa é explícita e ocorre antes de qualquer gravação.
  def test_cancellation_is_refused_after_pickup
    %w[in_progress completed].each do |status|
      started = reservation(status: status)

      refute issued.cancellable_with?(started)
      error = assert_raises(Domain::Conflict) { issued.cancel(now: now, reason: "Desistência", fee: Domain::Money.zero, reservation: started) }
      assert_equal "contract_not_cancellable", error.code
      assert_includes error.message, "encerrado após a devolução"
    end
    assert issued.cancellable_with?(reservation)
    refute issued.close(now).cancellable_with?(reservation)
  end

  def test_issued_contract_without_acceptance_can_be_closed
    closed = issued.close(now)

    assert_equal ["closed", now, nil], [closed.status, closed.closed_at, closed.activated_at]
    refute_predicate closed, :open?
  end

  def test_transition_table_is_enforced_for_every_pair
    C::STATUSES.each_key do |from|
      contract = issued.with(status: from)
      C::STATUSES.each_key do |to|
        if C::TRANSITIONS.fetch(from).include?(to)
          assert_equal to, contract.transition(to).status
        else
          assert_raises(Domain::InvalidTransition, "#{from} -> #{to}") { contract.transition(to) }
        end
      end
    end
  end

  def test_cancellation_fee_uses_the_tier_for_the_notice_given
    total = Domain::Money.new(20_000)
    starts = rental.starts_at
    cases = { 100 * 3600 => 0, 72 * 3600 => 0, (72 * 3600) - 1 => 3000, 24 * 3600 => 3000, (24 * 3600) - 1 => 10_000, 0 => 10_000, -3600 => 10_000 }
    cases.each do |seconds_before, bps|
      preview = C::Cancellation.calculate(policy: POLICY, total: total, starts_at: starts, now: starts - seconds_before)

      assert_equal bps, preview.fee_bps, "#{seconds_before} s antes do início"
      assert_equal total.percent(bps), preview.fee
    end
    late = C::Cancellation.calculate(policy: POLICY, total: total, starts_at: starts, now: starts + 5400)

    assert_equal(-1, late.hours_before)
    assert_equal({ "base_cents" => 20_000, "fee_bps" => 10_000, "fee_cents" => 20_000, "hours_before" => -1 }, late.to_h)
  end

  def test_policy_description_and_percent_labels
    lines = C::Cancellation.describe(POLICY)

    assert_equal "72 h ou mais antes do início: multa de 0% do valor contratado", lines[0]
    assert_equal "de 24 h a menos de 72 h antes do início: multa de 30% do valor contratado", lines[1]
    assert_equal "menos de 24 h antes do início (ou após o início): multa de 100% do valor contratado", lines[2]
    assert_equal(%w[25,5% 12,34% 30%], [2550, 1234, 3000].map { |bps| C::Cancellation.percent_label(bps) })
  end

  def test_acceptance_validates_identification_and_channel
    acceptance = C::Acceptance.build(name: "Joana Locatária", document: "529.982.247-25", ip: "203.0.113.9", user_agent: "x" * 600, via: "staff",
                                     user_id: "u1", now: now)

    assert_equal ["52998224725", 500, C::ACCEPTANCE_STATEMENT], [acceptance.document, acceptance.user_agent.length, acceptance.statement]
    assert_equal "11222333000181", C::Acceptance.build(name: "Empresa Ltda", document: "11.222.333/0001-81", ip: nil, user_agent: nil,
                                                       via: "portal", user_id: nil, now: now).document
    assert_raises(Domain::ValidationError) { C::Acceptance.build(name: "Jo", document: "52998224725", ip: nil, user_agent: nil, via: "staff", user_id: nil, now: now) }
    assert_raises(Domain::ValidationError) { C::Acceptance.build(name: "Joana", document: "123", ip: nil, user_agent: nil, via: "staff", user_id: nil, now: now) }
    assert_raises(Domain::ValidationError) { C::Acceptance.build(name: "Joana", document: "52998224725", ip: nil, user_agent: nil, via: "fax", user_id: nil, now: now) }
  end

  def test_terms_snapshot_helpers
    local = C::Terms.period(rental, zone)

    assert_equal ["10/03/2026 05:00", "12/03/2026 05:00", "America/Sao_Paulo"], local.values_at("starts_at_local", "ends_at_local", "timezone")
    address = Domain::Customers::Address.new(id: "a", organization_id: "o", customer_id: "c", label: "principal", street: "Rua A", number: "10",
                                             complement: nil, district: "Centro", city: "Curitiba", state: "PR", postal_code: "80000000")

    assert_equal "Rua A, 10 · Centro · Curitiba/PR · CEP 80000-000", C::Terms.format_address(address)
    amendment = C::Terms.extension_amendment(number: 1, from: rental, to: rental.with_end(t("2026-03-13T08:00:00Z")), delta: Domain::Money.new(10_000),
                                             zone: zone, description: nil, document_version: 2)

    assert_equal "Extensão da devolução de 12/03/2026 05:00 para 13/03/2026 05:00", amendment["description"]
    assert_equal "Aditivo combinado", C::Terms.extension_amendment(number: 1, from: rental, to: rental.with_end(t("2026-03-13T08:00:00Z")),
                                                                   delta: Domain::Money.zero, zone: zone, description: "Aditivo combinado",
                                                                   document_version: 2)["description"]
    snapshot = C::Terms.document_snapshot(contract: issued.with(code: "C-000001"), version: 2, reason: "amendment", amendments: [amendment],
                                          current_period: rental.with_end(t("2026-03-13T08:00:00Z")), zone: zone, now: now)

    assert_equal [30_000, "C-000001", "13/03/2026 05:00"], [snapshot["current_total_cents"], snapshot["contract_code"],
                                                            snapshot["current_period"]["ends_at_local"]]
  end
end
