# Módulo de configurações da organização e gestão de filiais

Requisitos atendidos: RF-01 (organizações e filiais), com RF-37 (interface web), RF-40 (CLI), RF-41
(auditoria) e RF-42 (limite de filiais do plano). As decisões estão na ADR-028 de
[`../DECISOES.md`](../DECISOES.md); a precificação no fuso de referência da reserva, em
[`../PRECIFICACAO.md`](../PRECIFICACAO.md).

| Camada | Arquivos |
|---|---|
| Migration | `db/migrations/0016_configuracoes_organizacao.sql` |
| Domínio | `lib/locentra/domain/organizations.rb` (`Text`, `Organization`, `Branch`), `domain/organization_settings.rb` (`Settings`, `CancellationPolicy`), `domain/shared/time_zone.rb` (`TimeZone.snapshot_or`), `domain/quotes.rb` (política na versão e na impressão digital), `domain/contracts.rb` (`Contract#time_zone_identifier`, `Cancellation.describe` delegando à política), `domain/identity.rb` (`organization.read`) |
| Aplicação | `lib/locentra/application/organization_settings.rb` (`BranchGuard`, `GetSettings`, `PreviewSettings`, `UpdateSettings`, `GetBranch`, `UpdateBranch`, `SetBranchActive`), `application/organizations.rb` (`GetOrganization` com permissão opcional, `CreateBranch`), `reservations.rb`, `quotes.rb`, `contracts.rb`, `returns.rb`, `finance/receivables.rb`, `catalog.rb`, `transfers.rb` e `portal.rb` (política congelada, fuso de referência e filial ativa) |
| Persistência | `lib/locentra/infrastructure/persistence/organizations.rb` (trava, gravação com versão esperada, filiais), `organization_queries.rb` (contagens, vínculos e impacto da troca de fuso), `reservations.rb` (`cancellation_policy`, `reference_timezone`), `quotes.rb` (política da versão), `catalog.rb` (`branch_exists?` sem filtro de situação) |
| Interface web | `interfaces/http/web/organization_controller.rb`, `routes.rb` (`draw_organization`), `controller.rb` (`local_time` com o campo `fuso`), `views.rb` (`branch_options`, `time_zone_field`, `utc_offset_label`, `count_text`), `labels.rb`; `views/organization/show.html.erb`, `settings.html.erb`, `policy_preview.html.erb`, `branch.html.erb`, `views/shared/cancellation_policy.html.erb`, `views/shared/errors.html.erb` |
| E-mails | `interfaces/worker/handlers.rb` (`time_zone` nas variáveis) e os modelos de `views/mailer/` com horários |
| API | `interfaces/http/api/v1.rb` (`organization`, política no detalhe da reserva), `interfaces/organization_serializers.rb`, `docs/openapi.yaml` |
| CLI | `interfaces/cli/organization_commands.rb`, `commands.rb`, `invocation.rb` |
| Composição | `lib/locentra/wiring/organizations.rb` (chamado por `System#build_use_cases`) |

## Modelo de dados

| Tabela | Colunas novas | Proteções |
|---|---|---|
| `organizations` | `lock_version` (controle otimista); `settings` guarda `hold_minutes` e `cancellation_policy` somente quando diferentes do padrão | `CHECK organizations_settings_object`; `UPDATE` de `locentra_app` somente em `name`, `timezone`, `settings`, `lock_version` e `updated_at` (o `slug`, a situação e o documento não mudam pela aplicação); worker sem `UPDATE` |
| `branches` | `deactivated_at`, `lock_version` | `CHECK branches_active_coherent` (`active = (deactivated_at IS NULL)`); `UPDATE` de `locentra_app` somente em `name`, `address`, `active`, `deactivated_at`, `lock_version` e `updated_at` (o código não muda); `DELETE` revogado; worker sem `UPDATE` (não trava filiais) |
| `reservations` | `cancellation_policy` (`jsonb NOT NULL`) | `CHECK reservations_cancellation_policy_shape`; gatilhos `reservations_cancellation_policy_fill` (inserção sem a coluna) e `reservations_cancellation_policy_immutable` |
| `quote_versions` | `cancellation_policy` (`jsonb NOT NULL`) | `CHECK quote_versions_cancellation_policy_shape`; gatilhos `quote_versions_cancellation_policy_fill` e `quote_versions_cancellation_policy_immutable`; a aplicação continua com `UPDATE` somente em `sent_at` |

Funções: `app_default_cancellation_policy()` (a política padrão, igual a `CancellationPolicy::DEFAULT`) e
`app_cancellation_policy_shape_ok(jsonb)` (formato mínimo; a validação de negócio completa fica no domínio).
A migration verifica o formato de `settings` antes de alterar qualquer coisa, remove valores JSON `null`,
preenche a política das reservas com a do contrato (quando houver) ou com a da organização, e a das versões
de orçamento com a da organização, desligando `quote_versions_protect` somente durante esse preenchimento
(ver [`../RUNBOOKS.md`](../RUNBOOKS.md), seção 14, e [`../ISOLAMENTO.md`](../ISOLAMENTO.md)).

## Regras

### Configurações

- **Nome:** de 2 a 120 caracteres. O identificador (`slug`) não muda. Contratos emitidos mantêm o nome dos
  termos; e-mails, telas e PDFs novos usam o nome novo.
- **Validade padrão do bloqueio temporário:** de 5 a 1440 minutos (o mesmo intervalo do motor de reservas,
  com erro em `validade_bloqueio`). Vale para formulários de reserva e de orçamento e para a API quando a
  validade não é informada. Bloqueios (`hold_expires_at`) e orçamentos (`quotes.hold_minutes`) já registrados
  não mudam. O portal não cria bloqueios.
- **Política de cancelamento:** de 1 a 6 faixas, antecedência em horas inteiras de 0 a 8760 sem repetição,
  exatamente uma faixa de 0 h, multa em pontos-base de 0 a 10000 que não diminui à medida que a antecedência
  cai. A forma canônica é ordenada pela antecedência decrescente. Todas as mensagens ficam em
  `faixas_cancelamento`; as de uma faixa começam com "faixa N: ", em que N é a posição na lista sem as linhas
  vazias (a mesma das linhas reexibidas), e a tela marca a linha com `aria-invalid`.
- **Padrão por valor:** só se gravam chaves diferentes do padrão; a chave é removida quando o valor volta ao
  padrão, e chaves desconhecidas de `settings` são preservadas. "(padrão)" é exibido pela igualdade de valor.
- **Operação nula:** sem diferença nos valores efetivos, nada é gravado nem auditado ("Nenhuma alteração a
  salvar.").
- **Somente usuários:** credenciais, mesmo com o escopo `organization.manage`, recebem "as configurações da
  organização são alteradas somente por usuários".

### Fuso horário

- A lista oferece os 16 fusos IANA do Brasil, cada um com o deslocamento atual em relação ao UTC. O fuso atual
  é sempre aceito, mesmo fora da lista, e aparece como "(atual)". A troca exige a caixa "Confirmo a troca do
  fuso horário e as consequências descritas acima." (`confirmar_fuso`); a pré-visualização não exige.
- **Fuso de referência da reserva:** o fuso com que a reserva foi precificada (`pricing.timezone`); o atual
  da organização só quando o resumo não tem o campo.
- Consequências da troca:
  - instantes gravados (períodos, vigências de cupons e condições, vencimentos de bloqueios e de orçamentos)
    não mudam; a exibição e a digitação passam a usar o fuso novo. Uma vigência digitada como 23:59 em
    Brasília aparece como 22:59 em Manaus, e a tela orienta a revisão;
  - preços registrados (reservas, versões e contratos) não são recalculados;
  - extensões, multas por atraso e vencimentos (`due_on`) das cobranças de uma reserva usam o fuso de
    referência da reserva;
  - o contrato é emitido no fuso de referência da reserva (período local, `issued_at_local` e
    `organization.timezone` dos termos); novas versões do documento e aditivos usam o fuso dos termos. Cada
    contrato tem um único fuso, igual ao do preço;
  - reservas e versões novas, painel do dia, "hoje" do financeiro, detecção de atraso, calendário, telas, CLI
    (inclusive datas sem hora em `--de`/`--ate`) e e-mails enviados depois da troca usam o fuso novo. Os
    e-mails informam o fuso ("Horários no fuso horário America/Manaus.");
  - datas de vencimento já gravadas não mudam;
  - formulários abertos antes da troca: todo formulário POST com data e hora local leva o campo oculto `fuso`;
    se ele diferir do fuso atual, o envio é recusado com 422 no campo `fuso` e nada é gravado; os valores
    enviados voltam ao formulário, que passa a levar o fuso atual. No portal, a consulta de disponibilidade é
    refeita no fuso atual para reexibir a tabela com as quantidades e as observações. A API não é afetada
    (ISO 8601 com deslocamento).
- A tela mostra, antes da confirmação, quantas reservas e quantos contratos estão em aberto e quantos cupons e
  condições negociadas têm instante de vigência futuro.

### Política congelada (snapshots)

- A versão do orçamento grava a política vigente com os preços (`VersionBuilder`); a impressão digital da
  versão inclui a política. Depois de uma troca de política, uma revisão sem outras mudanças gera uma versão
  nova com a política nova: é assim que a política nova chega a um orçamento em aberto.
- A reserva grava a política na criação. A reserva criada a partir de orçamento (bloqueio no envio, conversão
  com bloqueio vencido ou conversão sem bloqueio) recebe a política da versão; as demais (equipe, API,
  portal) recebem a política vigente da organização. A solicitação do portal congela no pedido, não na
  confirmação.
- O contrato copia a política da reserva. A prévia de cancelamento do contrato usa a política dos termos.
- A reserva, o orçamento (equipe e portal) e o detalhe da reserva na API exibem a política registrada.

### Filiais

- Nome (2 a 120 caracteres) e endereço (até 300 caracteres, recusado acima) editáveis com `lock_version`
  (`stale_branch`). O código não muda: é usado em `--filial` e nos snapshots.
- **Filial inexistente:** "filial não encontrada". **Filial inativa:** erro no campo do formulário (`filial` ou
  `destino`), "filial inativa: escolha uma filial ativa".
- Exigem filial ativa (com `FOR SHARE` na filial): criação de reserva (equipe, API e portal), criação, revisão
  e envio de orçamento (com ou sem bloqueio), transferência com destino à filial, cadastro de ativo e entrada
  ou ajuste positivo de estoque. A consulta de disponibilidade do portal exige filial ativa sem trava.
- Aceitos em filial inativa: baixa, perda e ajuste negativo de estoque, ordens de manutenção, inspeções e
  transferências a partir dela.
- **Desativação** (`Branch::BLOCKING_RESERVATIONS` e regras em
  [`../MAQUINAS-DE-ESTADO.md`](../MAQUINAS-DE-ESTADO.md)): recusada para a última filial ativa
  (`last_active_branch`, "A organização precisa de ao menos uma filial ativa.") e para a filial com reservas
  em aberto (solicitadas, confirmadas, em andamento e bloqueios vigentes), orçamentos enviados com a versão
  atual vigente, orçamentos aprovados ainda conversíveis ou transferências pendentes com destino a ela
  (`branch_in_use`, com até cinco códigos por tipo e a orientação de cada um). Ativos, estoque, rascunhos,
  bloqueios e orçamentos vencidos, transferências de saída e orçamentos aprovados cuja retirada já passou
  (a conversão recusa início no passado e nenhuma transição desfaz o vínculo) não impedem.
- **Reativação:** respeita `max_branches` do plano (somente a reativação conta; as configurações não dependem
  do plano).
- Os formulários de criação listam somente as filiais ativas; estoque (entrada, baixa e perda), origem de
  transferência, manutenção, listagens e filtros listam todas, com " (inativa)". O calendário usa como padrão
  a primeira filial ativa. Na nova versão de um orçamento cuja filial foi desativada, a filial atual continua
  selecionada, com " (inativa)" e um aviso no campo; o envio sem trocar de filial é recusado com "filial
  inativa", para que a troca nunca aconteça sem o usuário perceber.

## Permissões

`organization.read` (todos os papéis) governa a página `/organizacao`, o detalhe de filial,
`GET /api/v1/organization` e `organization show`. `organization.manage` (proprietário e administrador) altera
as configurações (somente usuário) e cria, edita, desativa e reativa filiais. Quem só lê não vê os
formulários nem o painel de assinatura; o histórico da filial aparece com `organization.manage` ou
`audit.read`. Matriz completa em [`../PERMISSOES.md`](../PERMISSOES.md).

## Auditoria

| Ação | Recurso | Detalhes |
|---|---|---|
| `organization.settings_updated` | `organization` | `changes` (campo → valores efetivos anterior e novo), `lock_version` novo e `timezone_confirmed` quando o fuso muda |
| `branch.created` | `branch` | `code` |
| `branch.updated` | `branch` | `code`, `changes` |
| `branch.deactivated`, `branch.reactivated` | `branch` | `code` |

Prévia, restauração dos valores padrão, salvamento sem mudança e operações recusadas não são auditados. Os
conflitos `stale_organization`, `stale_branch`, `last_active_branch` e `branch_in_use` entram em
`domain_conflicts_total`. Não há evento novo de webhook.

## Interface web

| Rota | Uso |
|---|---|
| `GET /organizacao` | Configurações (com "(padrão)"), assinatura (somente com `organization.manage`), filiais com situação e detalhes, formulário de nova filial |
| `GET`/`POST /organizacao/configuracoes` | Tela de configurações; `acao` = `salvar`, `previsualizar` ou `restaurar_padrao` |
| `POST /organizacao/filiais` | Criação de filial (falha preserva os valores; código duplicado no campo `codigo`) |
| `GET`/`POST /organizacao/filiais/:id` | Detalhe com vínculos, edição e histórico |
| `POST /organizacao/filiais/:id/desativar`, `/reativar` | Desativação (com diálogo de confirmação) e reativação |

- A pré-visualização lista as faixas, mostra a tabela "Exemplo sobre um contrato de R$ 1.000,00", a validade
  e, na troca de fuso, "Agora: … em America/Sao_Paulo → … em America/Manaus" com o aviso para marcar a
  confirmação. Nada é gravado.
- "Restaurar valores padrão" preenche a validade de 30 minutos e as faixas padrão, mantendo os demais
  campos e a versão enviados.
- Em todos os reenvios (prévia, restauração e 422), os campos e a versão vêm do envio; o 409
  (`stale_organization`) mostra os valores atuais. As faixas usam o módulo de linhas
  (`public/js/modules/line-items.js`), sem script inline. As linhas vindas do servidor são anunciadas como
  "Faixa N" e a linha vazia, como "Nova faixa"; esta é a linha modelo (`data-line-template`), de modo que as
  faixas adicionadas pelo botão nascem como "Nova faixa", sem o `aria-invalid` nem a mensagem de erro de
  outra linha. A mensagem de erro de uma faixa fica dentro da própria linha e sai com ela.

## API v1

`GET /api/v1/organization` (escopo `organization.read`; tenant do token) devolve nome, identificador, fuso e
rótulo, situação, versão, `settings` (validade e limites, política canônica, textos das faixas e os
indicadores `*_default` por valor) e as filiais com `active` e `deactivated_at`. O detalhe da reserva inclui
`cancellation_policy`.

`PATCH /api/v1/organization/settings` altera as configurações somente por sessão de usuário com
`organization.manage` (cookie de sessão e `X-CSRF-Token`, o campo `_csrf` das páginas); credenciais recebem 403,
mesmo com o escopo `organization.manage` (ADR-029). Regras:

- PATCH parcial: chave presente altera o campo (`name`, `time_zone`, `hold_minutes`, `cancellation_policy`) e
  chave ausente mantém o valor atual (sem `cancellation_policy`, a política gravada fica como está, sem ser
  revalidada pelas regras atuais); `lock_version` é obrigatório e divergente responde 409
  `stale_organization`;
- a troca de fuso exige `confirm_time_zone_change: true` (422 em `confirmar_fuso`, a mensagem da tela);
- a política usa o formato de `GET /organization` (`{"tiers": [{"min_hours_before": 48, "fee_bps": 1000}]}`),
  com as regras e as mensagens da tela em `faixas_cancelamento`; textos e números com casas decimais são
  recusados;
- chaves desconhecidas ou não editáveis (`slug`, `status`, `settings`, `branches`...) respondem 422 no próprio
  nome;
- sem mudança efetiva, 200 com `changed: false` e sem auditoria; com mudança, a auditoria
  `organization.settings_updated` traz `via: api`;
- exige `Idempotency-Key`; a resposta é `{"organization": <objeto de GET /organization>, "changed": bool}`.

Prévia, restauração dos valores padrão e gestão de filiais continuam somente na interface web. Detalhes em
[`api-v1.md`](api-v1.md).

## CLI

`organization show` (escopo `organization.read`; saída 77 sem o escopo) mostra fuso com rótulo, validade
padrão, política com "(padrão)" e a tabela de filiais com a situação. `--json` devolve exatamente o objeto da
API (`OrganizationSerializers.organization`). `whoami` e a resolução de `--filial` não exigem o escopo.

## Concorrência e ordem de travas

- **Configurações:** `FOR NO KEY UPDATE` na organização (não conflita com as chaves estrangeiras das
  inserções do tenant) e `UPDATE ... AND lock_version = <esperada>`. Duas abas com a mesma versão: uma grava e
  a outra recebe 409, sem gravação nem auditoria. Sem versão (uso interno), o "de" da auditoria é lido sob a
  trava.
- **Desativação contra criação:** a criação trava a filial com `FOR SHARE`; a desativação, com
  `FOR NO KEY UPDATE`. Se a criação vem primeiro, a desativação espera e encontra o vínculo; se a desativação
  vem primeiro, a criação espera, relê a filial inativa e é recusada.
- **Última filial:** a desativação trava a organização (que sempre existe, inclusive sem assinatura) antes de
  contar as filiais ativas.
- **Reativação no limite:** serializada pela trava da assinatura (`PlanLimits`).
- **Reserva durante a troca de política:** a organização é lida uma vez por caso de uso; a reserva grava a
  política antiga ou a nova, nunca uma mistura, e o contrato copia a da reserva.
- **Ordem global:** filial → organização (desativação); filial → assinatura (reativação, ativos e estoque);
  só assinatura (criação de filial); só organização (configurações). Não há ciclo
  ([`../ISOLAMENTO.md`](../ISOLAMENTO.md)).

## Testes

| Arquivo | Cobertura |
|---|---|
| `test/unit/domain/organization_settings_test.rb` | Política (regras, mensagens reunidas e ordem, formulário com linhas vazias, meia linha, decimais, recusa antecipada acima de 6), descrições, faixas e exemplos, revisão das configurações (padrão por valor, chaves desconhecidas, confirmação do fuso, limites da validade, `changes`), filiais (revisão, desativação, reativação, endereço), mensagens de bloqueio da desativação, `TimeZone.snapshot_or` e impressão digital da versão |
| `test/unit/domain/cancellation_policy_property_test.rb` | Propriedades: invariantes, aceitação igual a um verificador de referência, idempotência, invariância a permutações, multa e monotonicidade |
| `test/unit/application/organization_settings_test.rb` | Casos de uso com repositórios falsos: credencial recusada, versão desatualizada e 0 linhas sem auditoria, operação nula, prévia sem gravação, desativação e reativação, `BranchGuard` e histórico condicionado à permissão |
| `test/repository/organization_settings_repository_test.rb` | Grants por coluna, worker sem trava, imutabilidade, preenchimento no formato da 1.1.0, CHECKs, keyword obrigatória, gravação com versão esperada e as consultas restritas ao tenant |
| `test/repository/migration_0016_test.rb`, `migration_0015_test.rb` | Atualização a partir da 0015 com dados no formato da 1.1.0 e aborto com diagnóstico; independência entre a 0015 e a 0016 |
| `test/integration/organization_settings_test.rb` | Papéis, credenciais e isolamento; política congelada na reserva, na versão, no portal e no contrato; validade padrão; fuso de referência em extensão, multa, cobrança, contrato e aditivo |
| `test/integration/organization_branches_test.rb` | Edição sem efeito nos contratos, desativação recusada e aceita, operações em filial inativa, "filial não encontrada" e limite do plano |
| `test/integration/demo_organization_settings_test.rb` | Passo 16 da demonstração pela interface web |
| `test/concurrency/organization_settings_race_test.rb` | Edições simultâneas, desativação contra reserva e transferência nas duas ordens, últimas duas filiais sem assinatura, reativações no limite e reserva durante a troca de política |
| `test/http/organization_settings_pages_test.rb`, `organization_branches_pages_test.rb` | Telas com `Rack::Lint`: acessibilidade, salvamento, 422 com a linha marcada, prévia, restauração, 409 entre abas, confirmação do fuso, CSRF, histórico, formulários abertos durante a troca, filiais, permissões e isolamento |
| `test/http/organization_api_test.rb` | Formato completo, escopo, tenant do token e política no detalhe da reserva |
| `test/http/organization_settings_api_test.rb` | PATCH por sessão: alteração parcial com auditoria `via: api`, operação nula, política em pontos-base com as mensagens da tela, confirmação do fuso, versão obrigatória e desatualizada, chaves desconhecidas, CSRF, idempotência, gerente e credenciais recusados e isolamento |
| `test/unit/domain/organization_settings_test.rb` (faixas em pontos-base) | `from_tiers` (formato, regras e equivalência com o formulário), `revise` com `cancellation_tiers`, precedência das linhas do formulário e `revision_attrs` |
| `test/cli/organization_test.rb` | Saída humana e JSON igual ao serializador, escopo e ajuda |
| `test/browser/organization_settings_test.rb` | Nova faixa pelo módulo de linhas, prévia, salvamento, troca de fuso com foco no resumo de erros, edição e desativação de filial com o diálogo de confirmação |

## Limitações

- As configurações são alteradas somente por usuário, pela interface web ou pela API v1 com sessão
  (`PATCH /api/v1/organization/settings`); credenciais e CLI apenas consultam (ADR-029).
- Prévia, restauração dos valores padrão e gestão de filiais não estão na API.
- A lista de fusos oferece somente os fusos do Brasil (o atual é sempre aceito).
- O CNPJ da organização (`legal_document`), impresso nos contratos, ainda não é editável; a coluna não recebe
  `UPDATE` da aplicação.
- O gatilho de preenchimento da política continua ativo nesta versão, por causa da implantação gradual e do
  retorno à 1.1.0; a remoção está planejada para uma migration futura.
