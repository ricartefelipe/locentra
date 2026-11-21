# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versões seguem
[SemVer](https://semver.org/lang/pt-BR/).

## [1.2.0] — 2026-11-21

### Adicionado

- **Configurações da organização:** tela em **Organização → Editar configurações** para o nome, o fuso horário
  (fusos do Brasil, com confirmação e as consequências da troca), a validade padrão do bloqueio temporário
  (5 a 1440 minutos) e a política de cancelamento (de 1 a 6 faixas), com pré-visualização, restauração dos
  valores padrão, controle otimista entre abas e histórico. Somente usuários com `organization.manage`
  alteram; credenciais não alteram.
- **Filiais:** detalhe com vínculos (ativos, estoque, reservas, orçamentos e transferências), edição de nome e
  endereço com controle otimista, desativação (recusada para a última filial ativa e com compromissos em
  aberto, com os códigos) e reativação dentro do limite do plano.
- **Permissão `organization.read`** (todos os papéis): página da organização, detalhe de filial, API e CLI. A
  página não mostra formulários nem a assinatura a quem não gerencia a organização.
- **API v1:** `GET /organization` (configurações efetivas e filiais) e `cancellation_policy` no detalhe da
  reserva.
- **CLI:** `organization show`, com `--json` igual ao objeto da API.
- **Política de cancelamento nas versões de orçamento:** cada versão guarda a política vigente com os preços;
  orçamento e portal exibem a política da versão, e a reserva exibe a política registrada.
- Passo 16 do roteiro de demonstração.

### Alterado

- O contrato copia a política de cancelamento registrada na reserva (antes, usava a política vigente na
  emissão). A reserva criada a partir de orçamento recebe a política da versão.
- Extensões, multas por atraso, vencimentos das cobranças, emissão de contrato, novas versões do documento e
  aditivos usam o fuso com que a reserva foi precificada.
- Os formulários de criação (reserva, orçamento, disponibilidade, cadastro de ativo e destino de transferência)
  listam somente filiais ativas; os de estoque, manutenção e origem de transferência mostram as inativas com
  " (inativa)". Criações ligadas a filial inativa são recusadas com "filial inativa: escolha uma filial ativa".
- Endereço de filial acima de 300 caracteres passa a ser recusado (antes era truncado).
- A mensagem de filial inexistente passa a ser "filial não encontrada".
- Os e-mails com horários informam o fuso horário.
- Formulários com data e hora abertos antes de uma troca de fuso são recusados com orientação para conferir os
  horários, sem gravar nada.
- A navegação "Organização" aparece para todos os papéis (`organization.read`).

### Atualização

- **Migration 0016** (`0016_configuracoes_organizacao.sql`). Antes de migrar, execute a verificação prévia de
  `docs/RUNBOOKS.md`, seção 14: `settings` fora do formato esperado aborta a migration com a lista das
  organizações. As requisições esperam durante a migration (travas exclusivas até o commit); use
  `lock_timeout` e uma janela curta. Não altere configurações nem filiais até todas as instâncias estarem na
  versão nova.
- Credenciais existentes não recebem `organization.read`; crie credenciais novas para usá-lo.
- **Retorno à versão 1.1.0:** a 1.1.0 ignora as colunas novas, emite contratos com a política atual de
  `settings` e não oferece a gestão de filiais (`docs/RUNBOOKS.md`, seção 14).

## [1.1.0] — 2026-11-21

### Adicionado

- **Cupons:** cadastro com código único por organização, desconto percentual ou de valor fixo, vigência,
  máximo de usos e subtotal mínimo; edição com controle otimista, desativação, reativação e exclusão somente
  de cupom nunca usado; lista com situação (vigente, agendado, expirado, esgotado, desativado), usos por
  reserva e histórico.
- **Condições negociadas por cliente:** desconto geral ou por produto, com vigência, sem sobreposição no
  mesmo cliente e escopo, e encerramento único, imediato ou agendado, com motivo.
- **Tarifas adicionais:** catálogo da organização com valor padrão; aplicação em reservas, orçamentos e
  novas versões de orçamento (até 10 por documento), com tarifa avulsa e valor ajustado para quem tem a
  permissão, e continuidade das tarifas já autorizadas na nova versão do orçamento.
- **Permissões:** `coupons.read`, `coupons.write`, `price_agreements.read`, `price_agreements.write`,
  `fees.read`, `fees.write` e `fees.override`. A redução de tarifa respeita o limite de desconto manual do
  papel; credenciais de integração não reduzem tarifas.
- **API v1:** cupons, tarifas e condições negociadas (`/coupons`, `/fees`,
  `/customers/{id}/price-agreements`, `/price-agreements/{id}/end`), com `PATCH`, `Idempotency-Key` em toda
  mutação e inteiros estritos; `fees` em `POST /reservations`.
- **CLI:** `coupons list|show|create|deactivate|reactivate`, `fees list|show` e
  `agreements list|create|end`.
- **Seed:** tarifas, cupons e condições negociadas de demonstração nas duas organizações, criados somente
  quando nunca existiram; passo 15 do roteiro de demonstração.
- **Auditoria** de todas as alterações de cadastro (`coupon.*`, `fee.*`, `price_agreement.*`).

### Alterado

- O uso de cupom passa a ser registrado por reserva (livro de usos) e é liberado quando a reserva é
  cancelada ou o bloqueio temporário expira. Na 1.0.0 o contador só aumentava. Para o limite de usos, o
  bloqueio vencido continua contando por 5 minutos, porque uma confirmação iniciada antes do vencimento
  pode estar em andamento.
- O snapshot de preços de reservas, orçamentos e contratos identifica o cupom (`coupon`), as condições
  negociadas aplicadas (`agreements` e `negotiated_agreement_id` em cada item) e, em cada tarifa, a origem e o
  valor padrão. O contrato em PDF descreve cupom, condições e tarifas.
- A recusa de cupom informa o motivo (inexistente, desativado, expirado, ainda não vigente, esgotado ou
  subtotal abaixo do mínimo), em vez da mensagem única "cupom inválido ou expirado".
- Vigências de condições negociadas do mesmo cliente e escopo não podem mais se sobrepor, e as condições não
  são alteradas depois de criadas (somente encerradas).
- O portal do cliente mostra o detalhamento de valores (condição negociada, cupom, tarifas e total) antes da
  aprovação do orçamento, na reserva e no contrato.
- O snapshot de preços de reservas e itens não pode ser alterado no banco.

### Corrigido

- Texto com caractere nulo (U+0000) ou UTF-8 inválido, em qualquer endpoint da API v1 e da web, passa a ser
  erro do cliente em vez de erro interno (500): a API responde 422 no campo (corpo JSON, em qualquer nível, e
  query string) e os formulários respondem 400, inclusive em parâmetros aninhados (`nome[chave]`) e em partes
  multipart de texto com outra codificação que não seja ASCII puro.
- O OpenAPI descreve `allocations` e `adjustments` do detalhe da reserva (`GET /reservations/{id}`), que já
  eram devolvidos na 1.0.0.

### Atualização

- **Migration 0015** (`0015_condicoes_comerciais.sql`). Antes de migrar, execute a verificação prévia de
  `docs/RUNBOOKS.md`, seção 13: condições negociadas sobrepostas herdadas da 1.0.0 abortam a migration, com
  mensagem que identifica a organização e o cliente, e precisam ser ajustadas antes. A migration altera
  `coupons`, `customer_price_agreements`, `reservations` e `reservation_items` com travas exclusivas de curta
  duração; aplique-a antes de substituir web e worker. Cupons da 1.0.0 com fim de vigência anterior ao início
  ou máximo acima de 1.000.000 continuam aceitos e podem ser desativados; a edição exige corrigir o campo.
- Credenciais de integração existentes não recebem os escopos novos; crie credenciais novas para usá-los.
- **Retorno à versão 1.0.0:** o esquema continua compatível, mas a 1.0.0 conta somente o contador antigo de
  usos (ignora os usos registrados depois da migration) e ignora o início e o encerramento das condições
  negociadas. Desative os cupons com limite que foram usados antes de voltar, e não volte depois de
  encerrar ou agendar condições (`docs/RUNBOOKS.md`, seção 13).

## [1.0.0] — 2026-11-20

Primeira versão estável da plataforma.

### Adicionado

- **Fundação:** Ruby 4.0.9 sem framework de aplicação e sem ORM; domínio de dinheiro em centavos, períodos
  semiabertos em UTC, fusos IANA e motor de disponibilidade por ocupação máxima simultânea; Docker
  multi-stage; CI com análise estática, auditoria de dependências, verificação de segredos e de imagem.
- **Organizações e acesso:** cadastro de organização com assinatura em avaliação, filiais, usuários, convites,
  sete papéis, matriz de permissões, revogação imediata, sessões opacas, CSRF, limitação de tentativas,
  confirmação de e-mail e recuperação de senha com token de uso único; credenciais de integração com escopos.
- **Planos:** limites efetivos de ativos, filiais, usuários e funcionalidades.
- **Clientes, catálogo e ativos:** pessoa física e jurídica, contatos autorizados, endereços; ativos
  individuais, estoque quantitativo e kits; histórico, situação operacional, bloqueios e transferências.
- **Reservas:** solicitação, bloqueio temporário com expiração, confirmação com revalidação atômica,
  cancelamento, reagendamento, extensão; garantias por exclusion constraint e locks no PostgreSQL.
- **Precificação:** hora, diária de 24 horas, dia de calendário, semana, mínimo, arredondamento, tolerância,
  faixas, descontos por papel, multa por atraso e snapshots; o motor aplica cupons, condições negociadas e
  tarifas adicionais (sem cadastro nesta versão, ver limitações).
- **Orçamentos e contratos:** versões, aprovação da versão aceita, conversão idempotente, PDF com versão e
  SHA-256, aceite eletrônico simples, aditivos e cancelamento com política.
- **Operação:** separação, conferência, retirada, devolução total ou parcial, inspeção, avarias e faltas com
  evidência e autorização, manutenção, transferências entre filiais, alertas de atraso.
- **Financeiro:** cobranças, pagamentos parciais, reembolsos com limite sob concorrência, cauções separadas da
  receita, diário balanceado, simulador e adaptador Asaas sandbox, webhooks recebidos deduplicados,
  conciliação, API de pagamentos com idempotência.
- **Portal do cliente:** acesso por convite, disponibilidade, solicitações, orçamentos, contratos e extrato.
- **Integrações:** worker com fila persistente, lease e fencing; outbox; e-mails via SMTP; webhooks assinados
  com proteção contra SSRF; anexos com download autenticado; API v1 documentada em OpenAPI.
- **CLI operacional** e CLI administrativa de banco.
- **Observabilidade:** logs estruturados com correlação, métricas Prometheus de baixa cardinalidade,
  liveness e readiness.
- **Operação:** seed idempotente com duas organizações, `bin/setup`, backup com papel dedicado e restauração
  exercitada, publicação de imagem por tag condicionada a verificações e a configuração explícita.
- **Testes:** unitários, propriedades, repositórios, integração, Rack com `Rack::Lint`, CLI, concorrência com
  barreiras, navegador e roteiro de demonstração de ponta a ponta.

### Limitações conhecidas

- **RF-29 atendido parcialmente:** a caução por depósito pago (recebimento, aplicação e devolução) está
  implementada; a pré-autorização em cartão (`card_preauthorization`) é modelada e recusada, porque exige
  tokenização no provedor para autorizar, capturar parcialmente e liberar sem estorno (PAN e CVV nunca são
  recebidos nem armazenados).
- Cupons, condições negociadas por cliente e tarifas adicionais não têm caso de uso, tela, endpoint nem
  comando de cadastro; o motor de preços os aplica quando existem no banco.
- Integração real com o sandbox Asaas não exercitada (sem credenciais); adaptador testado com cliente HTTP
  falso.
- Demais limitações em [`docs/STATUS.md`](docs/STATUS.md).
