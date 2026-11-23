# Locentra

Plataforma SaaS B2B multitenant para gestão de locações e ativos, destinada a locadoras de ferramentas,
equipamentos audiovisuais, materiais para eventos e equipamentos profissionais. Acompanha todo o ciclo da
locação: consulta de disponibilidade, orçamento, reserva, contrato, retirada, devolução, inspeção,
manutenção e encerramento financeiro, sem conflitos de alocação e com rastreabilidade de cada ativo.

## Modelo comercial

Mensalidade por organização em planos configuráveis (faixas de ativos, filiais, usuários e funcionalidades),
com taxa de implantação e treinamento. Os planos Essencial, Profissional e Empresarial têm valores que são
hipóteses de produto (`db/migrations/0001`). Os limites são aplicados de fato (cadastro de ativos, filiais,
convites e funcionalidades como portal, API, webhooks e pagamentos online). A assinatura da organização na
plataforma é separada dos contratos de locação entre a organização e seus clientes.

## Funcionalidades

- **Organizações e acesso:** filiais, usuários, convites, papéis (proprietário, administrador, gerente,
  atendente, operador de estoque, financeiro, auditor), alternância de organização, revogação imediata,
  credenciais de integração com escopos. [Permissões](docs/PERMISSOES.md)
- **Confirmação de e-mail:** sem confirmar o e-mail, a conta opera normalmente dentro da organização, mas não
  convida pessoas, não cria credenciais, não cadastra nem reativa webhooks, não configura pagamentos online e não
  envia orçamentos, contratos nem convites do portal; depois de 7 dias sem confirmação, fica somente leitura. Aviso
  com reenvio no topo das páginas da equipe. [Módulo](docs/modulos/confirmacao-email.md)
- **Configurações da organização e filiais:** nome, fuso horário (com as consequências da troca e confirmação),
  validade padrão do bloqueio temporário e política de cancelamento editáveis pela interface web, com
  pré-visualização e histórico; a política fica congelada na reserva, na versão do orçamento e no contrato.
  Filiais com edição, desativação (recusada com compromissos em aberto) e reativação dentro do limite do plano.
  Consulta pela API (`GET /api/v1/organization`) e pela CLI (`organization show`); alteração também pela API
  com sessão de usuário (`PATCH /api/v1/organization/settings`).
  [Módulo](docs/modulos/configuracoes-organizacao.md)
- **Clientes:** pessoa física e jurídica (CPF/CNPJ validados), contatos, pessoas autorizadas a retirar,
  endereços, anexos.
- **Catálogo e ativos:** produtos com ativos individuais, estoque quantitativo ou kits; histórico,
  condição, custo, situação operacional, bloqueios, manutenção e transferência entre filiais.
- **Disponibilidade e reservas:** ocupação máxima simultânea por período, bloqueios temporários com expiração,
  confirmação com revalidação atômica, reagendamento, extensão, reservas com vários itens (tudo ou nada).
  [Motor de disponibilidade](docs/DISPONIBILIDADE.md)
- **Precificação:** hora, diária de 24 h, dia de calendário, semana, mínimo, arredondamento, tolerância,
  faixas por quantidade, descontos por papel, multa por atraso, snapshots. Cadastro de cupons (com usos por
  reserva), condições negociadas por cliente e tarifas adicionais, pela interface web, pela API e pela CLI,
  aplicados em reservas e orçamentos. [Política](docs/PRECIFICACAO.md) ·
  [Condições comerciais](docs/modulos/condicoes-comerciais.md)
- **Orçamentos e contratos:** versões, aprovação da versão aceita, conversão idempotente, contrato em PDF com
  versão e SHA-256, aceite eletrônico simples, aditivos e cancelamento com política explícita.
- **Operação:** separação, conferência, retirada, devolução total ou parcial, inspeção, avarias e faltas com
  evidência e autorização, manutenção, transferências, alertas de atraso e reservas afetadas.
- **Financeiro:** cobranças, pagamentos parciais, reembolsos, cauções separadas da receita, diário contábil
  balanceado, simulador e adaptador Asaas (sandbox), webhooks recebidos deduplicados, conciliação.
  [Caução](docs/CAUCAO.md)
- **API v1 com OpenAPI:** clientes, catálogo, disponibilidade, reservas, financeiro, condições comerciais,
  organização, orçamentos (criação, versões, envio, aprovação, rejeição e conversão), contratos (emissão, PDF,
  aditivo e cancelamento), retirada, devolução, inspeções e alertas, com `Idempotency-Key` em toda mutação,
  escopos por permissão e respostas conferidas contra o contrato OpenAPI nos testes.
  [Módulo](docs/modulos/api-v1.md) · [OpenAPI](docs/openapi.yaml)
- **Webhooks enviados e worker:** entregas assinadas com proteção SSRF, limite de execuções simultâneas por
  organização na fila de webhooks, pausa automática de endpoints com falhas consecutivas (entregas retidas e
  reativação pela tela) e retenção do histórico de integrações por organização.
  [Módulo](docs/modulos/worker-webhooks-retencao.md)
- **Portal do cliente, CLI operacional, e-mails e auditoria.**

## Arquitetura

Monólito modular em Ruby 4.0.9 puro (sem framework de aplicação, sem ORM), com domínio independente de
infraestrutura, SQL explícito sobre PostgreSQL 18, Row-Level Security forçada e aplicação Rack servida por
Puma. Detalhes: [Arquitetura (C4)](docs/ARQUITETURA.md), [Modelo de dados](docs/MODELO-DE-DADOS.md),
[Máquinas de estado](docs/MAQUINAS-DE-ESTADO.md), [Isolamento](docs/ISOLAMENTO.md),
[Decisões](docs/DECISOES.md).

### Dependências

| Gem | Uso |
|---|---|
| rack, puma | interface HTTP e servidor |
| pg, connection_pool | driver PostgreSQL e pool |
| bcrypt | hashing de senhas (limite de 72 bytes respeitado, sem truncamento) |
| tzinfo, tzinfo-data | fusos IANA |
| prawn | PDF de contratos |
| mail, net-smtp | composição e envio de e-mail |
| json, bigdecimal, csv, logger | bibliotecas que deixaram de ser default gems no Ruby 4.0 (json fixado em versão corrigida) |
| minitest, rack-test, simplecov, ferrum | testes, cobertura e navegador |
| rubocop (+ minitest, performance), bundler-audit | análise estática e auditoria de dependências |

## Execução

Pré-requisito: Docker com Compose v2. Ruby local é opcional (`.ruby-version`).

```bash
bin/setup
```

Constrói as imagens, sobe PostgreSQL e Mailpit, aplica migrations (credencial do proprietário), carrega o
seed (duas organizações) e inicia web e worker.

- Aplicação: http://localhost:9292 — usuários `ana@alfa.demo` (Alfa Audiovisual) e `paulo@beta.demo`
  (Beta Eventos), senha `locentra-local-demo`. Outros membros no seed (`lib/locentra/seed.rb`).
- Mailpit: http://localhost:8025
- Roteiro de demonstração: [`docs/DEMONSTRACAO.md`](docs/DEMONSTRACAO.md)

Comandos úteis:

```bash
docker compose --profile ops run --rm migrate                                      # migrations
docker compose --profile ops run --rm migrate ruby bin/locentra-admin db:status    # credencial do proprietário
docker compose run --rm --no-deps web ruby bin/locentra-admin db:seed  # idempotente; somente demonstração (recusado em produção)
read -rs LOCENTRA_TOKEN && export LOCENTRA_TOKEN                     # o token não fica no histórico nem no ps
docker compose run --rm --no-deps -e LOCENTRA_TOKEN web ruby bin/locentra reservations list
docker compose run --rm --no-deps -e LOCENTRA_TOKEN web ruby bin/locentra organization show  # fuso, bloqueio, política e filiais
docker compose logs -f web worker
```

## Configuração

Variáveis em [`.env.example`](.env.example): URLs separadas para aplicação (`DATABASE_URL`), worker
(`WORKER_DATABASE_URL`), migrations (`MIGRATION_DATABASE_URL`) e backup (`BACKUP_DATABASE_URL`);
`APP_SECRET_KEY_BASE`, `APP_ENCRYPTION_KEY`, `APP_BASE_URL` (HTTPS obrigatório em produção), dimensionamento
(`PUMA_THREADS`, `WEB_CONCURRENCY`, `DB_POOL_SIZE`, `DB_POOL_TIMEOUT`, `WORKER_CONCURRENCY`,
`WEBHOOK_CONCURRENCY`), limite de execuções simultâneas por organização na fila de webhooks
(`WEBHOOK_MAX_PER_ORGANIZATION`), janelas de retenção do histórico de integrações em dias
(`OUTBOX_RETENTION_DAYS`, `WEBHOOK_DELIVERY_RETENTION_DAYS`, `INBOUND_WEBHOOK_RETENTION_DAYS`, com mínimos
verificados na partida; ver [`docs/modulos/worker-webhooks-retencao.md`](docs/modulos/worker-webhooks-retencao.md)),
proxies confiáveis (`TRUSTED_PROXIES`), limite da API (`API_RATE_LIMIT`), SMTP
(`SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_AUTH`, `MAIL_FROM`; TLS
obrigatório em produção), rotação da chave de cifragem (`APP_ENCRYPTION_KEY_PREVIOUS`),
provedores de pagamento habilitados (`PAYMENT_PROVIDERS`; a conta e a chave de cada organização são
cadastradas em Financeiro → Provedor), armazenamento (`STORAGE_ROOT`, `MAX_UPLOAD_BYTES`) e `METRICS_TOKEN`
(obrigatório para expor `/metrics` em produção). O Compose repassa essas variáveis do `.env` aos contêineres.

## Testes e qualidade

```bash
docker compose --profile dev run --rm dev bundle exec rake test:unit   # sem banco, rede ou servidor
docker compose --profile dev run --rm dev bundle exec rake test:all    # unitários, repositórios, integração, Rack, CLI, concorrência
docker compose --profile dev run --rm dev bundle exec rake test:browser
docker compose --profile dev run --rm dev bundle exec rubocop
docker compose --profile dev run --rm dev bundle exec rake audit
```

As suítes com banco usam PostgreSQL real (nunca SQLite) com os papéis da aplicação, sem superuser nem
`BYPASSRLS`. A semente do Minitest é aleatória e reproduzível (`SEED=...`), inclusive nos testes de
propriedades. A CI executa RuboCop, Bundler Audit, actionlint, Gitleaks, todas as suítes com metas de
cobertura (domínio + aplicação ≥ 90% de linhas e ≥ 80% de branches), testes de navegador, reconstrução do
banco com seed, build da imagem, Trivy e verificação de inicialização da imagem.

## Operação

[Runbooks](docs/RUNBOOKS.md): migrations, backup e restauração (exercitados), falhas na fila, provedor de
pagamento indisponível, revogação de credenciais, rotação de segredos e dimensionamento de conexões.

## Limitações

Consulte [`docs/STATUS.md`](docs/STATUS.md). Em resumo: integração real com o sandbox Asaas não exercitada
(sem credenciais); pré-autorização de cartão não suportada; NFS-e fora do escopo; armazenamento de anexos
somente local; sem medições de desempenho publicadas.

## Contribuição

GitFlow, Conventional Commits e SemVer: veja [`CONTRIBUTING.md`](CONTRIBUTING.md).
