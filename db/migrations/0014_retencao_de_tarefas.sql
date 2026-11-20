-- Retenção da fila: tarefas concluídas (succeeded, cancelled) são removidas em lotes pelo housekeeping do
-- worker depois do prazo de retenção, com as tentativas (job_attempts, ON DELETE CASCADE). O índice
-- parcial mantém a busca das mais antigas barata mesmo com milhões de linhas.
CREATE INDEX jobs_finished_idx ON jobs (finished_at) WHERE status IN ('succeeded', 'cancelled');
