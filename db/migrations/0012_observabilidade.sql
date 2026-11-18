-- Observabilidade: totais de desfechos de tarefas somados entre todos os workers.
--
-- Os contadores de retentativas e de falhas permanentes existiam apenas na memória de cada
-- processo do worker, que não expõe HTTP. Esta tabela recebe o incremento na mesma transação que
-- reagenda ou encerra a tarefa (somente quando a transição vale, isto é, com o lease atual), e o
-- endpoint de métricas do processo web a lê para publicar contadores agregados.
--
-- Tabela global e sem dados de tenant, como `queue_stats`: não contém organização, identificadores
-- de tarefa, de cliente ou de reserva nem mensagens de erro; somente fila, tipo de tarefa, desfecho
-- e total. A aplicação web só lê; o worker grava.
CREATE TABLE job_outcome_totals (
  queue text NOT NULL CHECK (queue ~ '^[a-z_]{1,30}$'),
  kind text NOT NULL CHECK (kind ~ '^[a-z_.]{1,60}$'),
  outcome text NOT NULL CHECK (outcome IN ('retry', 'dead')),
  total bigint NOT NULL DEFAULT 0 CHECK (total >= 0),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (queue, kind, outcome)
);
REVOKE INSERT, UPDATE, DELETE ON job_outcome_totals FROM locentra_app;
REVOKE DELETE ON job_outcome_totals FROM locentra_worker;
