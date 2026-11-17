# frozen_string_literal: true

require "socket"

module Locentra
  module Infrastructure
    module Jobs
      # Fila persistente no PostgreSQL.
      #
      # - `enqueue` usa a transação do negócio: a tarefa existe se e somente se a alteração foi gravada.
      # - `claim` usa transação curta com FOR UPDATE SKIP LOCKED e grava um lease (prazo + token).
      #   Tarefas 'running' com lease vencido voltam a ser elegíveis (recuperação após queda do worker).
      # - `complete`/`retry_later`/`kill` exigem o token do lease atual (fencing): um worker cujo lease
      #   venceu e foi assumido por outro não consegue registrar resultado.
      # - Nenhum lock de banco é mantido durante a execução da tarefa ou chamadas de rede.
      class Queue
        Claimed = Data.define(:id, :organization_id, :kind, :payload, :attempts, :max_attempts, :lease_token, :correlation_id)

        def initialize(clock:, ids:, lease_seconds: 120)
          @clock = clock
          @ids = ids
          @lease_seconds = lease_seconds
        end

        def enqueue(tx, kind, payload = {}, run_at: nil, priority: 100, max_attempts: 10, unique_key: nil, correlation_id: nil,
                    queue: "default")
          now = @clock.now
          tx.query_value(<<~SQL, [@ids.uuid, tx.tenant_id, queue, kind, payload, priority, run_at || now, max_attempts, unique_key, correlation_id, now])
            INSERT INTO jobs (id, organization_id, queue, kind, payload, priority, run_at, max_attempts, unique_key, correlation_id, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
            ON CONFLICT (unique_key) WHERE unique_key IS NOT NULL DO NOTHING
            RETURNING id
          SQL
        end

        def claim(tx, worker:, limit:, queues: ["default"])
          now = @clock.now
          rows = tx.query(<<~SQL, [now, limit, queues])
            SELECT id FROM jobs
             WHERE queue = ANY($3::text[])
               AND ((status = 'pending' AND run_at <= $1) OR (status = 'running' AND lease_expires_at <= $1))
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
            tx.execute(<<~SQL, [@ids.uuid, job["id"], job["organization_id"], job["attempts"], worker, now])
              INSERT INTO job_attempts (id, job_id, organization_id, attempt, worker, started_at) VALUES ($1, $2, $3, $4, $5, $6)
            SQL
            Claimed.new(**job.transform_keys(&:to_sym))
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

        # Reprocessamento autorizado de tarefa morta (com contexto de tenant).
        def requeue(tx, job_id)
          now = @clock.now
          tx.execute(<<~SQL, [job_id, now, tx.tenant_id!]) == 1
            UPDATE jobs SET status = 'pending', run_at = $2, attempts = 0, last_error = NULL, finished_at = NULL, updated_at = $2
             WHERE id = $1 AND organization_id = $3 AND status = 'dead'
          SQL
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

        def finish(tx, job, status, error, outcome)
          now = @clock.now
          updated = tx.execute(<<~SQL, [job.id, job.lease_token, status, truncate(error), now])
            UPDATE jobs SET status = $3, last_error = COALESCE($4, last_error), finished_at = $5, lease_token = NULL, lease_expires_at = NULL,
                            locked_by = NULL, updated_at = $5
             WHERE id = $1 AND lease_token = $2 AND status = 'running'
          SQL
          record_attempt(tx, job, updated == 1 ? outcome : "lease_lost", error, now)
          updated == 1
        end

        def record_attempt(tx, job, outcome, error, now)
          tx.execute(<<~SQL, [job.id, job.attempts, now, outcome, truncate(error)])
            UPDATE job_attempts SET finished_at = $3, outcome = $4, error = $5 WHERE job_id = $1 AND attempt = $2 AND finished_at IS NULL
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
