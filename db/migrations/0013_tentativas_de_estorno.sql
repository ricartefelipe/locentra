-- Tentativas de estorno no provedor. Como no envio de cobranças, a tentativa (número e início) é gravada
-- antes da chamada de rede: uma consulta que não encontra o estorno só prova a ausência depois da janela
-- da última tentativa; dentro dela, a requisição pode estar em andamento e nada é reenviado.
ALTER TABLE refunds
  ADD COLUMN submission_attempts integer NOT NULL DEFAULT 0 CHECK (submission_attempts >= 0),
  ADD COLUMN submission_started_at timestamptz;
