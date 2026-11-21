-- Configurações da organização e gestão de filiais: versão para controle otimista das configurações
-- (organizations.settings), situação das filiais com instante de desativação e versão, e política de
-- cancelamento congelada na reserva e na versão do orçamento.
--
-- Garantias:
-- * Grants por coluna: a aplicação altera somente nome, fuso, configurações, versão e atualização da
--   organização (slug, situação e documento não mudam), e somente nome, endereço, situação, desativação,
--   versão e atualização da filial (o código não muda). Organizações e filiais não são excluídas. O
--   worker não recebe UPDATE nessas tabelas e, portanto, não trava filiais (FOR SHARE exige UPDATE).
-- * Snapshots imutáveis: reservations.cancellation_policy e quote_versions.cancellation_policy são
--   gravadas na inserção e recusadas em qualquer alteração (gatilhos *_cancellation_policy_immutable),
--   inclusive pelo proprietário. O formato mínimo é verificado por CHECK; a validação completa da
--   política fica no domínio (Domain::Organizations::CancellationPolicy).
-- * Gatilhos de preenchimento para a 1.1.0 em execução: durante a implantação gradual (e no retorno), uma
--   instância 1.1.0 insere reservas e versões sem a coluna nova; o gatilho *_cancellation_policy_fill
--   preenche com a política vigente da organização (settings) ou com a padrão. A aplicação 1.2 sempre
--   informa a coluna. A remoção dos gatilhos está planejada em docs/RUNBOOKS.md.
-- * Tabelas sem FORCE só dentro da transação: com a RLS forçada nem o proprietário enxerga linhas sem
--   contexto de organização; organizations, branches, reservations, quote_versions e contracts (esta
--   somente para leitura no preenchimento) ficam sem FORCE apenas nesta transação.
-- * Verificação prévia: configurações (settings) fora do formato esperado interrompem a migration com a
--   lista das organizações, sem alterar nada. Valores JSON null são tratados como ausentes e removidos.

-- 1. Sem FORCE dentro desta transação (o proprietário não enxerga linhas sem contexto de organização).
ALTER TABLE organizations NO FORCE ROW LEVEL SECURITY;
ALTER TABLE branches NO FORCE ROW LEVEL SECURITY;
ALTER TABLE reservations NO FORCE ROW LEVEL SECURITY;
ALTER TABLE quote_versions NO FORCE ROW LEVEL SECURITY;
ALTER TABLE contracts NO FORCE ROW LEVEL SECURITY;

-- 2. Funções auxiliares ------------------------------------------------------------------------------
-- Política padrão (mesmo valor de Domain::Organizations::CancellationPolicy::DEFAULT).
CREATE FUNCTION app_default_cancellation_policy() RETURNS jsonb
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  AS $$
  SELECT '{"tiers":[{"min_hours_before":72,"fee_bps":0},{"min_hours_before":24,"fee_bps":3000},{"min_hours_before":0,"fee_bps":10000}]}'::jsonb
$$;

-- Formato mínimo (a validação de negócio completa fica no domínio): objeto com "tiers" não vazio, de até
-- 6 faixas, e campos numéricos. O CASE garante que as funções de array só recebam arrays.
CREATE FUNCTION app_cancellation_policy_shape_ok(p jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  AS $$
  SELECT CASE
           WHEN p IS NULL OR jsonb_typeof(p) <> 'object' OR jsonb_typeof(p -> 'tiers') IS DISTINCT FROM 'array' THEN false
           ELSE jsonb_array_length(p -> 'tiers') BETWEEN 1 AND 6
                AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p -> 'tiers') t
                                 WHERE jsonb_typeof(t) IS DISTINCT FROM 'object'
                                    OR jsonb_typeof(t -> 'min_hours_before') IS DISTINCT FROM 'number'
                                    OR jsonb_typeof(t -> 'fee_bps') IS DISTINCT FROM 'number')
         END
$$;
GRANT EXECUTE ON FUNCTION app_default_cancellation_policy(), app_cancellation_policy_shape_ok(jsonb) TO locentra_app, locentra_worker;

-- 3. Verificação prévia: aborta com diagnóstico, sem alterar nada. Valores JSON null são tratados como
-- ausentes. A validade do bloqueio é um inteiro de 5 a 1440 (número ou texto com dígitos).
DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(o.id::text, ', ' ORDER BY o.id) INTO bad
    FROM organizations o
   WHERE jsonb_typeof(o.settings) <> 'object'
      OR (NULLIF(o.settings -> 'cancellation_policy', 'null'::jsonb) IS NOT NULL
          AND NOT app_cancellation_policy_shape_ok(o.settings -> 'cancellation_policy'))
      OR (NULLIF(o.settings -> 'hold_minutes', 'null'::jsonb) IS NOT NULL
          AND NOT CASE WHEN (o.settings ->> 'hold_minutes') ~ '^\d{1,4}$'
                       THEN (o.settings ->> 'hold_minutes')::int BETWEEN 5 AND 1440
                       ELSE false END);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'migração 0016: configurações (settings) fora do formato esperado nas organizações %', bad
      USING HINT = 'Corrija as configurações dessas organizações antes de aplicar a migration (docs/RUNBOOKS.md, seção 14).';
  END IF;
END;
$$;
UPDATE organizations SET settings = settings - 'cancellation_policy' WHERE settings -> 'cancellation_policy' = 'null'::jsonb;
UPDATE organizations SET settings = settings - 'hold_minutes' WHERE settings -> 'hold_minutes' = 'null'::jsonb;

-- 4. Organizações ------------------------------------------------------------------------------------
ALTER TABLE organizations
  ADD COLUMN lock_version integer NOT NULL DEFAULT 1 CHECK (lock_version > 0),
  ADD CONSTRAINT organizations_settings_object CHECK (jsonb_typeof(settings) = 'object');
REVOKE UPDATE, DELETE ON organizations FROM locentra_app, locentra_worker;
GRANT UPDATE (name, timezone, settings, lock_version, updated_at) ON organizations TO locentra_app;

-- 5. Filiais -----------------------------------------------------------------------------------------
ALTER TABLE branches
  ADD COLUMN deactivated_at timestamptz,
  ADD COLUMN lock_version integer NOT NULL DEFAULT 1 CHECK (lock_version > 0);
UPDATE branches SET deactivated_at = updated_at WHERE NOT active;
ALTER TABLE branches ADD CONSTRAINT branches_active_coherent CHECK (active = (deactivated_at IS NULL));
REVOKE UPDATE, DELETE ON branches FROM locentra_app, locentra_worker;
GRANT UPDATE (name, address, active, deactivated_at, lock_version, updated_at) ON branches TO locentra_app;
-- O worker não recebe UPDATE: não trava filiais (FOR SHARE exige privilégio de UPDATE).

-- 6. Reservas: default não volátil (sem reescrita da tabela) e preenchimento só onde difere do padrão.
-- O snapshot do contrato tem prioridade: é a política aceita pelo cliente.
ALTER TABLE reservations ADD COLUMN cancellation_policy jsonb NOT NULL DEFAULT app_default_cancellation_policy();
UPDATE reservations r SET cancellation_policy = c.terms_snapshot -> 'cancellation_policy'
  FROM contracts c
 WHERE c.organization_id = r.organization_id AND c.reservation_id = r.id
   AND app_cancellation_policy_shape_ok(c.terms_snapshot -> 'cancellation_policy')
   AND c.terms_snapshot -> 'cancellation_policy' IS DISTINCT FROM app_default_cancellation_policy();
UPDATE reservations r SET cancellation_policy = o.settings -> 'cancellation_policy'
  FROM organizations o
 WHERE o.id = r.organization_id AND o.settings ? 'cancellation_policy'
   AND NOT EXISTS (SELECT 1 FROM contracts c
                    WHERE c.organization_id = r.organization_id AND c.reservation_id = r.id
                      AND app_cancellation_policy_shape_ok(c.terms_snapshot -> 'cancellation_policy'));
ALTER TABLE reservations ALTER COLUMN cancellation_policy DROP DEFAULT;
ALTER TABLE reservations ADD CONSTRAINT reservations_cancellation_policy_shape
  CHECK (app_cancellation_policy_shape_ok(cancellation_policy));

-- 7. Versões de orçamento. O gatilho de proteção recusa qualquer UPDATE que não seja o registro do envio;
-- fica desligado somente durante o preenchimento, dentro desta transação.
ALTER TABLE quote_versions ADD COLUMN cancellation_policy jsonb NOT NULL DEFAULT app_default_cancellation_policy();
ALTER TABLE quote_versions DISABLE TRIGGER quote_versions_protect;
UPDATE quote_versions v SET cancellation_policy = o.settings -> 'cancellation_policy'
  FROM organizations o
 WHERE o.id = v.organization_id AND o.settings ? 'cancellation_policy';
ALTER TABLE quote_versions ENABLE TRIGGER quote_versions_protect;
ALTER TABLE quote_versions ALTER COLUMN cancellation_policy DROP DEFAULT;
ALTER TABLE quote_versions ADD CONSTRAINT quote_versions_cancellation_policy_shape
  CHECK (app_cancellation_policy_shape_ok(cancellation_policy));
-- A aplicação já não tem UPDATE nessa coluna (somente sent_at).

-- 8. Preenchimento para inserções sem a coluna (instâncias 1.1.0 durante a atualização) e imutabilidade.
CREATE FUNCTION app_cancellation_policy_fill() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF NEW.cancellation_policy IS NULL THEN
    SELECT COALESCE(NULLIF(o.settings -> 'cancellation_policy', 'null'::jsonb), app_default_cancellation_policy())
      INTO NEW.cancellation_policy
      FROM organizations o
     WHERE o.id = NEW.organization_id;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER reservations_cancellation_policy_fill BEFORE INSERT ON reservations
  FOR EACH ROW EXECUTE FUNCTION app_cancellation_policy_fill();
CREATE TRIGGER quote_versions_cancellation_policy_fill BEFORE INSERT ON quote_versions
  FOR EACH ROW EXECUTE FUNCTION app_cancellation_policy_fill();

CREATE FUNCTION app_cancellation_policy_immutable() RETURNS trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  IF NEW.cancellation_policy IS DISTINCT FROM OLD.cancellation_policy THEN
    RAISE EXCEPTION 'a política de cancelamento registrada não pode ser alterada' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER reservations_cancellation_policy_immutable BEFORE UPDATE OF cancellation_policy ON reservations
  FOR EACH ROW EXECUTE FUNCTION app_cancellation_policy_immutable();
CREATE TRIGGER quote_versions_cancellation_policy_immutable BEFORE UPDATE OF cancellation_policy ON quote_versions
  FOR EACH ROW EXECUTE FUNCTION app_cancellation_policy_immutable();

-- 9. FORCE restaurado
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;
ALTER TABLE branches FORCE ROW LEVEL SECURITY;
ALTER TABLE reservations FORCE ROW LEVEL SECURITY;
ALTER TABLE quote_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE contracts FORCE ROW LEVEL SECURITY;
