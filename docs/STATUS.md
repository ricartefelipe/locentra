# Status de implementação

"Testado" indica testes automatizados executados com sucesso. Comandos de verificação em
`CONTRIBUTING.md`; documentação de cada módulo em `docs/modulos/`.

## Última verificação completa

Executada na branch `release/1.0.0`, depois das correções da estabilização (segurança das rotas públicas,
webhooks, fila, financeiro, backup, configuração e interface), em 20/11/2026:

| Verificação | Resultado |
|---|---|
| `rake test:all` com `COVERAGE_CHECK=1` (unitários, repositórios, integração, Rack, CLI, concorrência) | 624 testes, 0 falhas |
| Cobertura de domínio + aplicação | 99,10% de linhas, 92,10% de branches (metas 90% / 80%) |
| `rake test:browser` (Ferrum, Chrome headless) | 9 testes, 0 falhas |
| `rubocop` (árvore da branch, com os modos de arquivo do repositório), actionlint | sem ofensas |
| Backup e restauração com o esquema final (14 migrations) | exercitados; registro em `RUNBOOKS.md` |
| `bin/setup` completo a partir de diretório limpo, com healthchecks e parada graciosa | exercitado; registro em `RUNBOOKS.md` §1 |
| CI do PR da release (#11) | 7 checks aprovados |

Verificação anterior, na integração do PR #9: 553 testes, 0 falhas; 7 checks de CI aprovados.

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
| release/1.0.0 | Estabilização: correções de segurança, concorrência, operação, documentação e interface | Testado (ver acima) |
| feature/cadastro-condicoes-comerciais | Cadastro de cupons (com livro de usos), condições negociadas por cliente e tarifas adicionais; aplicação em reservas e orçamentos; telas, API v1, CLI, seed e migration 0015 | Implementado e testado na branch; entra na versão 1.1.0 |

A tabela "Última verificação completa" acima registra a versão 1.0.0 (14 migrations). A migration 0015 tem
teste automatizado de atualização a partir do esquema da 0014, mas backup, restauração e `bin/setup` ainda
não foram exercitados com ela: serão exercitados e registrados em `RUNBOOKS.md` na release 1.1.0 (o
procedimento de atualização está na seção 13).

## Casos obrigatórios cobertos por testes

Disputa pelo último ativo; estoque quantitativo com sobreposições (cenário das dez cadeiras); kits com
componentes compartilhados; expiração concorrente com confirmação; reagendamento com conflito; extensão que
invade outra reserva; retirada e devolução duplicadas (sequencial e concorrente); devolução parcial; avaria e
indisponibilidade; isolamento entre organizações e entre clientes; revogação de acesso; cálculos e
arredondamentos (inclusive propriedades); caução e reembolso (inclusive concorrente); timeout após sucesso no
provedor; recuperação de tarefas e worker com lease vencido; downloads não autorizados; XSS e CSRF;
contrato Rack (`Rack::Lint`); roteiro de demonstração de 15 passos; condições comerciais: dois resgates do
último uso de um cupom, uso liberado por cancelamento e por expiração (inclusive bloqueio vencido ainda não
varrido), confirmação de bloqueio em andamento no vencimento contra o último uso e contra a redução do
máximo, criação com cupom
concorrente com o alocador sem impasse, condições negociadas sobrepostas simultâneas, ajuste de tarifa sem
permissão ou acima do limite do papel, repetição de tarifa mantida na nova versão do orçamento e
atualização do esquema da 0014 para a 0015 (inclusive cupons legados fora dos limites novos); texto com
caractere nulo ou UTF-8 inválido em JSON, query string, parâmetros aninhados e partes multipart respondido
como erro do cliente.

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
- Sem API v1 para orçamentos, contratos, operação e portal (disponíveis pela interface e casos de uso).
- A confirmação de e-mail (RF-05) é emitida e registrada, mas não restringe funcionalidades: conta não
  confirmada entra, convida, cria credenciais e envia orçamentos e contratos. O cadastro é limitado por IP e
  por e-mail (ADR-026); uma política de bloqueio até a confirmação fica para versão futura.
- Configurações da organização (`settings`: política de cancelamento e validade padrão do bloqueio
  temporário) são lidas com valores padrão, mas não há tela nem comando para alterá-las nesta versão.
- Cupons não se aplicam a orçamentos nem a solicitações do portal: valem somente na criação de reserva pela
  equipe ou pela API. A reserva convertida de um orçamento copia os preços do orçamento, sem cupom.
- Tarifas adicionais pela API somente na criação de reserva (sem API de orçamentos). A CLI cadastra cupons e
  condições negociadas, mas não edita cupons nem gerencia tarifas (ficam na interface web e na API).
- Os usos de cupom anteriores à migration 0015 não são reconstruídos no livro de usos: aparecem somente no
  contador legado do cupom. O retorno à versão 1.0.0 depois de usar cupons com limite ou de encerrar
  condições negociadas tem restrições (`RUNBOOKS.md`, seção 13).
- Sem medições de desempenho publicadas.
- Proteções de branch exigem os checks; aprovação de revisão não é exigida porque o repositório tem um único
  mantenedor (revisões independentes não são simuladas).
