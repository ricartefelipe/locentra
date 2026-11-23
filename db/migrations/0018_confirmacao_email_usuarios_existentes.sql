-- Confirmação de e-mail obrigatória (ADR-031): a partir desta versão, a conta não confirmada não executa
-- ações que agem para fora em nome da organização (convites, credenciais, webhooks, provedor e cobranças de
-- pagamento, envio de orçamentos, emissão de contratos e convites do portal) e, depois de 7 dias contados de
-- users.created_at, fica somente leitura. Até a 1.3.0 a confirmação não restringia nada, e uma conta criada
-- pelo cadastro há mais de 7 dias que nunca abriu o link ficaria somente leitura no momento da atualização,
-- sem aviso prévio e, numa instalação sem envio de e-mail configurado, sem como sair dessa situação.
--
-- Por isso, todo usuário existente sem confirmação passa a ser considerado confirmado. As contas criadas
-- depois desta migration seguem a regra nova.
--
-- Garantias:
-- * Somente dados: nenhuma coluna, índice, política ou grant muda. A RLS não se aplica a `users` (tabela
--   global, exceção documentada na 0001).
-- * Nenhuma confirmação existente é alterada (`WHERE email_confirmed_at IS NULL`).
-- * Rastreabilidade: os usuários confirmados por esta migration ficam com `email_confirmed_at` igual ao
--   instante da transação, o mesmo gravado em `schema_migrations.applied_at` da versão 0018
--   (docs/RUNBOOKS.md, seção 17).
-- * Credenciais de API e CLI existentes continuam válidas: as criadas por usuários passam a ter criador
--   confirmado, que é a condição para criar credenciais a partir desta versão.
--
-- Compatibilidade com a 1.3.0 (implantação gradual e retorno): a 1.3.0 grava e lê `email_confirmed_at` como
-- antes. Um cadastro feito pela 1.3.0 depois desta migration nasce sem confirmação e segue a regra nova
-- quando a versão nova estiver no ar; o e-mail de confirmação é enviado pelas duas versões.
--
-- Locks: UPDATE de linhas de `users` (ROW EXCLUSIVE), proporcional ao número de usuários não confirmados.
-- Entradas e cadastros simultâneos esperam somente pelas linhas afetadas.

UPDATE users
   SET email_confirmed_at = now(),
       updated_at = now()
 WHERE email_confirmed_at IS NULL;
