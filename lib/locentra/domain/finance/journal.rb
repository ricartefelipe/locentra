# frozen_string_literal: true

module Locentra
  module Domain
    module Finance
      # Plano de contas do diário (partidas dobradas). Saldo natural: ativos (receivable, cash) devedores;
      # receitas e passivos (deposit_liability, refunds_payable) credores.
      ACCOUNTS = {
        "receivable" => "Contas a receber", "rental_revenue" => "Receita de locação", "additional_revenue" => "Receitas adicionais",
        "cash" => "Caixa e bancos", "deposit_liability" => "Cauções de clientes (passivo)", "refunds_payable" => "Reembolsos a pagar"
      }.freeze
      REVENUE_ACCOUNTS = %w[rental_revenue additional_revenue].freeze

      JournalLine = Data.define(:account, :debit, :credit) do
        def self.debit(account, amount) = new(account: account, debit: amount, credit: Money.zero)
        def self.credit(account, amount) = new(account: account, debit: Money.zero, credit: amount)

        def net = debit - credit
      end

      # Lançamento contábil: duas ou mais linhas cuja soma de débitos é igual à de créditos.
      Posting = Data.define(:memo, :lines) do
        def self.build(memo, lines)
          raise InvariantViolation, "lançamento exige ao menos duas linhas" if lines.size < 2

          lines.each do |line|
            raise InvariantViolation, "conta contábil desconhecida: #{line.account}" unless ACCOUNTS.key?(line.account)
            raise InvariantViolation, "cada linha tem exatamente um lado positivo" unless line.debit.positive? ^ line.credit.positive?
            raise InvariantViolation, "valores negativos no diário" if line.debit.negative? || line.credit.negative?
          end
          raise InvariantViolation, "lançamento desbalanceado" unless Money.sum(lines.map(&:debit)) == Money.sum(lines.map(&:credit))

          new(memo: memo.to_s[0, 300], lines: lines.freeze)
        end

        def self.transfer(memo, debit:, credit:, amount:)
          Amount.positive!(amount)
          build(memo, [JournalLine.debit(debit, amount), JournalLine.credit(credit, amount)])
        end

        def total = Money.sum(lines.map(&:debit))
        def touches?(account) = lines.any? { |line| line.account == account }
      end

      # Regras de contabilização de cada operação financeira.
      module Postings
        module_function

        def receivable_issued(receivable)
          Posting.transfer("Cobrança emitida: #{receivable.description}", debit: "receivable", credit: receivable.revenue_account,
                                                                          amount: receivable.amount)
        end

        def receivable_cancelled(receivable)
          Posting.transfer("Cancelamento compensatório: #{receivable.description}", debit: receivable.revenue_account, credit: "receivable",
                                                                                    amount: receivable.amount)
        end

        # Caução recebida é passivo (deposit_liability), nunca receita.
        def payment_confirmed(payment)
          credit = payment.purpose == "deposit" ? "deposit_liability" : "receivable"
          Posting.transfer("Pagamento confirmado (#{payment.method_label})", debit: "cash", credit: credit, amount: payment.amount)
        end

        def refund_requested(amount) = Posting.transfer("Reembolso solicitado", debit: "receivable", credit: "refunds_payable", amount: amount)
        def refund_confirmed(amount) = Posting.transfer("Reembolso pago", debit: "refunds_payable", credit: "cash", amount: amount)
        def refund_failed(amount) = Posting.transfer("Estorno de reembolso não realizado", debit: "refunds_payable", credit: "receivable", amount: amount)
        def deposit_applied(amount) = Posting.transfer("Caução aplicada a cobrança", debit: "deposit_liability", credit: "receivable", amount: amount)
        def deposit_returned(amount) = Posting.transfer("Caução devolvida", debit: "deposit_liability", credit: "cash", amount: amount)

        # Saldo por conta (débitos − créditos).
        def trial_balance(postings)
          totals = ACCOUNTS.keys.to_h { |account| [account, Money.zero] }
          postings.each { |posting| posting.lines.each { |line| totals[line.account] += line.net } }
          totals
        end
      end
    end
  end
end
