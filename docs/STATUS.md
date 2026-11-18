# Status de implementação

"Testado" indica testes automatizados executados com sucesso. Comandos de verificação em
`CONTRIBUTING.md`; documentação de cada módulo em `docs/modulos/`.

## Última verificação completa

Executada na integração do PR #9 (código idêntico ao de `develop` após o merge; esta branch acrescenta
apenas documentação e scripts operacionais):

| Verificação | Resultado |
|---|---|
| `rake test:all` com `COVERAGE_CHECK=1` (unitários, repositórios, integração, Rack, CLI, concorrência) | 553 testes, 0 falhas |
| Cobertura de domínio + aplicação | 99,05% de linhas, 92,01% de branches (metas 90% / 80%) |
| `rake test:browser` (Ferrum, Chrome headless) | 9 testes, 0 falhas |
| `rubocop`, actionlint | sem ofensas |
| CI do PR #9 | 7 checks aprovados (análise, segredos, unitários, PostgreSQL, navegador, reconstrução do banco, imagem) |

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
| esta branch | Documentação consolidada, backup e restauração, publicação de imagem por tag | Backup e restauração exercitados (ver `RUNBOOKS.md`) |

## Casos obrigatórios cobertos por testes

Disputa pelo último ativo; estoque quantitativo com sobreposições (cenário das dez cadeiras); kits com
componentes compartilhados; expiração concorrente com confirmação; reagendamento com conflito; extensão que
invade outra reserva; retirada e devolução duplicadas (sequencial e concorrente); devolução parcial; avaria e
indisponibilidade; isolamento entre organizações e entre clientes; revogação de acesso; cálculos e
arredondamentos (inclusive propriedades); caução e reembolso (inclusive concorrente); timeout após sucesso no
provedor; recuperação de tarefas e worker com lease vencido; downloads não autorizados; XSS e CSRF;
contrato Rack (`Rack::Lint`); roteiro de demonstração de 14 passos.

## Limitações conhecidas

- Integração real com o sandbox Asaas não exercitada (sem credenciais); adaptador testado com cliente HTTP
  falso conforme a documentação oficial.
- Pré-autorização de cartão modelada e recusada (exigiria tokenização; PAN/CVV nunca são armazenados).
- NFS-e fora do escopo; apenas faturas comerciais.
- Armazenamento de anexos somente local; object storage privado depende de adaptador com a mesma interface.
- Recuperação em ponto no tempo (WAL) não exercitada.
- Métricas de duração de tarefas e de chamadas externas ficam no processo do worker; com vários processos
  Puma o coletor precisa somar as séries.
- Sem API v1 para orçamentos, contratos, operação e portal (disponíveis pela interface e casos de uso).
- Sem medições de desempenho publicadas.
- Proteções de branch exigem os checks; aprovação de revisão não é exigida porque o repositório tem um único
  mantenedor (revisões independentes não são simuladas).
