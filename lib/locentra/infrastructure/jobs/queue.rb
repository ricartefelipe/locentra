# frozen_string_literal: true

require "socket"

module Locentra
  module Infrastructure
    module Jobs
      # Fila persistente no PostgreSQL.
      #
      # - `enqueue` usa a transação do negócio: a tarefa existe se e somente se a alteração foi gravada.
      # - `claim` usa transação curta com FOR UPDATE SKIP LOCKED e grava um lease (prazo + token).
      #   Tarefas 'running' com lease vencido voltam a ser elegíveis (recuperação após queda do worker),
      #   e a tentativa abandonada é encerrada como `lease_lost`. Uma tarefa com lease vencido que já
      #   usou todas as tentativas (o processo morreu durante o handler, por exemplo por falta de
      #   memória) é encerrada como `dead` em vez de ser reivindicada de novo.
      # - `complete`/`retry_later`/`kill` exigem o token do lease atual (fencing): um worker cujo lease
      #   venceu e foi assumido por outro não consegue registrar resultado.
      # - Nenhum lock de banco é mantido durante a execução da tarefa ou chamadas de rede.
      # - Reagendamentos e encerramentos sem novas tentativas somam em `job_outcome_totals` (fila, tipo
      #   e desfecho, sem dados de tenant) na mesma transação da transição: o processo web expõe os
      #   totais de todos os workers em /metrics.
      # - Cada reivindicação abre uma linha em `job_attempts`, identificada por `attempt_id`, com
      #   numeração crescente por tarefa (continua após o reprocessamento, que zera `attempts`).
      class Queue
        Claimed = Data.define(:id, :organization_id, :kind, :payload, :attempts, :max_attempts, :lease_token, :correlation_id, :attempt_id) do
          def initialize(attempt_id: nil, **)
            super
          end
        end

        def initialize(clock:, ids:, lease_seconds: 120)
          @clock = clock
          @ids = ids
          @lease_seconds = lease_seconds
        end

        # Retorna o id gerado (ou nil quando a chave única já existia). Sem RETURNING: tarefas sem
        # organização podem ser inseridas pela aplicação, mas não lidas por ela (política de RLS).
        def enqueue(tx, kind, payload = {}, run_at: nil, priority: 100, max_attempts: 10, unique_key: nil, correlation_id: nil,
                    queue: "default")
          now = @clock.now
          id = @ids.uuid
          # ON CONFLICT exige que a linha passe também pela política de leitura; por isso só é usado
          # quando há chave única (agendamentos do worker).
          conflict = unique_key ? "ON CONFLICT (unique_key) WHERE unique_key IS NOT NULL DO NOTHING" : ""
          inserted = tx.execute(<<~SQL, [id, tx.tenant_id, queue, kind, payload, priority, run_at || now, max_attempts, unique_key, correlation_id, now])
            INSERT INTO jobs (id, organization_id, queue, kind, payload, priority, run_at, max_attempts, unique_key, correlation_id, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
            #{conflict}
          SQL
          inserted == 1 ? id : nil
        end

        EXHAUSTED_LEASE = "lease expirado sem retorno do worker após o limite de tentativas"

        def claim(tx, worker:, limit:, queues: ["default"])
          now = @clock.now
          bury_exhausted(tx, now, queues)
          rows = tx.query(<<~SQL, [now, limit, queues])
            SELECT id FROM jobs
             WHERE queue = ANY($3::text[])
               AND ((status = 'pending' AND run_at <= $1) OR (status = 'running' AND lease_expires_at <= $1 AND attempts < max_attempts))
             ORDER BY priority, run_at
             LIMIT $2
               FOR UPDATE SKIP LOCKED
          SQL
          rows.map do |row|
            token = @ids.uuid
            job = tx.query_one(<<~SQL, [row["id"], token, now + @lease_seconds, worker, now])
              UPDATE jobs SET status = 'running', lease_token = $2, lease_expires_at = $3, locked_by = $4, attempts = attempts + 1, updated_at = $5
               WHERE id = $1
              RETURNING id, organization_id, kind, payload, attempts, max_attempts, lease_token, correlation_id
            SQL
            close_abandoned(tx, [job["id"]], now, nil)
            attempt_id = @ids.uuid
            # A tarefa está bloqueada (FOR UPDATE) nesta transação: o próximo número é único.
            tx.execute(<<~SQL, [attempt_id, job["id"], job["organization_id"], worker, now])
              INSERT INTO job_attempts (id, job_id, organization_id, attempt, worker, started_at)
              VALUES ($1, $2, $3, (SELECT COALESCE(MAX(attempt), 0) + 1 FROM job_attempts WHERE job_id = $2), $4, $5)
            SQL
            Claimed.new(**job.transform_keys(&:to_sym), attempt_id: attempt_id)
          end
        end

        # Renova o lease de uma execução longa. Retorna false se o lease já foi perdido.
        def heartbeat(tx, job)
          now = @clock.now
          tx.execute(<<~SQL, [job.id, job.lease_token, now + @lease_seconds, now]) == 1
            UPDATE jobs SET lease_expires_at = $3, updated_at = $4 WHERE id = $1 AND lease_token = $2 AND status = 'running'
          SQL
        end

        def complete(tx, job)
          finish(tx, job, "succeeded", nil, "succeeded")
        end

        # Reagenda com backoff exponencial limitado (com variação determinística por tarefa).
        def retry_later(tx, job, error)
          return kill(tx, job, error) if job.attempts >= job.max_attempts

          now = @clock.now
          delay = self.class.backoff(job.attempts, job.id)
          updated = tx.execute(<<~SQL, [job.id, job.lease_token, now + delay, truncate(error), now])
            UPDATE jobs SET status = 'pending', run_at = $3, last_error = $4, lease_token = NULL, lease_expires_at = NULL, locked_by = NULL, updated_at = $5
             WHERE id = $1 AND lease_token = $2 AND status = 'running'
          SQL
          record_attempt(tx, job, updated == 1 ? "retry" : "lease_lost", error, now)
          count_outcome(tx, job, "retry", now) if updated == 1
          updated == 1
        end

        def kill(tx, job, error)
          finish(tx, job, "dead", error, "dead")
        end

        def self.backoff(attempts, id)
          base = [2**[attempts, 12].min, 3600].min * 5
          jitter = id.to_s.delete("-")[-4, 4].to_i(16) % [base / 4, 1].max
          [base + jitter, 6 * 3600].min
        end

        # Tarefa da organização bloqueada para a decisão de reprocessamento (com contexto de tenant).
        def lock(tx, job_id)
          tx.query_one(<<~SQL, [job_id, tx.tenant_id!])
            SELECT id, kind, status, attempts, max_attempts, last_error FROM jobs WHERE id = $1 AND organization_id = $2 FOR UPDATE
          SQL
        end

        # Reprocessamento autorizado de tarefa morta (com contexto de tenant). O orçamento de
        # tentativas recomeça; tentativas ainda abertas (lease vencido sem retorno do worker) são
        # encerradas como `lease_lost`, e o histórico anterior não é alterado.
        def requeue(tx, job_id)
          now = @clock.now
          requeued = tx.execute(<<~SQL, [job_id, now, tx.tenant_id!]) == 1
            UPDATE jobs SET status = 'pending', run_at = $2, attempts = 0, last_error = NULL, finished_at = NULL, updated_at = $2
             WHERE id = $1 AND organization_id = $3 AND status = 'dead'
          SQL
          return false unless requeued

          tx.execute(<<~SQL, [job_id, now, tx.tenant_id!])
            UPDATE job_attempts SET finished_at = $2, outcome = 'lease_lost' WHERE job_id = $1 AND organization_id = $3 AND finished_at IS NULL
          SQL
          true
        end

        def failures(tx, limit: 50)
          tx.query(<<~SQL, [tx.tenant_id!, limit])
            SELECT id, kind, attempts, max_attempts, last_error, correlation_id, created_at, updated_at, finished_at
              FROM jobs WHERE organization_id = $1 AND status = 'dead' ORDER BY updated_at DESC LIMIT $2
          SQL
        end

        def attempts(tx, job_id)
          tx.query("SELECT attempt, worker, started_at, finished_at, outcome, error FROM job_attempts WHERE job_id = $1 ORDER BY attempt",
                   [job_id])
        end

        def self.worker_name
          "#{Socket.gethostname}:#{Process.pid}"
        end

        private

        # Tarefas cujo worker sumiu durante a última tentativa permitida: encerradas como mortas,
        # com a tentativa aberta registrada como `lease_lost` e o total por fila e tipo atualizado.
        def bury_exhausted(tx, now, queues)
          ids = tx.query(<<~SQL, [now, queues, EXHAUSTED_LEASE]).map { |row| row["id"] }
            WITH exhausted AS (
              SELECT id FROM jobs
               WHERE queue = ANY($2::text[]) AND status = 'running' AND lease_expires_at <= $1 AND attempts >= max_attempts
               LIMIT 100
                 FOR UPDATE SKIP LOCKED
            )
            UPDATE jobs j SET status = 'dead', last_error = $3, finished_at = $1, lease_token = NULL, lease_expires_at = NULL, locked_by = NULL,
                              updated_at = $1
              FROM exhausted e
             WHERE j.id = e.id
            RETURNING j.id
          SQL
          return if ids.empty?

          close_abandoned(tx, ids, now, EXHAUSTED_LEASE)
          tx.execute(<<~SQL, [ids, now])
            INSERT INTO job_outcome_totals (queue, kind, outcome, total, updated_at)
            SELECT queue, kind, 'dead', count(*), $2 FROM jobs WHERE id = ANY($1::uuid[]) GROUP BY queue, kind
            ON CONFLICT (queue, kind, outcome) DO UPDATE SET total = job_outcome_totals.total + EXCLUDED.total, updated_at = EXCLUDED.updated_at
          SQL
        end

        # Tentativas que ficaram abertas porque o worker perdeu o lease sem registrar resultado.
        def close_abandoned(tx, job_ids, now, error)
          tx.execute(<<~SQL, [job_ids, now, error])
            UPDATE job_attempts SET finished_at = $2, outcome = 'lease_lost', error = COALESCE($3, error)
             WHERE job_id = ANY($1::uuid[]) AND finished_at IS NULL
          SQL
        end

        def finish(tx, job, status, error, outcome)
          now = @clock.now
          updated = tx.execute(<<~SQL, [job.id, job.lease_token, status, truncate(error), now])
            UPDATE jobs SET status = $3, last_error = COALESCE($4, last_error), finished_at = $5, lease_token = NULL, lease_expires_at = NULL,
                            locked_by = NULL, updated_at = $5
             WHERE id = $1 AND lease_token = $2 AND status = 'running'
          SQL
          record_attempt(tx, job, updated == 1 ? outcome : "lease_lost", error, now)
          count_outcome(tx, job, outcome, now) if updated == 1 && outcome == "dead"
          updated == 1
        end

        # Fila e tipo vêm da própria linha da tarefa; nenhum identificador é gravado no total.
        def count_outcome(tx, job, outcome, now)
          tx.execute(<<~SQL, [job.id, outcome, now])
            INSERT INTO job_outcome_totals (queue, kind, outcome, total, updated_at)
            SELECT queue, kind, $2, 1, $3 FROM jobs WHERE id = $1
            ON CONFLICT (queue, kind, outcome) DO UPDATE SET total = job_outcome_totals.total + 1, updated_at = EXCLUDED.updated_at
          SQL
        end

        # Encerra somente a linha aberta por esta reivindicação (nunca uma tentativa de outro ciclo).
        def record_attempt(tx, job, outcome, error, now)
          tx.execute(<<~SQL, [job.attempt_id, job.id, now, outcome, truncate(error)])
            UPDATE job_attempts SET finished_at = $3, outcome = $4, error = $5 WHERE id = $1 AND job_id = $2 AND finished_at IS NULL
          SQL
        end

        def truncate(error)
          return nil if error.nil?

          text = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
          text[0, 2000]
        end
      end
    end
  end
end
