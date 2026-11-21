# frozen_string_literal: true

module Locentra
  module Infrastructure
    module Persistence
      # Totais globais por desfecho (webhooks entregues, com falha, retidos e liberados, pausas de
      # endpoints e registros removidos pela retenção), gravados pelo worker na mesma transação do fato.
      # Sem organização nem identificadores: somente família, desfecho e total.
      class OutcomeTotalsRepository
        def add(tx, family, outcome, amount, now)
          return if amount.zero?

          tx.execute(<<~SQL, [family, outcome, amount, now])
            INSERT INTO worker_outcome_totals (family, outcome, total, updated_at) VALUES ($1, $2, $3, $4)
            ON CONFLICT (family, outcome) DO UPDATE SET total = worker_outcome_totals.total + EXCLUDED.total, updated_at = EXCLUDED.updated_at
          SQL
        end
      end
    end
  end
end
