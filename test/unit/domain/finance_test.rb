# frozen_string_literal: true

require_relative "../unit_helper"

# Regras do financeiro sem banco: saldos, máquinas de estado, cauções, diário e conciliação.
class FinanceDomainTest < UnitTest
  F = Domain::Finance

  def money(cents) = Domain::Money.new(cents)

  def receivable(kind: "rental", amount: 10_000, source_type: kind == "rental" ? "reservation" : "manual")
    F::Receivable.build(id: "r1", organization_id: "o1", reservation_id: "res1", customer_id: "c1", kind: kind, source_type: source_type,
                        source_id: "s1", description: "Locação da reserva R-000001", amount: money(amount), due_on: Date.new(2026, 3, 10))
  end

  def manual_payment(purpose: "receivable", amount: 10_000, review: nil)
    F::Payment.manual(id: "p1", organization_id: "o1", purpose: purpose, target_id: "t1", reservation_id: "res1", customer_id: "c1",
                      payment_method: "pix", amount: money(amount), paid_at: Time.utc(2026, 3, 2), review_reason: review)
  end

  def online_payment(provider: "simulator", scenario: nil, payment_method: "pix")
    F::Payment.request(id: "p2", organization_id: "o1", purpose: "receivable", target_id: "t1", reservation_id: "res1", customer_id: "c1",
                       payment_method: payment_method, amount: money(5_000), provider: provider, account_id: "a1", due_on: Date.new(2026, 3, 5),
                       scenario: scenario)
  end

  def test_receivable_rules_and_revenue_accounts
    assert_equal "rental_revenue", receivable.revenue_account
    assert_equal "rental_revenue", receivable(kind: "extension", source_type: "reservation_adjustment").revenue_account
    assert_equal "additional_revenue", receivable(kind: "damage").revenue_account
    assert_equal "Avaria", receivable(kind: "damage").kind_label
    assert_raises(Domain::ValidationError) { receivable(kind: "juros") }
    assert_raises(Domain::ValidationError) { receivable(amount: 0) }
    assert_raises(Domain::ValidationError) { receivable(source_type: "planilha") }
    assert_raises(Domain::InvariantViolation) { receivable(kind: "rental", source_type: "manual") }
    assert_raises(Domain::ValidationError) do
      F::Receivable.build(id: "r", organization_id: "o", reservation_id: "x", customer_id: "c", kind: "other", source_type: "manual", source_id: "s",
                          description: "Taxa", amount: money(1), due_on: "2026-03-10")
    end
  end

  def test_balance_statuses
    amount = money(10_000)

    assert_equal "open", F::Balance.of(amount).status
    assert_equal %w[partial 6000], [F::Balance.of(amount, paid: money(4_000)).status, F::Balance.of(amount, paid: money(4_000)).outstanding.cents.to_s]
    assert_equal "paid", F::Balance.of(amount, paid: money(7_000), applied: money(3_000)).status
    credit = F::Balance.of(amount, paid: money(12_000))

    assert_equal %w[credit 2000 0], [credit.status, credit.credit.cents.to_s, credit.open_amount.cents.to_s]
    assert_equal "partial", F::Balance.of(amount, paid: money(12_000), refunded: money(4_000)).status
    cancelled = F::Balance.of(amount, cancelled: amount, paid: money(3_000))

    assert_equal %w[cancelled 3000 Cancelada], [cancelled.status, cancelled.credit.cents.to_s, cancelled.status_label]
    assert_equal 0, F::Balance.of(amount).credit.cents
  end

  def test_amount_parsing_refuses_floats
    assert_equal 1234, F::Amount.cents!(1234).cents
    assert_equal 50, F::Amount.cents!(" 50 ").cents
    [10.5, "10,50", nil, -1, "abc"].each do |value|
      assert_raises(Domain::ValidationError, value.inspect) { F::Amount.cents!(value) }
    end
    assert_raises(Domain::ValidationError) { F::Amount.positive!(Domain::Money.zero) }
  end

  def test_charge_helpers
    assert F::Charges.chargeable?("confirmed")
    refute F::Charges.chargeable?("held")
    assert F::Charges.chargeable?("held", prepayment: true)
    refute F::Charges.chargeable?("expired", prepayment: true)
    assert_equal "other", F::Charges.adjustment_kind("amendment")
    assert_nil F::Charges.adjustment_kind("desconhecido")
    assert_equal "Extensão da reserva R-1", F::Charges.adjustment_description("extension", "R-1")
    assert_equal "damage", F::Charges.manual_kind!("damage")
    assert_raises(Domain::ValidationError) { F::Charges.manual_kind!("rental") }
    assert_nil F::Charges.manual_allowed!("cancelled")
    assert_raises(Domain::InvalidTransition) { F::Charges.manual_allowed!("held") }
  end

  def test_manual_payment_is_born_confirmed
    payment = manual_payment

    assert_predicate payment, :confirmed?
    assert_predicate payment, :final?
    assert_predicate payment, :manual?
    refute_predicate payment, :online?
    assert_predicate payment, :refundable?
    assert_equal "p1", payment.external_reference
    assert_equal ["Pix", "Registro manual", "Confirmado"], [payment.method_label, payment.provider_label, payment.status_label]
    refute_predicate manual_payment(purpose: "deposit"), :refundable?
    assert_equal "t1", manual_payment(purpose: "deposit").deposit_id
    assert manual_payment(review: "revisar").requires_review
    assert_raises(Domain::InvalidTransition) { payment.transition("pending") }
    assert_raises(Domain::ValidationError) { manual_payment(purpose: "presente") }
    assert_raises(Domain::ValidationError) do
      F::Payment.manual(id: "p", organization_id: "o", purpose: "receivable", target_id: "t", reservation_id: "r", customer_id: "c",
                        payment_method: "cheque", amount: money(1), paid_at: Time.now)
    end
  end

  def test_online_payment_state_machine
    payment = online_payment

    assert_equal %w[pending_submission success], [payment.status, payment.simulator_scenario]
    assert_nil online_payment(provider: "asaas", scenario: "fail").simulator_scenario
    assert_raises(Domain::ValidationError) { online_payment(scenario: "explodir") }
    assert_raises(Domain::ValidationError) { online_payment(payment_method: "cash") }
    assert_raises(Domain::ValidationError) { online_payment(provider: "manual") }
    unknown = payment.attempt.transition("submission_unknown")

    assert_equal 1, unknown.submission_attempts
    assert_equal "pending_submission", unknown.transition("pending_submission").status
    pending = unknown.adopt("sim_1", "https://pagar.example/1").transition("pending")

    assert_equal "sim_1", pending.adopt("sim_2", nil).provider_payment_id, "identificador do provedor não é substituído"
    confirmed = pending.confirm(Time.utc(2026, 3, 3), review_reason: "pagamento após expiração")

    assert_equal [true, Time.utc(2026, 3, 3)], [confirmed.requires_review, confirmed.paid_at]
    assert_equal "failed", pending.fail(nil).status
    assert_equal "recusado", pending.fail("").failure_reason
    assert_equal "cancelled", pending.cancel("removida").status
    assert_raises(Domain::InvalidTransition) { confirmed.cancel("tarde demais") }
    assert_equal "confirmed", payment.confirm(Time.utc(2026, 3, 3)).status, "webhook antes da resposta do envio"
  end

  def test_review_findings
    kind, message = F::Review.for_reservation("expired")

    assert_equal "payment_after_expiration", kind
    assert_match(/não foi reativada/, message)
    assert_equal "payment_after_cancellation", F::Review.for_reservation("cancelled").first
    assert_nil F::Review.for_reservation("confirmed")
    assert_nil F::Review.amount_mismatch(money(100), money(100))
    assert_nil F::Review.amount_mismatch(money(100), nil)
    assert_equal "payment_amount_mismatch", F::Review.amount_mismatch(money(100), money(90)).first
    assert_nil F::Review.reason_text([])
    assert_equal "a b", F::Review.reason_text([%w[x a], %w[y b]])
  end

  def test_refund_policy_and_state_machine
    payment = manual_payment

    assert_equal money(4_000), F::RefundPolicy.check!(payment, committed: money(6_000), amount: money(4_000))
    error = assert_raises(Domain::Conflict) { F::RefundPolicy.check!(payment, committed: money(6_000), amount: money(4_001)) }
    assert_equal "refund_exceeds_eligible", error.code
    assert_raises(Domain::ValidationError) { F::RefundPolicy.check!(payment, committed: Domain::Money.zero, amount: Domain::Money.zero) }
    assert_raises(Domain::ValidationError) { F::RefundPolicy.check!(manual_payment(purpose: "deposit"), committed: Domain::Money.zero, amount: money(1)) }
    assert_raises(Domain::InvalidTransition) { F::RefundPolicy.check!(online_payment, committed: Domain::Money.zero, amount: money(1)) }
    assert_equal 0, F::RefundPolicy.eligible(online_payment, Domain::Money.zero).cents
    assert_equal 3_000, F::RefundPolicy.eligible(payment, money(7_000)).cents
    manual = F::Refund.build(id: "f1", organization_id: "o1", payment: payment, amount: money(100), reason: "Ajuste", now: Time.utc(2026, 3, 2))

    assert_equal "confirmed", manual.status
    online = F::Refund.build(id: "f2", organization_id: "o1", payment: online_payment.confirm(Time.now), amount: money(100), reason: "Ajuste",
                             now: Time.now)

    assert_predicate online, :pending?
    assert_equal "Locentra reembolso f2", online.provider_description
    assert_equal "Falhou", online.fail(nil).status_label
    assert_raises(Domain::InvalidTransition) { manual.fail("tarde") }
    assert_raises(Domain::ValidationError) { F::Refund.build(id: "f", organization_id: "o", payment: payment, amount: money(1), reason: "", now: Time.now) }
  end

  def test_deposit_rules
    error = assert_raises(Domain::ValidationError) { open_deposit(kind: "card_preauthorization") }
    assert_match(/tokenização do cartão/, error.message)
    assert_match(/CVV/, error.message)
    assert_raises(Domain::ValidationError) { open_deposit(kind: "cheque") }
    assert_raises(Domain::InvalidTransition) { open_deposit(status: "expired") }
    assert_raises(Domain::ValidationError) { open_deposit(expected: Domain::Money.zero) }
    deposit = open_deposit

    assert_equal "Depósito pago", deposit.kind_label
    ledger = F::DepositLedger.empty

    assert_equal "awaiting", ledger.status
    assert_raises(Domain::Conflict) { ledger.receive!(money(30_001), deposit.expected) }
    held = ledger.receive!(money(30_000), deposit.expected)

    assert_equal %w[held Retida], [held.status, held.status_label]
    assert_equal 0, held.remaining(deposit.expected).cents
    assert_raises(Domain::Conflict) { held.apply!(money(30_001), money(50_000)) }
    assert_raises(Domain::Conflict) { held.apply!(money(10_000), money(5_000)) }
    applied = held.apply!(money(10_000), money(10_000))

    assert_raises(Domain::ValidationError) { applied.return!(money(1), "boleto") }
    assert_raises(Domain::Conflict) { applied.return!(money(20_001), "pix") }
    settled = applied.return!(money(20_000), "pix")

    assert_equal %w[settled 0], [settled.status, settled.balance.cents.to_s]
    rebuilt = F::DepositLedger.from_entries([{ kind: "receive", amount: money(30_000) }, { kind: "apply", amount: money(10_000) },
                                             { kind: "return", amount: money(20_000) }])

    assert_equal settled, rebuilt
  end

  def test_postings_are_validated
    posting = F::Posting.transfer("Pagamento", debit: "cash", credit: "receivable", amount: money(100))

    assert_equal 100, posting.total.cents
    assert posting.touches?("cash")
    refute posting.touches?("rental_revenue")
    line = F::JournalLine.debit("cash", money(100))

    [[line], [line, F::JournalLine.credit("cash", money(99))], [line, F::JournalLine.credit("caixinha", money(100))],
     [line, F::JournalLine.new(account: "receivable", debit: money(100), credit: money(100))],
     [line, F::JournalLine.new(account: "receivable", debit: money(-100), credit: money(200))]].each do |lines|
      assert_raises(Domain::InvariantViolation, lines.inspect) { F::Posting.build("inválido", lines) }
    end
    assert_raises(Domain::ValidationError) { F::Posting.transfer("zero", debit: "cash", credit: "receivable", amount: Domain::Money.zero) }
    assert_equal "Pagamento confirmado (Pix)", F::Postings.payment_confirmed(manual_payment).memo
    assert F::Postings.payment_confirmed(manual_payment(purpose: "deposit")).touches?("deposit_liability")
  end

  # Propriedade: qualquer sequência de operações gera lançamentos balanceados; o saldo da conta de
  # recebíveis coincide com os saldos derivados das cobranças; cauções nunca tocam contas de receita.
  def test_property_journal_stays_balanced_and_consistent
    property("diário balanceado e consistente com os saldos", runs: 150) do |random|
      book = Book.new
      random.rand(5..40).times { book.step(random) }
      totals = F::Postings.trial_balance(book.postings)

      assert(book.postings.all? { |p| Domain::Money.sum(p.lines.map(&:debit)) == Domain::Money.sum(p.lines.map(&:credit)) })
      assert_equal 0, totals.values.sum(&:cents), "débitos = créditos no total"
      assert_equal Domain::Money.sum(book.balances.map(&:outstanding)), totals["receivable"]
      assert_equal(-book.deposit.balance, totals["deposit_liability"])
      assert_equal(-Domain::Money.sum(book.refunds_pending), totals["refunds_payable"])
      assert(book.deposit_postings.none? { |p| F::REVENUE_ACCOUNTS.any? { |a| p.touches?(a) } }, "caução nunca é receita")
    end
  end

  def test_reconciliation_compare
    local = lambda do |id, status, cents|
      F::Reconciliation::Local.new(payment_id: id, external_reference: id, provider_payment_id: nil, status: status, amount: money(cents))
    end
    remote = lambda do |ref, status, cents, id = "sim_#{ref}"|
      F::Reconciliation::Remote.new(provider_payment_id: id, external_reference: ref, status: status, amount: money(cents))
    end
    locals = [local.call("a", "pending", 100), local.call("b", "confirmed", 200), local.call("c", "pending", 300), local.call("d", "confirmed", 400),
              local.call("e", "submission_unknown", 500), local.call("f", "pending", 600), local.call("g", "confirmed", 700)]
    remotes = [remote.call("a", "pending", 100), remote.call("b", "pending", 200), remote.call("c", "pending", 350), remote.call("f", "pending", 600),
               remote.call("f", "pending", 600, "sim_f2"), remote.call("g", "refunded", 700), remote.call("zz", "confirmed", 50),
               remote.call("old", "confirmed", 10)]
    found = F::Reconciliation.compare(locals, remotes, known_references: locals.map(&:external_reference) + ["old"])
    kinds = found.map { |d| [d.payment_id || d.external_reference, d.kind] }.sort

    assert_equal [%w[b status_mismatch], %w[c amount_mismatch], %w[d missing_remote], %w[f duplicate_remote], %w[zz missing_local]], kinds
    assert_equal "Valor divergente", found.find { |d| d.kind == "amount_mismatch" }.kind_label
    summary = F::Reconciliation.summary(found, checked: locals.size)

    assert_equal [7, 5, 1], [summary["checked"], summary["discrepancies"], summary["by_kind"]["missing_local"]]
    assert_equal ["status_mismatch"], F::Reconciliation.compare([local.call("e", "submission_unknown", 1)], [remote.call("e", "pending", 1)]).map(&:kind)
  end

  private

  def open_deposit(kind: "paid_deposit", status: "confirmed", expected: money(30_000))
    F::Deposit.open(id: "d1", organization_id: "o1", reservation_id: "res1", customer_id: "c1", reservation_status: status, kind: kind,
                    expected: expected, notes: "Caução do equipamento")
  end

  # Livro em memória que aplica as regras do domínio a operações aleatórias válidas.
  class Book
    F = Locentra::Domain::Finance
    M = Locentra::Domain::Money

    attr_reader :postings, :deposit_postings, :deposit

    def initialize
      @postings = []
      @deposit_postings = []
      @receivables = []
      @deposit = F::DepositLedger.empty
      @refunds_pending = []
    end

    def balances = @receivables.map { |r| r[:balance] }
    def refunds_pending = @refunds_pending.map { |r| r[:amount] }

    def step(random)
      case random.rand(7)
      when 0 then issue(random)
      when 1 then pay(random)
      when 2 then cancel(random)
      when 3 then refund(random)
      when 4 then settle_refund(random)
      when 5 then receive_deposit(random)
      else move_deposit(random)
      end
    end

    private

    def money(random, max) = M.new(random.rand(1..max))

    def issue(random)
      kind = %w[rental extension damage late_fee other].sample(random: random)
      receivable = F::Receivable.build(id: "r#{@receivables.size}", organization_id: "o", reservation_id: "res", customer_id: "c", kind: kind,
                                       source_type: kind == "rental" ? "reservation" : "manual", source_id: "s#{@receivables.size}",
                                       description: "Cobrança", amount: money(random, 50_000), due_on: Date.new(2026, 3, 10))
      @receivables << { receivable: receivable, balance: F::Balance.of(receivable.amount) }
      post(F::Postings.receivable_issued(receivable))
    end

    def pick(random) = @receivables.empty? ? nil : @receivables.sample(random: random)

    def update(row, **changes)
      row[:balance] = row[:balance].with(**changes.to_h { |key, value| [key, row[:balance].public_send(key) + value] })
    end

    def pay(random)
      row = pick(random)
      return unless row && !row[:balance].cancelled? && row[:balance].open_amount.positive?

      amount = M.new(random.rand(1..row[:balance].open_amount.cents))
      payment = F::Payment.manual(id: "p", organization_id: "o", purpose: "receivable", target_id: "t", reservation_id: "res", customer_id: "c",
                                  payment_method: "pix", amount: amount, paid_at: Time.utc(2026, 3, 2))
      update(row, paid: amount)
      post(F::Postings.payment_confirmed(payment))
    end

    def cancel(random)
      row = pick(random)
      return if row.nil? || row[:balance].cancelled?

      update(row, cancelled: row[:receivable].amount)
      post(F::Postings.receivable_cancelled(row[:receivable]))
    end

    def refund(random)
      row = pick(random)
      refundable = row && (row[:balance].paid - row[:balance].refunded)
      return unless refundable&.positive?

      amount = M.new(random.rand(1..refundable.cents))
      update(row, refunded: amount)
      @refunds_pending << { row: row, amount: amount }
      post(F::Postings.refund_requested(amount))
    end

    def settle_refund(random)
      return if @refunds_pending.empty?

      pending = @refunds_pending.shift
      post(random.rand(2).zero? ? F::Postings.refund_confirmed(pending[:amount]) : fail_refund(pending))
    end

    # Reembolso recusado: estorno do pedido no diário e no saldo da cobrança que o recebeu.
    def fail_refund(pending)
      update(pending[:row], refunded: -pending[:amount])
      F::Postings.refund_failed(pending[:amount])
    end

    def receive_deposit(random)
      amount = money(random, 30_000)
      @deposit = @deposit.receive!(amount, @deposit.received + amount)
      payment = F::Payment.manual(id: "p", organization_id: "o", purpose: "deposit", target_id: "d", reservation_id: "res", customer_id: "c",
                                  payment_method: "cash", amount: amount, paid_at: Time.utc(2026, 3, 2))
      deposit_post(F::Postings.payment_confirmed(payment))
    end

    def move_deposit(random)
      return unless @deposit.balance.positive?

      row = pick(random)
      if row && !row[:balance].cancelled? && row[:balance].open_amount.positive? && random.rand(2).zero?
        amount = M.new(random.rand(1..[@deposit.balance.cents, row[:balance].open_amount.cents].min))
        @deposit = @deposit.apply!(amount, row[:balance].open_amount)
        update(row, applied: amount)
        deposit_post(F::Postings.deposit_applied(amount))
      else
        amount = M.new(random.rand(1..@deposit.balance.cents))
        @deposit = @deposit.return!(amount, "pix")
        deposit_post(F::Postings.deposit_returned(amount))
      end
    end

    def post(posting) = @postings << posting

    def deposit_post(posting)
      @deposit_postings << posting
      post(posting)
    end
  end
end
