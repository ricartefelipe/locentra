-- Tarefas de identidade sem organização e métricas agregadas da fila.

-- A aplicação pode apenas INSERIR tarefas de e-mail de identidade sem organização (recuperação
-- de senha e confirmação de e-mail ocorrem antes de existir contexto de tenant). Não há política
-- de leitura dessas linhas para a aplicação; somente o worker as consome.
CREATE POLICY app_identity_jobs_insert ON jobs FOR INSERT TO locentra_app
  WITH CHECK (organization_id IS NULL AND kind IN ('email.password_reset', 'email.confirmation'));

-- Agregados por fila e estado, gravados pelo worker e lidos pelo endpoint de métricas. Não contém
-- dados de tenant nem identificadores.
CREATE TABLE queue_stats (
  queue text NOT NULL,
  status text NOT NULL,
  size integer NOT NULL CHECK (size >= 0),
  oldest_age_seconds numeric NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (queue, status)
);
REVOKE INSERT, UPDATE, DELETE ON queue_stats FROM locentra_app;
