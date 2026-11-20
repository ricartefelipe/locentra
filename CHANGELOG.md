# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versões seguem
[SemVer](https://semver.org/lang/pt-BR/).

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
  faixas, cupons, descontos por papel, condições negociadas, multa por atraso e snapshots.
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
