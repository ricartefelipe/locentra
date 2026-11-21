# Registro de decisões arquiteturais

Formato curto: contexto, decisão e consequências. Decisões substituídas permanecem com o status
atualizado.

## ADR-001 — Ruby 4.0.9

- **Contexto:** a página oficial de branches do Ruby lista 4.0 e 3.4 em manutenção normal; 4.0.9 é a
  versão estável mais recente.
- **Decisão:** Ruby 4.0.9, fixado em `.ruby-version`, no `Gemfile` (`ruby file:`) e na imagem
  `ruby:4.0.9-slim-trixie`.
- **Consequências:** no Ruby 4.0, `bigdecimal`, `csv`, `logger`, `net-smtp`, `minitest` e `rake` são
  bundled gems e precisam ser declaradas no `Gemfile`. `erb`, `date`, `time`, `securerandom`, `openssl`,
  `optparse`, `net-http`, `uri` e `ipaddr` continuam default gems e não são declaradas; `json` passou a ser
  declarada na versão corrigida (ADR-011).

## ADR-002 — Sem framework de aplicação e sem ORM

- **Decisão:** dependências pontuais: Rack (interface HTTP), Puma (servidor), `pg` (driver),
  `connection_pool` (pool), `bcrypt` (senhas), `tzinfo`/`tzinfo-data` (fusos), `prawn` (PDF),
  `mail` (composição e envio de e-mail). Testes: Minitest, rack-test, SimpleCov, Ferrum.
  Análise: RuboCop, Bundler Audit.
- **Consequências:** roteamento, mapeamento de resultados, transações e migrations são código explícito
  e pequeno do projeto, limitado ao necessário para o produto.

## ADR-003 — `bigdecimal` 3.3 em vez de 4.x

- **Contexto:** Prawn 2.5.0 depende de `ttfunk` 1.8, que exige `bigdecimal ~> 3.1`.
- **Decisão:** fixar `bigdecimal ~> 3.3.1`, compatível com Ruby 4.0. `BigDecimal` é usado apenas para
  interpretar textos decimais; cálculos monetários usam inteiros e `Rational`.

## ADR-004 — PostgreSQL 18

- **Decisão:** PostgreSQL 18 (`postgres:18.7-alpine`), com `btree_gist` para exclusion constraints em
  intervalos `tstzrange`.

## ADR-005 — Intervalos semiabertos, UTC e fuso IANA

- **Decisão:** todos os períodos são `[início, fim)` em UTC com precisão de segundos. Regras locais
  (dia de calendário, horário comercial) usam o fuso IANA da organização. Horários locais inexistentes
  são rejeitados; ambíguos resolvem para a primeira ocorrência (instante UTC mais cedo).

## ADR-006 — Dinheiro em centavos inteiros

- **Decisão:** `Money` encapsula centavos `Integer` e moeda (BRL). `Float` é rejeitado. Percentuais em
  pontos-base; arredondamento meio para cima apenas quando há fração de centavo; rateios pelo método
  do maior resto preservam a soma. A API expõe `amount_cents` (inteiro), `currency` e `formatted`.

## ADR-007 — Identificadores UUIDv7 gerados pela aplicação

- **Decisão:** `SecureRandom.uuid_v7` por meio de um gerador injetável. Mantém localidade temporal nos
  índices e permite identificadores determinísticos em testes.

## ADR-008 — Testes baseados em propriedades sem dependência adicional

- **Decisão:** gerador pseudoaleatório (`Random`) semeado a partir da semente do Minitest, com a semente
  e a iteração reportadas na falha. Evita dependência extra e mantém reprodutibilidade.

## ADR-009 — Ambiente de desenvolvimento em contêineres

- **Decisão:** o fluxo suportado executa Ruby, testes e ferramentas em contêineres (`docker compose`),
  inclusive Chromium para testes de navegador. Ruby local é opcional.

## ADR-010 — Actions do GitHub fixadas por SHA

- **Decisão:** cada action é referenciada por SHA de commit com a tag como comentário; imagens de
  ferramentas usam tags de versão explícitas (sem `latest`).

## ADR-011 — Correções de segurança na imagem

- **Contexto:** a análise da imagem apontou `zlib1g` com correção publicada na Debian e a default gem
  `json` 2.18.0 do Ruby 4.0.9 afetada pela CVE-2026-33210 (corrigida em ≥ 2.19.2).
- **Decisão:** a etapa base executa `apt-get upgrade`; a default gem `json` é removida da imagem e a
  versão corrigida (`json ~> 2.21.2`) é declarada no `Gemfile`. Os executáveis carregam
  `bundler/setup`, portanto usam sempre a versão do lockfile.
- **Consequências:** `ruby -rjson` sem Bundler não funciona na imagem de execução; o healthcheck usa
  somente `net/http`. A análise continua falhando para vulnerabilidades HIGH/CRITICAL corrigíveis.

## ADR-012 — Contexto de tenant local à transação e papéis de banco separados

- **Decisão:** toda operação de negócio abre transação com `set_config('app.tenant_id', ..., true)`
  (escopo local) a partir do ator autenticado. Políticas RLS (`ENABLE` e `FORCE`) comparam
  `organization_id` com `app_tenant_id()`; ausência de contexto resulta em nenhuma linha. Três papéis de
  operação: `locentra_owner` (migrations, proprietário), `locentra_app` (web/CLI) e `locentra_worker`
  (fila), todos sem superuser e sem `BYPASSRLS`; o papel de backup `locentra_backup`, com `BYPASSRLS`, foi
  acrescentado pela ADR-024. Chaves estrangeiras compostas `(organization_id, id)`
  impedem relações entre tenants mesmo com SQL incorreto.
- **Exceções globais documentadas:** `users`, `sessions`, `user_tokens`, `rate_limits`, `plans`,
  `queue_stats` e `job_outcome_totals` (ADR-025); as políticas além do isolamento por tenant estão
  consolidadas em `ISOLAMENTO.md`. `organizations` tem RLS com leitura pelo próprio tenant, por membros ativos e pelo
  worker. Tarefas de e-mail de identidade sem organização podem ser inseridas, mas não lidas, pela
  aplicação.

## ADR-013 — Unidade de trabalho revalida o vínculo em cada operação

- **Decisão:** `Application::UnitOfWork#run` abre a transação e recarrega o vínculo do ator
  (membro ativo, credencial válida ou acesso de portal) antes de autorizar. Revogação e mudança de
  papel valem na operação seguinte, mesmo com sessão aberta.

## ADR-014 — Repositórios recebem a transação explicitamente

- **Decisão:** repositórios não acessam o pool; recebem `tx` como primeiro argumento. Abrir
  transação aninhada na mesma thread gera erro; composição de casos de uso passa `tx:`;
  rollback parcial usa `savepoint`. Conexões voltam ao pool sem transação aberta.

## ADR-015 — Garantias de disponibilidade no PostgreSQL

- **Decisão:** ativos individuais usam exclusion constraint `EXCLUDE USING gist (asset_id WITH =,
  period WITH &&) WHERE (active)`; estoque quantitativo bloqueia a linha do estoque
  (`FOR UPDATE`, em ordem de id) antes de calcular o pico com o domínio. Bloqueios temporários
  vencidos não ocupam disponibilidade e são expirados na transação que precisa do recurso.
- **Consequência:** a confirmação de bloqueio e a expiração concorrentes têm resultado definido pelo
  instante comparado a `hold_expires_at` sob o lock da reserva; a varredura usa `SKIP LOCKED`.

## ADR-016 — Código sequencial da reserva atribuído no fechamento

- **Contexto:** o contador por organização serializava todas as criações de reserva enquanto a
  transação estivesse aberta (detectado pelos testes de concorrência).
- **Decisão:** a reserva é inserida com identificador provisório e recebe o código definitivo no fim
  da transação; o lock do contador dura apenas até o commit. Códigos permanecem sem lacunas.

## ADR-017 — Idempotência na mesma transação da operação

- **Decisão:** a chave é reservada com `INSERT ... ON CONFLICT DO NOTHING` no início da transação da
  operação e o resultado 2xx é gravado antes do commit. Requisições concorrentes equivalentes aguardam
  no índice único e recebem o resultado gravado; conteúdo diferente gera `409`. Falhas não gravam a
  chave.

## ADR-018 — Sessões opacas e templates com escape automático

- **Decisão:** cookie com token aleatório de 256 bits; o banco guarda SHA-256. HttpOnly, SameSite=Lax,
  Secure e prefixo `__Host-` com HTTPS. Rotação em login e troca de organização. CSRF por token
  sincronizado por sessão; formulários públicos (entrada, cadastro, recuperação e redefinição de senha,
  aceite de convites), que não têm sessão, recusam envios com `Sec-Fetch-Site: cross-site` ou `Origin`
  diferente da aplicação (CSRF de login); com sessão, o aceite de convite exige o token. ERB com `<%= %>` escapando sempre (subclasse de `ERB` que altera o comando de
  inserção); HTML confiável só por `raw`/helpers. CSP sem `unsafe-inline`.

## ADR-019 — Tokens de uso único emitidos no envio

- **Decisão:** convites, confirmação de e-mail e recuperação de senha enfileiram apenas identificadores;
  o worker emite o token no momento do envio. Tokens nunca ficam gravados em texto claro na fila.

## ADR-020 — Worker com lease, fencing e agendamento por chave única

- **Decisão:** processo próprio (`bin/worker`) com papel `locentra_worker`, N threads de execução,
  thread de renovação de leases e thread de agendamento. Reivindicação com `FOR UPDATE SKIP LOCKED` em
  transação curta; conclusão e reagendamento exigem o `lease_token` atual. Backoff exponencial com
  variação determinística e teto de 6 horas; tarefas esgotadas ficam `dead` e podem ser reprocessadas
  por usuário com `jobs.manage`. Uma tarefa com lease vencido na última tentativa permitida (processo
  morto durante o handler) também termina `dead`, sem nova reivindicação; a tentativa abandonada é
  registrada como `lease_lost`. O agendador usa `unique_key` por janela de 60 s, de modo que vários
  workers geram uma única tarefa. Encerramento por `TERM`/`INT` via self-pipe, aguardando as threads.
- **Consequências:** entrega "pelo menos uma vez"; handlers são idempotentes (despacho da outbox marca
  `dispatched_at` sob lock; entregas de webhook são únicas por `(endpoint, evento)`; e-mails podem ser
  reenviados em caso de queda entre o envio e a conclusão).

## ADR-021 — Webhooks enviados com proteção contra SSRF

- **Decisão:** somente HTTPS em produção; todos os IPs resolvidos devem ser públicos (bloqueio de
  privados, loopback, link-local, metadados, multicast, reservados e IPv4 mapeado); conexão pelo IP
  validado (`Net::HTTP#ipaddr`); redirecionamentos não são seguidos; tempos limite por operação de rede,
  prazo total de 15 s por entrega e leitura da resposta em partes interrompida em 4 KiB; sem nova
  tentativa automática do `Net::HTTP`. Entregas na fila `webhooks`, atendida por threads próprias do
  worker (`WEBHOOK_CONCURRENCY`), isoladas das demais tarefas. Assinatura
  `t=<timestamp>,v1=<HMAC-SHA256>` com identificadores estáveis de evento e entrega. O segredo de
  assinatura é cifrado com AES-256-GCM (chave derivada por HKDF). O limite de execuções simultâneas por
  organização na fila `webhooks`, a pausa automática por endpoint e a retenção das entregas estão na ADR-029.

## ADR-022 — Anexos fora do diretório público

- **Decisão:** chaves `<organização>/<anexo>` geradas pelo servidor; tipo detectado pelo conteúdo
  (PDF, PNG, JPEG, WebP); download apenas por rota autenticada com `Content-Security-Policy: sandbox`
  e `nosniff`; remoção lógica respeitando retenção. O adaptador local pode ser substituído por object
  storage privado implementando `put/get/delete/exist?`.

## ADR-023 — Decisões dos módulos de orçamentos, contratos, operação e financeiro

As decisões detalhadas de cada módulo estão registradas na seção "Decisões" do respectivo documento:

- [`modulos/orcamentos-contratos.md`](modulos/orcamentos-contratos.md): versões imutáveis com controle de envio
  por versão; bloqueio de orçamento confirmado apenas pela conversão; conversão idempotente com lock e índice
  único; aceite eletrônico simples sem equivalência a assinatura certificada; aditivo de extensão na mesma
  transação; cancelamento recusado após a retirada.
- [`modulos/retirada-devolucao-manutencao.md`](modulos/retirada-devolucao-manutencao.md): entrega somente do
  conferido; locks de estoque em ordem de id; inspeção como bloqueio sem fim definido; evidência protegida
  após aprovação da cobrança; transferência com saída atômica frente a novas reservas.
- [`modulos/financeiro.md`](modulos/financeiro.md): sincronização idempotente de cobranças por origem;
  `submission_unknown` resolvido por consulta antes de reenvio; caução como passivo; diário balanceado
  somente inserção; webhooks vinculados à conta e à cobrança do provedor.

## ADR-024 — Backup com papel dedicado e restauração por administrador

- **Contexto:** a RLS é forçada também para o proprietário; um dump feito sem bypass sairia vazio.
- **Decisão:** papel `locentra_backup` somente leitura (`pg_read_all_data`) com `BYPASSRLS`, usado por
  `pg_dump`; restauração executada por superusuário em banco novo, preservando proprietários e políticas.
  Procedimento exercitado e registrado em `RUNBOOKS.md`.
- **Uso complementar:** o operador também usa o papel em consultas de verificação somente leitura que
  precisam enxergar todas as organizações (contagem de linhas na restauração e verificações da migration
  0015 antes de migrar e antes do retorno de versão, `RUNBOOKS.md` §4 e §13). A aplicação, o worker e a CLI
  nunca usam o papel.

## ADR-025 — Portal, CLI e observabilidade

- **Portal do cliente** ([módulo](modulos/portal-cliente.md)): acesso por convite a contato do cliente, com
  token emitido no envio; áreas separadas para sessões de portal e de equipe; aceite de contrato e rejeição de
  orçamento vinculados à versão exibida; download restrito aos documentos gerados dos contratos do próprio
  cliente; disponibilidade apresentada sem dados de alocação.
- **CLI operacional** ([módulo](modulos/cli-operacional.md)): credencial `cli` por variável de ambiente ou
  arquivo com permissões restritas; mesmos casos de uso e auditoria (`actor_type = cli`); recusa credenciais
  de migration e de worker; códigos de saída estáveis e redação de segredos na saída.
- **Observabilidade** ([módulo](modulos/navegador-observabilidade.md)): desfechos de tarefas agregados em
  tabela global sem dados de tenant e expostos pelo processo web; conflitos contados na unidade de trabalho;
  rótulos com aparência de identificador mascarados; `request_id` propagado à outbox, às tarefas e às chamadas
  externas.

## ADR-026 — Limites de taxa e IP do cliente

- **Decisão:** limites por janela fixa persistidos em `rate_limits` (valem entre processos). Entrada:
  30 por IP em 5 min e 10 por e-mail em 15 min; recuperação de senha: 10 por IP e 3 por e-mail por
  hora; cadastro: 10 por IP e 5 por e-mail por hora; redefinição de senha e aceite de convites (equipe
  e portal): 20 por IP por hora; webhook de pagamento: 1200 por IP por minuto; API: `API_RATE_LIMIT`
  por credencial por minuto (padrão 1200); solicitações de reserva do portal: 30 por usuário por hora.
  Acima do limite a resposta é `429` com `Retry-After`. Tokens de redefinição e convites são conferidos
  antes do bcrypt, e o cadastro confere o e-mail antes do hash. O IP do cliente é o par da conexão;
  `X-Forwarded-For` só é considerado quando a conexão vem de um proxy listado em `TRUSTED_PROXIES`, e
  `Forwarded` nunca é usado.
- **Consequências:** clientes atrás do mesmo NAT compartilham os limites por IP. O cadastro informa
  que o e-mail já tem conta (a conta nova entra direto na organização criada, então uma resposta neutra
  não esconderia a diferença); a enumeração fica limitada pelos limites por IP e por e-mail. Nome de
  organização repetido recebe sufixo aleatório no identificador, sem revelar a outra organização.

## ADR-027 — Condições comerciais: cupons, condições negociadas e tarifas adicionais

- **Contexto:** a versão 1.0.0 aplicava cupons, condições negociadas e tarifas no motor de preços, mas sem
  cadastro. O contador `coupons.redemptions` só aumentava: uma reserva cancelada ou um bloqueio temporário
  vencido consumia o cupom para sempre. Condições do mesmo cliente podiam se sobrepor (valia a maior), e
  não havia como saber qual condição formou um preço.
- **Livro de usos imutável e uso ativo derivado:** cada uso de cupom é uma linha de `coupon_redemptions`
  (no máximo uma por reserva), nunca alterada. O uso é ativo conforme a situação da reserva (solicitada,
  confirmada, em andamento ou concluída; ou bloqueio temporário ainda válido), então cancelamento e expiração
  liberam o uso **sem nenhuma escrita**. A alternativa de decrementar um contador na liberação criaria a ordem
  de travas estoque → reserva → cupom, inversa à da criação (cupom → estoque), com impasses entre o resgate e
  a expiração em lote do alocador. Sem escrita na liberação, o cancelamento, a expiração e o alocador não
  tocam em cupons e não há ciclo. Um cancelamento concorrente ainda não confirmado continua contando como
  uso ativo, o que é conservador.
- **Limite sob concorrência:** a criação da reserva trava o cupom (`FOR UPDATE`) e conta os usos ativos numa
  instrução separada, executada depois da trava: em READ COMMITTED, uma subconsulta na mesma instrução usaria
  o snapshot anterior à espera e não veria o uso confirmado pela transação concorrente. Um gatilho de inserção
  no livro repete a verificação no banco, com o instante do próprio uso como referência (o relógio da
  aplicação). Para o limite, aplicação (resgate e redução do máximo) e gatilho recuam esse instante por uma
  carência de 5 minutos: uma confirmação que leu o relógio antes do vencimento do bloqueio só grava a nova
  situação no COMMIT, e até lá quem conta veria o bloqueio vencido e aceitaria um uso além do máximo (ou uma
  redução do máximo abaixo dos usos). A carência é maior que a duração
  de uma transação (instruções até 15 s, ociosidade até 60 s) e que a diferença de relógio entre
  instâncias; o custo é o uso do bloqueio vencido ficar reservado por esse tempo. A situação exibida do uso
  não usa a carência.
- **Base legada:** `coupons.redemptions` fica congelado com os usos da 1.0.0 e soma-se aos usos ativos do
  livro. O livro não é reconstruído a partir de reservas antigas e a coluna não é renomeada, o que mantém a
  migration aditiva. Consequência para o retorno à 1.0.0: ela enxerga só o contador congelado e ignora os
  usos registrados depois (ver `RUNBOOKS.md`, seção 13).
- **Imutabilidade:** código, tipo e valor do cupom e código da tarifa não mudam (privilégios de coluna no
  banco); condições negociadas só recebem o encerramento, uma vez (privilégios de coluna e gatilho); o
  snapshot de preços de reservas e itens não é alterado (gatilho). Um preço registrado continua explicável
  pelo cupom, pela condição e pelas tarifas gravados no snapshot. Cupom usado não é excluído, só desativado.
- **Sem sobreposição de condições:** vigências efetivas do mesmo cliente e escopo (geral ou produto) não se
  cruzam, por exclusion constraint sobre `[início, menor entre fim e encerramento)`. O encerramento pode ser
  agendado, o que permite trocar a condição sem intervalo. Entre a condição do produto e a geral continua
  valendo a maior, como na 1.0.0.
- **Preenchimento na migração:** a 0015 preenche `coupons.updated_at` e
  `customer_price_agreements.valid_from` com `created_at` e torna as colunas obrigatórias, o que evita
  `COALESCE` no domínio, nas consultas e na constraint. Como a RLS é forçada também para o proprietário, as
  duas tabelas ficam sem `FORCE` somente dentro da transação da migration (ver `ISOLAMENTO.md`). Condições
  sobrepostas herdadas da 1.0.0 abortam a migration com mensagem clara: escolher qual manter mudaria preços
  sem decisão de quem opera, então o ajuste é manual e anterior (ver `RUNBOOKS.md`, seção 13).
- **Tarifas com autorização:** aplicar uma tarifa do catálogo pelo valor padrão faz parte de criar a reserva
  ou o orçamento. Valor diferente do padrão e tarifa avulsa exigem `fees.override`. A redução é um desconto e
  respeita o limite de desconto manual do papel sobre o valor padrão; credenciais de integração têm limite 0.
- **Continuidade em orçamentos:** na nova versão, a tarifa idêntica a uma da versão anterior já foi
  autorizada e é mantida sem nova autorização, mesmo inativa. Cada entrada anterior autoriza uma única
  entrada da nova versão: cópias repetidas são ajustes novos. Assim um atendente revisa o orçamento sem
  perder nem reverter o ajuste de um gerente. Os ajustes vão para a auditoria do documento e nunca para o
  snapshot de preços, que é imutável e é exibido ao cliente.
- **Cupons somente em reservas:** orçamentos e solicitações do portal não aceitam cupom; a conversão do
  orçamento copia o snapshot, sem cupom.
- **Interfaces:** mutações da API exigem `Idempotency-Key` e usam somente o identificador do recurso (um
  único escopo de idempotência por recurso); `PATCH` altera as chaves enviadas. Cupons e tarifas têm controle
  otimista (`lock_version`), obrigatório na web e opcional na API. Alteração sem mudança e ativação ou
  desativação no mesmo estado são operações nulas, sem auditoria, em todos os canais. Não há evento novo de
  webhook; o uso do cupom é auditado na criação da reserva.
- **Consequências:** a situação de cupons, condições e usos é sempre calculada no instante da consulta, com a
  mesma regra no domínio, nas consultas SQL e no gatilho. Testes de propriedade comparam as três com dados
  aleatórios: a situação e os usos ativos calculados na SQL com o domínio, e a decisão do gatilho de limite
  com `Redemptions.counts_toward_limit?` somado ao contador legado. A contagem de usos ativos custa uma
  consulta ao livro por cupom; o índice `(organization_id, coupon_id, redeemed_at)` atende a esse acesso.

## ADR-028 — Configurações da organização, política congelada e gestão de filiais

- **Contexto:** até a 1.1.0, `organizations.settings` (validade padrão do bloqueio temporário e política de
  cancelamento) era lida com valores padrão, mas nada a alterava, e só o contrato congelava a política, no
  momento da emissão: uma troca de política mudaria a multa de reservas e orçamentos já combinados. Também não
  havia edição, desativação nem reativação de filiais, e o fuso da organização era lido no momento de cada
  operação, mesmo em extensões, multas e cobranças de reservas antigas.
- **Configurações em `settings` com controle otimista (D1):** sem tabela nova. A coluna
  `organizations.lock_version` faz o controle otimista (`stale_organization`). Só se gravam chaves com valor
  diferente do padrão; a chave é removida quando o valor volta ao padrão e chaves desconhecidas são
  preservadas. "Padrão" é a igualdade de valor, não a ausência da chave.
- **Política congelada em dois registros imutáveis (D2, D3):** a versão do orçamento grava a política com os
  preços, e a reserva grava a política na criação. A reserva criada a partir de orçamento recebe a da versão
  (somente por composição interna; a web e a API não repassam o campo); as demais recebem a vigente na
  organização. O contrato copia a da reserva. A impressão digital da versão inclui a política: depois de uma
  troca, uma revisão sem outras mudanças gera uma versão nova com a política nova, que é o caminho para levar a
  política nova a um orçamento em aberto. Gatilhos impedem a alteração das duas colunas, inclusive pelo
  proprietário.
- **Validade do bloqueio (D4):** o mesmo intervalo do motor (5 a 1440 minutos). Bloqueios e orçamentos já
  registrados guardam a própria validade.
- **Política válida (D5):** de 1 a 6 faixas, horas inteiras de 0 a 8760 sem repetição, uma faixa de 0 h e multa
  em pontos-base que não diminui à medida que o início se aproxima; forma canônica ordenada pela antecedência
  decrescente.
- **Troca de fuso com confirmação (D6, D7):** permitida a quem tem `organization.manage`, com a caixa de
  confirmação e as contagens de registros afetados. Cada reserva tem um **fuso de referência**, o da
  precificação (`pricing.timezone`): extensões, multas por atraso, vencimentos das cobranças, emissão do
  contrato, novas versões do documento e aditivos usam esse fuso, e cada contrato tem um único fuso, igual ao
  do preço. Instantes gravados não mudam e passam a ser exibidos no fuso novo; o restante (reservas novas,
  painel, financeiro, atrasos, calendário, telas, CLI e e-mails) usa o fuso novo, e os e-mails informam o fuso.
  Formulários abertos antes da troca levam o campo oculto `fuso` e são recusados com 422: interpretar os
  horários digitados no fuso novo mudaria o instante sem aviso. Foi escolhido 422 com `ValidationError` (e não
  409) porque todos os controladores já reexibem os valores enviados nesse caso. No portal, a solicitação
  recusada volta à consulta de disponibilidade refeita no fuso atual (a consulta não grava nada), com as
  quantidades e as observações enviadas.
- **Nome e filiais (D8, D9):** o nome é editável e o `slug` não muda; contratos emitidos mantêm o nome dos
  termos. Filiais têm nome e endereço editáveis com `lock_version`; o código não muda, porque é usado em
  `--filial` e nos snapshots.
- **Leitura e alteração (D10, D11):** `organization.read` (todos os papéis) governa a página, o detalhe de
  filial, a API e a CLI; quem só lê não vê formulários nem o painel de assinatura. As configurações são
  alteradas somente por usuário: a troca de fuso exige leitura e confirmação humanas e a auditoria liga a
  alteração a uma pessoa. Por isso não há alteração pela API nem pela CLI nesta versão. As mutações de filial
  exigem apenas a permissão, como a criação.
- **Auditoria e métricas (D12):** valores anterior e novo, sem webhook novo; os conflitos novos entram em
  `domain_conflicts_total`.
- **Plano (D13):** só a reativação de filial conta em `max_branches`.
- **Mensagens (D14):** filial inexistente responde "filial não encontrada"; existente e inativa, erro no campo
  do formulário ("filial inativa: escolha uma filial ativa").
- **Regras de desativação:** impedem reservas em aberto (bloqueio só enquanto vigente), orçamentos enviados com
  a versão atual vigente, orçamentos aprovados que ainda podem ser convertidos (retirada da versão aprovada
  dentro da tolerância da conversão) e transferências pendentes com destino à filial; ativos, estoque,
  rascunhos, aprovados com retirada já passada e transferências de saída não impedem. A última filial ativa não é desativada. Operações
  sobre o que já está na filial (baixa, perda, ajuste negativo, manutenção, transferência de saída) continuam
  aceitas; criações de vínculo exigem filial ativa.
- **Concorrência:** criações de vínculo travam a filial com `FOR SHARE`; a desativação, com `FOR NO KEY UPDATE`,
  e depois a organização, que sempre existe (inclusive sem assinatura), para contar as filiais ativas. A
  reativação usa a trava da assinatura. A ordem global (filial → organização; filial → assinatura; só
  assinatura; só organização) não tem ciclo.
- **Migration 0016:** default não volátil (`app_default_cancellation_policy()`), que evita a reescrita das
  tabelas, e preenchimento direcionado somente onde a política difere do padrão, com prioridade para a política
  dos termos do contrato. `quote_versions_protect` recusa qualquer `UPDATE` de versão enviada, então é desligado
  somente durante o preenchimento, na mesma transação. Gatilhos de preenchimento atendem inserções da 1.1.0
  durante a implantação gradual e o retorno; a 1.2 sempre informa a coluna (keyword obrigatória no
  repositório, coberta por teste), e a remoção dos gatilhos fica para uma migration futura.
- **Alternativas rejeitadas:**
  - dividir a entrega em três incrementos (fuso, nome e filiais): o objetivo exigia os três, e as lacunas
    apontadas foram resolvidas aqui;
  - CNPJ editável: desde julho de 2026 existe o CNPJ alfanumérico e `Customers::Document.valid_cnpj?` só aceita
    dígitos; o campo exigiria nova regra de validação. Fica como limitação, sem `UPDATE` na coluna;
  - `CHECK NOT VALID` seguido de `VALIDATE` na mesma transação: não reduz o tempo de trava, porque o `ALTER`
    já mantém ACCESS EXCLUSIVE até o commit;
  - extrair o `stale!` das condições comerciais para uso comum: a mensagem depende do gênero do código; os
    casos novos usam um auxiliar próprio com a mesma semântica;
  - remover já o gatilho de preenchimento: ele é necessário durante a implantação gradual e no retorno;
  - índice novo para reservas em aberto por filial: `reservations_org_status_idx` atende, e o índice novo
    aumentaria o tempo da migration;
  - restringir a troca de fuso ao proprietário ou bloqueá-la com locações em andamento: as consequências estão
    tratadas e a confirmação é explícita.
- **Consequências:** uma política alterada não muda reservas, versões nem contratos existentes; a reserva, o
  orçamento e o portal mostram a política registrada. Uma troca de fuso preserva o cálculo de tudo o que já foi
  precificado. A organização ganhou uma tela própria de configurações e as filiais, um ciclo ativa ⇄ inativa
  documentado em `MAQUINAS-DE-ESTADO.md`.

## ADR-029 — Justiça entre organizações na fila de webhooks, circuito por endpoint e retenção do histórico de integrações

- **Contexto:** a reivindicação da fila (`Queue#claim`) não tinha critério por organização e o worker usava uma
  thread para webhooks: uma organização com muitos destinos lentos ou fora do ar monopolizava a fila. Não havia
  contador de falhas por endpoint, então um destino morto consumia tentativas indefinidamente. Eventos da
  outbox, entregas e webhooks recebidos nunca eram removidos. `webhook_deliveries` e `inbound_webhooks` só são
  visíveis com contexto de tenant, de modo que uma limpeza global veria zero entregas e apagaria eventos com
  entrega pendente.
- **Decisão (detalhes em [`modulos/worker-webhooks-retencao.md`](modulos/worker-webhooks-retencao.md)):**
  - limite global de execuções com lease válido por organização na fila `webhooks`
    (`WEBHOOK_MAX_PER_ORGANIZATION`, padrão 2), aplicado no SQL da reivindicação: candidatos por varredura
    recursiva das organizações (`jobs_ready_org_idx`), ordenados pelas execuções em curso;
    `pg_try_advisory_xact_lock` por fila e organização antes da recontagem e bloqueio da linha com
    revalidação. O lock nunca espera e é liberado no commit da reivindicação;
  - `WEBHOOK_CONCURRENCY` passa de 1 para 4, para que o limite deixe vagas a outros tenants;
  - circuito por endpoint: falhas consecutivas e início da sequência no endpoint, pausa automática com ≥ 20
    falhas e ≥ 1 h (`Domain::Webhooks::Circuit`), auditada como ação do sistema e sem URL. Endpoint pausado
    retém as entregas (`held_at`) sem rede e sem gastar tentativas; a reativação é feita somente pela
    interface web (`integrations.manage`, auditada) e libera as retidas em lotes de 500 por tarefa própria.
    Despacho e retenção usam `FOR KEY SHARE` no endpoint e a reativação usa `FOR UPDATE`;
  - retenção por organização, no contexto do tenant, em tarefa horária (`organization.retention`), em lotes
    de 1.000 com até 10 lotes por execução, com janelas configuráveis e mínimos verificados na configuração (7
    dias para entregas e eventos e 45 para recebidos). Todo `DELETE` repete as condições na tabela-alvo;
  - totais por desfecho em `worker_outcome_totals` (global, sem dados de tenant), expostos no `/metrics`.
- **Alternativas rejeitadas:** política de leitura entre tenants para uma limpeza global (amplia a RLS);
  limite apenas em memória por processo (não vale entre workers); contagem sem lock consultivo (passa do
  limite em READ COMMITTED); `FOR UPDATE` no endpoint durante o despacho (faria a pausa esperar o despacho);
  pausa só por número de falhas (pausaria destinos com muito tráfego numa queda curta); parâmetros do circuito
  por variável de ambiente (mais superfície de configuração sem caso de uso); reativação pela API (não há API
  de webhooks enviados); contador de reivindicações (ponto de contenção).
- **Consequências:** uma organização não ocupa mais do que o limite das threads de webhooks de todos os
  workers; destinos fora do ar param de consumir tentativas e as entregas esperam a reativação sem se perder;
  o histórico de integrações tem tamanho limitado. A migration 0017 é compatível com a 1.2.0 em execução e no
  retorno (as retidas continuam retidas até a reativação na versão nova; `RUNBOOKS.md` §16).
