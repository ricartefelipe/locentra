# frozen_string_literal: true

require_relative "../unit_helper"

class QuotesDomainTest < UnitTest
  Q = Domain::Quotes

  def now = t("2026-03-02T12:00:00Z")
  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")

  def version(number: 1, valid_until: t("2026-03-05T12:00:00Z"), rental_period: rental, total: 24_000, pricing: {})
    Q::Version.new(id: "v#{number}", quote_id: "q1", number: number, branch_id: "b1", period: rental_period, valid_until: valid_until,
                   items: [{ "product_id" => "p1", "quantity" => 2, "total_cents" => total }], pricing: { "total_cents" => total }.merge(pricing),
                   terms: "Condições", manual_discount_bps: 0, deposit: Domain::Money.zero, total: Domain::Money.new(total), created_at: now,
                   sent_at: nil)
  end

  def draft = Q::Quote.draft(id: "q1", organization_id: "o1", customer_id: "c1", branch_id: "b1", hold_policy: "none", hold_minutes: nil)
  def sent = draft.send_version(version, now)
  def approver = Q::Approver.build(type: "staff", user_id: "u1", name: "Maria Compradora", ip: "198.51.100.1")

  def test_rules_validate_hold_policy_and_minutes
    assert_equal "none", Q::Rules.hold_policy!(nil)
    assert_equal "hold_on_send", Q::Rules.hold_policy!("hold_on_send")
    assert_raises(Domain::ValidationError) { Q::Rules.hold_policy!("sempre") }
    assert_nil Q::Rules.hold_minutes!("none", "9999")
    assert_equal 1440, Q::Rules.hold_minutes!("hold_on_send", "1440")
    assert_raises(Domain::ValidationError) { Q::Rules.hold_minutes!("hold_on_send", 1441) }
    assert_raises(Domain::ValidationError) { Q::Rules.hold_minutes!("hold_on_send", "um dia") }
  end

  def test_validity_must_be_future_bounded_and_before_the_rental_starts
    assert_equal t("2026-03-05T12:00:00Z"), Q::Rules.valid_until!(Time.at(t("2026-03-05T12:00:00Z").to_r + Rational(1, 3)), period: rental, now: now)
    assert_raises(Domain::ValidationError) { Q::Rules.valid_until!(nil, period: rental, now: now) }
    assert_raises(Domain::ValidationError) { Q::Rules.valid_until!(now, period: rental, now: now) }
    assert_raises(Domain::ValidationError) { Q::Rules.valid_until!(t("2026-03-10T08:00:01Z"), period: rental, now: now) }
    far = period("2026-12-01T08:00:00Z", "2026-12-02T08:00:00Z")

    assert_raises(Domain::ValidationError) { Q::Rules.valid_until!(t("2026-06-01T00:00:00Z"), period: far, now: now) }
    assert_nil Q::Rules.terms("   ")
    assert_equal 5000, Q::Rules.terms("x" * 6000).length
  end

  def test_approver_requires_known_type_and_name
    assert_equal "Maria Compradora", approver.name
    assert_raises(Domain::ValidationError) { Q::Approver.build(type: "robot", user_id: nil, name: "X Y", ip: nil) }
    assert_raises(Domain::ValidationError) { Q::Approver.build(type: "customer", user_id: nil, name: " ", ip: nil) }
    assert_nil Q::Approver.build(type: "customer", user_id: "u", name: "Cliente", ip: "").ip
  end

  def test_version_helpers
    v = version

    refute v.expired?(t("2026-03-05T11:59:59Z"))
    assert v.expired?(t("2026-03-05T12:00:00Z")), "a validade é exclusiva no instante final"
    assert_equal [Domain::Reservations::Line.new(product_id: "p1", quantity: 2)], v.lines
    assert_equal v.fingerprint, version(number: 2).fingerprint
    refute_equal v.fingerprint, version(total: 30_000).fingerprint
    refute_predicate v, :sent?
    delivered = v.mark_sent(now)

    assert_equal now, delivered.sent_at
    assert_predicate delivered, :sent?
    assert_equal v.fingerprint, delivered.fingerprint, "o envio não altera o conteúdo da versão"
    assert_raises(Domain::InvariantViolation) { delivered.mark_sent(now + 60) }
  end

  # As tarifas fazem parte do conteúdo comparável: trocar uma tarifa por outra de mesmo valor (total
  # igual) justifica nova versão; a ordem das tarifas e os campos internos do snapshot, não.
  def test_fingerprint_includes_fees
    delivery = { "fee_id" => "f1", "code" => "ENTREGA", "description" => "Entrega", "amount_cents" => 15_000, "default_amount_cents" => 15_000,
                 "source" => "catalog" }
    custom = { "fee_id" => nil, "code" => nil, "description" => "Taxa de estacionamento", "amount_cents" => 3_000, "default_amount_cents" => nil,
               "source" => "custom" }
    with_fees = version(pricing: { "fees" => [delivery, custom] })

    refute_equal version.fingerprint, with_fees.fingerprint
    assert_equal version.fingerprint, version(pricing: { "fees" => [] }).fingerprint, "versões anteriores não têm a chave"
    assert_equal with_fees.fingerprint, version(pricing: { "fees" => [custom, delivery] }).fingerprint
    assert_equal with_fees.fingerprint, version(pricing: { "fees" => [delivery.merge("default_amount_cents" => 18_000), custom] }).fingerprint
    refute_equal with_fees.fingerprint, version(pricing: { "fees" => [delivery.merge("fee_id" => "f2"), custom] }).fingerprint
    refute_equal with_fees.fingerprint, version(pricing: { "fees" => [delivery, custom.merge("description" => "Pedágio")] }).fingerprint
    refute_equal with_fees.fingerprint, version(pricing: { "fees" => [delivery.merge("amount_cents" => 20_000), custom] }).fingerprint
  end

  # O bloqueio do envio fica ligado ao orçamento enquanto ele está enviado ou aprovado (ainda não
  # convertido); nesse período a reserva de bloqueio não é alterada diretamente.
  def test_hold_link_is_active_only_while_sent_or_approved
    with_hold = sent.with_hold("r1")

    assert with_hold.holds_reservation?("r1")
    refute with_hold.holds_reservation?("r2")
    refute with_hold.holds_reservation?(nil)
    approved = with_hold.approve(1, version: version, approver: approver, now: now)

    assert approved.holds_reservation?("r1")
    refute approved.convert("r1", now).holds_reservation?("r1")
    refute with_hold.reject("Preço alto", now).holds_reservation?("r1")
    refute with_hold.expire(now).holds_reservation?("r1")
    refute draft.holds_reservation?(nil)
  end

  def test_send_requires_draft_current_version_valid_validity_and_future_start
    quote = sent

    assert_equal "sent", quote.status
    assert_equal now, quote.sent_at
    assert_equal "Enviado", quote.status_label
    assert_raises(Domain::InvalidTransition) { quote.send_version(version, now) }
    assert_raises(Domain::InvariantViolation) { draft.send_version(version(number: 2), now) }
    assert_raises(Domain::ValidationError) { draft.send_version(version, t("2026-03-05T12:00:00Z")) }
    started = version(valid_until: t("2026-03-04T00:00:00Z"), rental_period: period("2026-03-01T00:00:00Z", "2026-03-03T00:00:00Z"))
    error = assert_raises(Domain::ValidationError) { draft.send_version(started, now) }

    assert_equal ["inicio"], error.errors.keys
  end

  def test_approval_targets_the_current_sent_version_within_validity
    assert_raises(Domain::InvalidTransition) { draft.approve(1, version: version, approver: approver, now: now) }
    stale = assert_raises(Domain::Conflict) { sent.approve(2, version: version, approver: approver, now: now) }

    assert_equal "stale_quote_version", stale.code
    expired = assert_raises(Domain::Conflict) { sent.approve(1, version: version, approver: approver, now: t("2026-03-06T00:00:00Z")) }

    assert_equal "quote_expired", expired.code
    marked = sent.expire(now)
    again = assert_raises(Domain::Conflict) { marked.approve(1, version: version, approver: approver, now: now) }

    assert_equal "quote_expired", again.code
    approved = sent.approve(1, version: version, approver: approver, now: now)

    assert_equal ["approved", 1, "staff", "Maria Compradora", "198.51.100.1", now],
                 [approved.status, approved.approved_version, approved.approved_by_type, approved.approved_by_name, approved.approved_ip,
                  approved.approved_at]
    assert_equal "Equipe em nome do cliente", approved.approver_label
    assert_nil draft.approver_label
  end

  def test_revision_reopens_quote_and_releases_hold_reference
    with_hold = sent.with_hold("r1")
    revised = with_hold.revise(branch_id: "b2", hold_policy: "hold_on_send", hold_minutes: 60)

    assert_equal ["draft", 2, nil, nil, "b2"], [revised.status, revised.current_version, revised.hold_reservation_id, revised.sent_at, revised.branch_id]
    assert_predicate revised, :hold_on_send?
    again = draft.revise(branch_id: "b1", hold_policy: "none", hold_minutes: nil)

    assert_equal [2, "draft"], [again.current_version, again.status]
    rejected = sent.reject("Preço alto", now)

    assert_equal "draft", rejected.revise(branch_id: "b1", hold_policy: "none", hold_minutes: nil).status
    approved = sent.approve(1, version: version, approver: approver, now: now)

    assert_raises(Domain::InvalidTransition) { approved.revise(branch_id: "b1", hold_policy: "none", hold_minutes: nil) }
  end

  def test_rejection_of_a_given_version_requires_it_to_be_current
    resent = sent.revise(branch_id: "b1", hold_policy: "none", hold_minutes: nil).send_version(version(number: 2), now)
    stale = assert_raises(Domain::Conflict) { resent.reject("Preço alto", now, version: 1) }

    assert_equal "stale_quote_version", stale.code
    assert_includes stale.message, "versão atual: 2"
    assert_raises(Domain::InvalidTransition, "situação é verificada antes da versão") { draft.reject("Preço alto", now, version: 7) }
    rejected = resent.reject("Preço alto", now, version: 2)

    assert_equal ["rejected", "Preço alto"], [rejected.status, rejected.rejection_reason]
    assert_equal "rejected", resent.reject("Sem versão informada", now).status
  end

  def test_rejection_conversion_and_final_states
    assert_raises(Domain::ValidationError) { sent.reject("", now) }
    assert_raises(Domain::InvalidTransition) { draft.reject("motivo", now) }
    approved = sent.approve(1, version: version, approver: approver, now: now)
    converted = approved.convert("r9", now)

    assert_equal ["converted", "r9", now], [converted.status, converted.reservation_id, converted.converted_at]
    assert_raises(Domain::InvalidTransition) { converted.convert("r10", now) }
    assert_raises(Domain::InvalidTransition) { sent.convert("r1", now) }
  end

  def test_transition_table_is_enforced_for_every_pair
    Q::STATUSES.each_key do |from|
      quote = draft.with(status: from)
      Q::STATUSES.each_key do |to|
        if Q::TRANSITIONS.fetch(from).include?(to)
          assert_equal to, quote.transition(to).status
        else
          assert_raises(Domain::InvalidTransition, "#{from} -> #{to}") { quote.transition(to) }
        end
      end
    end
  end
end
