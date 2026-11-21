# Status de implementação

"Testado" indica testes automatizados executados com sucesso. Comandos de verificação em
`CONTRIBUTING.md`; documentação de cada módulo em `docs/modulos/`.

## Última verificação completa

Executada na branch `feature/webhooks-por-organizacao` (limite de execuções simultâneas por organização na fila
de webhooks, circuito por endpoint com entregas retidas e reativação, retenção do histórico de integrações por
organização, métricas por desfecho e migration 0017), em 21/11/2026:

| Verificação | Resultado |
|---|---|
| `rake test:all` com `COVERAGE_CHECK=1` (unitários, repositórios, integração, Rack, CLI, concorrência) | 991 testes, 28.772 asserções, 0 falhas (15 min 23 s) |
| Cobertura de domínio + aplicação | 99,48% de linhas, 93,73% de branches (metas 90% / 80%) |
| `rake test:browser` (Ferrum, Chrome headless) | 14 testes, 0 falhas |
| `rubocop` | 319 arquivos, sem ofensas |
| Atualização de um banco da 1.2.0 para a 0017 | coberta por `test/repository/migration_0017_test.rb`; o procedimento com a 1.2.0 em execução (`RUNBOOKS.md` §16) está escrito, sem exercício em ambiente Compose |

Verificação anterior, executada para a versão 1.2.0 (configurações da organização, política congelada na reserva e na versão do
orçamento, fuso de referência da reserva, gestão de filiais e migration 0016), em 21/11/2026:

| Verificação | Resultado |
|---|---|
| `rake test:all` com `COVERAGE_CHECK=1` (unitários, repositórios, integração, Rack, CLI, concorrência) | 933 testes, 0 falhas |
| Cobertura de domínio + aplicação | 99,28% de linhas, 93,37% de branches (metas 90% / 80%) |
| `rake test:browser` (Ferrum, Chrome headless) | 14 testes, 0 falhas |
| `rubocop` (árvore da branch exportada com `git archive`) | sem ofensas |
| Atualização de um banco da 1.1.0 para a 0016 (verificação prévia, aborto por `settings` inválido, correção, backup, migration com `lock_timeout` e a 1.1.0 em execução, troca, edição pela tela, controle otimista, retorno à 1.1.0) | exercitada; registro em `RUNBOOKS.md` §14.5; também coberta por `test/repository/migration_0016_test.rb` |
| CI do PR da feature (#16) | 7 checks e análise do SonarCloud aprovados |

Verificação anterior, na branch `release/1.1.0` (cadastro de cupons, condições negociadas e tarifas
adicionais, migration 0015), em 21/11/2026:

| Verificação | Resultado |
|---|---|
| `rake test:all` com `COVERAGE_CHECK=1` (unitários, repositórios, integração, Rack, CLI, concorrência) | 819 testes, 0 falhas |
| Cobertura de domínio + aplicação | 99,25% de linhas, 93,14% de branches (metas 90% / 80%) |
| `rake test:browser` (Ferrum, Chrome headless) | 11 testes, 0 falhas |
| `rubocop` (árvore da branch, com os modos de arquivo do repositório) | sem ofensas |
| Atualização de um banco da 1.0.0 para a 0015 (verificação prévia, aborto por condições sobrepostas, ajuste, migration com a 1.0.0 em execução, troca para a 1.1.0, retorno à 1.0.0) | exercitada; registro em `RUNBOOKS.md` §13.5 |
| Backup e restauração com o esquema final (15 migrations, 71 tabelas) | exercitados; registro em `RUNBOOKS.md` §4 |
| `bin/setup` completo a partir de diretório limpo | exercitado na 1.0.0 (`RUNBOOKS.md` §1); na 1.1.0, web e worker `healthy` e parada com código 0 conferidos na atualização |

Verificação anterior, na `release/1.0.0` (20/11/2026): 624 testes, 0 falhas; 9 testes de navegador; backup,
restauração e `bin/setup` exercitados com 14 migrations; 7 checks de CI aprovados no PR #11.

## Entregas por incremento

| PR | Incremento | Situação |
|---|---|---|
| #1 | Fundação: Ruby 4.0.9, Docker, CI, dinheiro, períodos, fusos, motor de disponibilidade | Integrado e testado |
| #2 | Fatia vertical: organizações, autenticação, clientes, catálogo, disponibilidade, reservas concorrentes, interface, API | Integrado e testado |
| #3 | Worker com lease e fencing, e-mails, outbox, webhooks assinados com proteção SSRF, anexos | Integrado e testado |
| #4 | Orçamentos versionados, contratos com PDF, aditivos, cancelamento com política | Integrado e testado |
| #5 | Retirada, devolução, inspeção, avarias, manutenção, transferências, atrasos | Integrado e testado |
| #6 | Financeiro: cobranças, pagamentos, reembolsos, cauções, diário, simulador, Asaas, conciliação | Integrado e testado (Asaas sem credenciais reais) |
| #7 | Portal do cliente | Integrado e testado |
| #8 | CLI operacional e correção do detalhe de reserva na API | Integrado e testado |
| #9 | Testes de navegador, métricas, correlação de logs, demonstração de ponta a ponta | Integrado e testado |
| #10 | Documentação consolidada, backup e restauração, publicação de imagem por tag | Integrado; backup e restauração exercitados (ver `RUNBOOKS.md`) |
| #11 | Estabilização da versão 1.0.0: correções de segurança, concorrência, operação, documentação e interface | Integrado e testado; versão 1.0.0 |
| #13 | Cadastro de cupons (com livro de usos), condições negociadas por cliente e tarifas adicionais; aplicação em reservas e orçamentos; telas, API v1, CLI, seed e migration 0015 | Integrado e testado; versão 1.1.0 |
| #16 | Configurações da organização, política congelada na reserva e no orçamento, fuso de referência da reserva, gestão de filiais, API, CLI e migration 0016 | Integrado e testado; versão 1.2.0 (ver acima) |
| — | Configurações da organização (nome, fuso, validade padrão do bloqueio, política de cancelamento), política congelada na reserva e na versão do orçamento, fuso de referência da reserva, gestão de filiais, `organization.read`, API, CLI e migration 0016 (branch `feature/configuracoes-organizacao`) | Testado na branch; não integrado |
| — | API v1 ampliada: orçamentos, contratos e PDF, retirada, devolução, inspeções, alertas e `PATCH /organization/settings` por sessão, com composição transacional dos casos de uso e contrato OpenAPI conferido nos testes (branch `feature/api-v1-ampliada`, ADR-030) | Testado na branch; não integrado. `rake test:all` com `COVERAGE_CHECK=1`: 1015 testes, 0 falhas; cobertura de domínio + aplicação 99,30% de linhas e 93,64% de branches; `rake test:browser`: 14 testes, 0 falhas; `rubocop`: 320 arquivos, sem ofensas |
| — | Limite de execuções simultâneas por organização na fila de webhooks, pausa automática de endpoints com entregas retidas e reativação pela tela, retenção do histórico de integrações por organização, métricas e migration 0017 (branch `feature/webhooks-por-organizacao`) | Testado na branch; não integrado |

## Casos obrigatórios cobertos por testes

Disputa pelo último ativo; estoque quantitativo com sobreposições (cenário das dez cadeiras); kits com
componentes compartilhados; expiração concorrente com confirmação; reagendamento com conflito; extensão que
invade outra reserva; retirada e devolução duplicadas (sequencial e concorrente); devolução parcial; avaria e
indisponibilidade; isolamento entre organizações e entre clientes; revogação de acesso; cálculos e
arredondamentos (inclusive propriedades); caução e reembolso (inclusive concorrente); timeout após sucesso no
provedor; recuperação de tarefas e worker com lease vencido; downloads não autorizados; XSS e CSRF;
contrato Rack (`Rack::Lint`); roteiro de demonstração de 16 passos; condições comerciais: dois resgates do
último uso de um cupom, uso liberado por cancelamento e por expiração (inclusive bloqueio vencido ainda não
varrido), confirmação de bloqueio em andamento no vencimento contra o último uso e contra a redução do
máximo, criação com cupom
concorrente com o alocador sem impasse, condições negociadas sobrepostas simultâneas, ajuste de tarifa sem
permissão ou acima do limite do papel, repetição de tarifa mantida na nova versão do orçamento e
atualização do esquema da 0014 para a 0015 (inclusive cupons legados fora dos limites novos); texto com
caractere nulo ou UTF-8 inválido em JSON, query string, parâmetros aninhados e partes multipart respondido
como erro do cliente; configurações da organização e filiais: duas edições simultâneas com a mesma versão,
desativação de filial contra criação de reserva e de transferência com destino a ela (nas duas ordens),
desativação simultânea das duas últimas filiais (inclusive sem assinatura), duas reativações disputando a
última vaga do plano, reserva criada durante a troca da política (exatamente uma das políticas), política
congelada na reserva, na versão do orçamento e no contrato depois de uma troca, fuso de referência da reserva
em extensão, multa por atraso, vencimento da cobrança, contrato e aditivo depois de uma troca de fuso,
formulário aberto antes da troca de fuso recusado sem gravar e atualização do esquema da 0015 para a 0016
(inclusive aborto por `settings` fora do formato); API v1 ampliada: duas conversões simultâneas do mesmo
orçamento com a mesma chave e com chaves diferentes, duas entregas simultâneas da mesma retirada, casos de uso
compostos desfeitos com a transação da chave (inclusive o arquivo do PDF), aprovação vencida sem aprovar e
respostas reais conferidas contra o OpenAPI; fila de webhooks e retenção: reivindicações simultâneas
com as transações abertas ao mesmo tempo sem passar do limite por organização, endpoints lentos de uma
organização sem monopolizar as threads de webhooks, reativação disputando com a retenção de uma entrega (nas
duas ordens), limpeza do histórico contra reenvio concorrente e atualização do esquema da 0016 para a 0017.

## Limitações conhecidas

- Integração real com o sandbox Asaas não exercitada (sem credenciais); adaptador testado com cliente HTTP
  falso conforme a documentação oficial.
- Pré-autorização de cartão modelada e recusada (exigiria tokenização; PAN/CVV nunca são armazenados).
- NFS-e fora do escopo; apenas faturas comerciais.
- Armazenamento de anexos somente local; object storage privado depende de adaptador com a mesma interface.
- Recuperação em ponto no tempo (WAL) não exercitada.
- Métricas de duração de tarefas e de chamadas externas ficam no processo do worker, que não expõe HTTP.
- `/metrics` só é confiável com um processo web (`WEB_CONCURRENCY=0`): com vários processos Puma, cada
  coleta é atendida por um processo arbitrário, as séries não têm rótulo de processo e o coletor vê quedas
  de contadores como reinício. As métricas derivadas do banco (fila, desfechos de tarefas) são as mesmas em
  qualquer processo.
- Portal do cliente sem API v1.
- Aceite e encerramento de contrato, avarias, manutenção e transferências sem API v1 (interface web).
- A confirmação de e-mail (RF-05) é emitida e registrada, mas não restringe funcionalidades: conta não
  confirmada entra, convida, cria credenciais e envia orçamentos e contratos. O cadastro é limitado por IP e
  por e-mail (ADR-026); uma política de bloqueio até a confirmação fica para versão futura.
- Configurações da organização são alteradas somente por usuário com `organization.manage`, pela interface web
  ou por `PATCH /api/v1/organization/settings` com sessão; credenciais e CLI apenas consultam (ADR-030). Prévia,
  restauração dos padrões e gestão de filiais ficam na interface web. A lista de fusos oferece os fusos do
  Brasil. O CNPJ da organização, impresso nos contratos, ainda não é editável.
- Cupons não se aplicam a orçamentos nem a solicitações do portal: valem somente na criação de reserva pela
  equipe ou pela API. A reserva convertida de um orçamento copia os preços do orçamento, sem cupom.
- A API aplica tarifas adicionais na criação de reserva e nas versões de orçamento. A CLI cadastra cupons e
  condições negociadas, mas não edita cupons nem gerencia tarifas (ficam na interface web e na API).
- Os usos de cupom anteriores à migration 0015 não são reconstruídos no livro de usos: aparecem somente no
  contador legado do cupom. O retorno à versão 1.0.0 depois de usar cupons com limite ou de encerrar
  condições negociadas tem restrições (`RUNBOOKS.md`, seção 13).
- A retenção do histórico de integrações só roda para organizações ativas: o histórico das suspensas ou
  encerradas não é removido.
- Os parâmetros da pausa automática de endpoints (20 falhas consecutivas e 1 h) são fixos.
- Não há API para consultar ou reativar endpoints de webhook; a reativação é feita somente pela interface web.
- O limite de execuções simultâneas por organização vale somente para a fila `webhooks`.
- Sem medições de desempenho publicadas.
- Proteções de branch exigem os checks; aprovação de revisão não é exigida porque o repositório tem um único
  mantenedor (revisões independentes não são simuladas).
