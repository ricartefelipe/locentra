# Requisitos do Locentra

Plataforma SaaS B2B multitenant para gestão de locações e ativos: da consulta de disponibilidade ao
encerramento financeiro, sem conflitos de alocação e com rastreabilidade de cada ativo.

Os identificadores (`RF-xx`, `RNF-xx`) são usados nos documentos de módulo (`docs/modulos/`), que
relacionam cada requisito à implementação e aos testes de evidência; `docs/STATUS.md` resume a situação
geral e as limitações (por exemplo, o RF-29 atendido parcialmente).

## 1. Produto

**Público inicial:** locadoras de ferramentas, de equipamentos audiovisuais, de materiais para eventos
e de equipamentos profissionais.

**Modelo comercial (hipóteses de produto):** mensalidade por organização, com faixas por quantidade de
ativos, quantidade de filiais, usuários e funcionalidades contratadas; taxa de implantação e
treinamento. Os valores dos planos são configuráveis e servem como hipótese inicial de preço.

A assinatura da organização no Locentra (relação plataforma ↔ empresa) é um contexto separado dos
contratos de locação da empresa com seus clientes.

## 2. Requisitos funcionais

### Organizações, identidade e acesso
- **RF-01** Organizações (tenants), filiais, usuários, convites, vínculos usuário–organização.
- **RF-02** Alternância de organização ativa na sessão.
- **RF-03** Papéis: proprietário, administrador, gerente, atendente, operador de estoque, financeiro, auditor.
- **RF-04** Permissões por papel e por recurso; revogação de acesso com efeito imediato.
- **RF-05** Autenticação por senha, confirmação de e-mail, recuperação de senha com token de uso único.

### Clientes
- **RF-06** Clientes pessoa física (CPF) e jurídica (CNPJ), contatos, endereços e pessoas autorizadas a retirar.

### Catálogo e ativos
- **RF-07** Produtos com modalidade de rastreamento: ativo individual (número de série/patrimônio),
  estoque quantitativo (unidades intercambiáveis) ou kit (composição de produtos e quantidades).
- **RF-08** Ativos com identificação, filial, condição, custo de aquisição, situação operacional e histórico.
- **RF-09** Desativação, perda, manutenção e transferência preservando histórico.
- **RF-10** Kits consomem a disponibilidade dos componentes, inclusive quando oferecidos separadamente,
  sem alocar o mesmo componente duas vezes.

### Disponibilidade e reservas
- **RF-11** Consulta de disponibilidade por período e filial, com calendário.
- **RF-12** Reserva temporária com expiração; confirmação; cancelamento; reagendamento; extensão.
- **RF-13** Reservas com múltiplos itens, alocação individual e quantitativa, tudo ou nada.
- **RF-14** Bloqueios de preparação (antes/depois) e de manutenção.
- **RF-15** Confirmação revalida disponibilidade atomicamente; expiração e confirmação concorrentes têm
  resultado determinístico; pagamento após expiração não reativa a reserva automaticamente.

### Precificação
- **RF-16** Preços por hora, diária (24 h ou dia de calendário) e semana; período mínimo; arredondamento.
- **RF-17** Faixas por quantidade, descontos autorizados, cupons, tarifas adicionais, caução, multa por atraso,
  condições negociadas por cliente.
- **RF-18** Snapshots de preço e condições: alterações de catálogo não afetam reservas/contratos existentes.

### Orçamentos e contratos
- **RF-19** Orçamentos versionados com validade, itens, períodos e condições; aprovação e rejeição de versão.
- **RF-20** Conversão idempotente de orçamento aprovado em reserva; política de bloqueio explícita.
- **RF-21** Contratos de locação com documentos versionados (PDF a partir de dados reais), aditivos e
  cancelamento com política explícita. Aceite eletrônico simples registrado como tal.

### Retirada, devolução e manutenção
- **RF-22** Separação, conferência e retirada dos ativos/quantidades efetivamente entregues.
- **RF-23** Devolução total ou parcial, inspeção, avarias, faltas, encaminhamento para manutenção e liberação.
- **RF-24** Prevenção de retirada/devolução duplicadas.
- **RF-25** Alertas de atraso e identificação de reservas futuras afetadas.
- **RF-26** Transferências entre filiais com estados de saída, trânsito e recebimento.
- **RF-27** Cobranças por dano ou falta com evidências e autorização.

### Financeiro
- **RF-28** Contas a receber, pagamentos parciais, saldos, reembolsos, cobranças adicionais.
- **RF-29** Cauções separadas da receita: recebimento, aplicação, devolução; distinção entre depósito
  pago e pré-autorização em cartão.
- **RF-30** Registros imutáveis após confirmação, correções por operações compensatórias.
- **RF-31** Conciliação básica com o provedor de pagamentos.
- **RF-32** Simulador local determinístico e adaptador para o sandbox Asaas.

### Notificações, arquivos e integrações
- **RF-33** E-mails transacionais via SMTP (Mailpit no ambiente local).
- **RF-34** Anexos com armazenamento por adaptador, downloads autenticados e retenção controlada.
- **RF-35** Webhooks recebidos autenticados e deduplicados; webhooks enviados assinados com retentativas.
- **RF-36** Credenciais de integração com escopos, validade e revogação.

### Interfaces
- **RF-37** Interface web em português para todas as áreas operacionais.
- **RF-38** Portal do cliente: disponibilidade, solicitação de reserva, aprovação de orçamento,
  acompanhamento de contrato e cobranças.
- **RF-39** API versionada documentada em OpenAPI, com idempotência em operações de reserva e financeiras.
- **RF-40** CLI operacional usando os mesmos casos de uso e permissões.
- **RF-41** Auditoria das operações relevantes.
- **RF-42** Planos e limites efetivos (ativos, filiais, usuários, funcionalidades).

## 3. Requisitos não funcionais

- **RNF-01** Núcleo em Ruby, sem framework de aplicação e sem ORM; domínio independente de infraestrutura.
- **RNF-02** Isolamento entre tenants por escopo explícito, policies, constraints e Row-Level Security.
- **RNF-03** Concorrência: múltiplas threads e processos sem sobrealocação nem efeitos duplicados.
- **RNF-04** Segurança: sessões seguras, CSRF, rate limiting, CSP, validação de entrada, redação de logs.
- **RNF-05** Observabilidade: logs estruturados correlacionados, métricas de baixa cardinalidade, liveness/readiness.
- **RNF-06** Reprodutibilidade: Docker, versões fixadas, lockfile, migrations versionadas com checksum.
- **RNF-07** Qualidade: ≥ 90% de cobertura de linhas em domínio e aplicação; ≥ 80% de branches em caminhos críticos.
- **RNF-08** Acessibilidade: navegação por teclado, labels, foco visível, estados vazios e de erro.
