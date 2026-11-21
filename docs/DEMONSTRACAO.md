# Demonstração de ponta a ponta

Roteiro para apresentar o Locentra manualmente com os dados do seed, do primeiro acesso ao isolamento
entre organizações. O mesmo roteiro é executado automaticamente por
`test/integration/demo_flow_test.rb` (passos 1 a 14) e por
`test/integration/demo_commercial_terms_test.rb` (passo 15), com dados próprios dos testes, o que garante
que os passos e os resultados descritos aqui continuam válidos.

## Preparação

```bash
bin/setup                       # imagens, PostgreSQL, Mailpit, migrations, seed, web e worker
docker compose up -d web worker # se o ambiente já existia
```

O seed é idempotente (`ruby bin/locentra-admin db:seed` pode ser repetido) e, além das duas
organizações, garante os dados usados neste roteiro: a proprietária da Alfa também é gerente da Beta
e a Alfa tem a conta do simulador de pagamentos ativa. Esses dois itens só são criados quando nunca
existiram: repetir o seed não substitui outro provedor configurado na Alfa, não reativa uma conta
desativada e não devolve um acesso revogado. Nesses casos, configure o simulador em **Financeiro →
Provedor de pagamentos** antes do passo 12 e use `paulo@beta.demo` no passo 14.

O seed também cria as condições comerciais do passo 15, com a mesma política: tarifas e cupons só são
criados quando o código nunca existiu na organização (ativo ou desativado), e a condição negociada só é
criada para o cliente que nunca teve nenhuma. Na Alfa: tarifas **ENTREGA** (R$ 150,00), **MONTAGEM**
(R$ 250,00) e **LIMPEZA** (R$ 80,00); cupons **BEMVINDO10** (10%, até 100 usos) e **PRIMEIRALOCACAO**
(R$ 50,00 em locações a partir de R$ 300,00, uso único), válidos por 365 dias a partir do seed; condição
geral de **8%** para Produtora Horizonte Ltda. e de **10%** na Lente 24-70mm f/2.8 (LEN-2470) para Marina
Souza. Na Beta: tarifas ENTREGA e MONTAGEM, cupom **PRIMAVERA15** e condição de 5% para Casamentos
Primavera ME. Se algum desses itens mudou depois do seed, ajuste-o antes do passo 15: o código de cupom e
o de tarifa são únicos na organização, inclusive entre os desativados, então um item desativado é
**reativado** ("Reativar cupom" em **Cupons** ou "Reativar tarifa" em **Tarifas adicionais**), e um item
alterado volta aos valores do roteiro pela edição na própria página. Exigem novo cadastro somente a condição
negociada encerrada, em **Clientes → Produtora Horizonte Ltda. → Nova condição negociada** (8%, todos os
produtos), e o cupom excluído (a exclusão vale para cupom nunca usado e não deixa nada a reativar). O cupom
excluído é recriado ao repetir o seed (`ruby bin/locentra-admin db:seed`), porque o código deixou de existir,
ou pode ser cadastrado de novo em **Cupons → Novo cupom** com os valores acima.

| Endereço | Uso |
|---|---|
| http://localhost:9292 | Interface web e API (`/api/v1`) |
| http://localhost:8025 | Mailpit: e-mails enviados pelo worker (confirmação, orçamento, contrato) |
| http://localhost:9292/metrics | Métricas no formato do Prometheus (com `METRICS_TOKEN`, enviar `Authorization: Bearer <token>`) |

Senha de todos os usuários demonstrativos: `locentra-local-demo`.

| Usuário | Organização e papel |
|---|---|
| `ana@alfa.demo` | Alfa Audiovisual (proprietária) e Beta Eventos (gerente) |
| `bruno@alfa.demo`, `carla@alfa.demo`, `diego@alfa.demo`, `elisa@alfa.demo` | Alfa: atendimento, estoque, financeiro e auditoria |
| `paulo@beta.demo` | Beta Eventos (proprietário) |
| `rita@beta.demo` | Beta Eventos (atendimento) |

Convenções: **D** é a data de hoje; horários são locais (America/Sao_Paulo). O worker precisa estar em
execução: ele envia e-mails, gera as cobranças a partir dos eventos das reservas, envia cobranças ao
provedor e processa os eventos do provedor. Valores esperados consideram os produtos criados no passo 2.

## Roteiro

### 1. Entrar na organização A

1. Acesse http://localhost:9292 e entre com `ana@alfa.demo`.
2. A tela **Selecione a organização** lista **Alfa Audiovisual** (Proprietário) e **Beta Eventos**
   (Gerente). Escolha **Alfa Audiovisual**.

**Esperado:** painel com "Organização ativa: Alfa Audiovisual" e o nome da organização no topo. A
navegação lateral mostra somente as áreas permitidas ao papel. A tecla Tab, na primeira vez, foca o
atalho **Ir para o conteúdo**; Enter leva o foco ao conteúdo principal.

### 2. Cadastrar cliente e catálogo

1. **Clientes → Novo cliente**: Pessoa física, nome **Joana Prado**, CPF **111.444.777-35**, e-mail
   `joana@cliente.demo` → **Cadastrar**. (Um CPF inválido mostra o resumo de erros com foco nele e
   o campo marcado como inválido.)
2. **Produtos e kits → Novo produto**: SKU **GRAV-F6**, nome **Gravador Zoom F6**, **Ativo individual**,
   preço da diária **150,00**, caução por unidade **500,00** → **Cadastrar**.
3. Novo produto: SKU **XLR-10**, nome **Cabo XLR 10 m**, **Estoque quantitativo**, diária **10,00** →
   **Cadastrar**.

**Esperado:** cliente e produtos nas listas; tentar cadastrar outro cliente com o mesmo CPF é recusado.

### 3. Ativo individual e estoque quantitativo

1. Na página do **Gravador Zoom F6**, em **Cadastrar ativo**, registre os patrimônios **GRAV-F6-001** e
   **GRAV-F6-002** (filial Matriz).
2. Na página do **Cabo XLR 10 m**, em **Estoque quantitativo por filial**, registre uma **Entrada** de
   **20** unidades.

**Esperado:** **Ativos** lista os dois gravadores como disponíveis; o estoque do cabo mostra 20 unidades
e o histórico do movimento.

### 4. Consultar disponibilidade

**Disponibilidade → Consultar disponibilidade**: filial Matriz, início **D+10 09:00**, fim
**D+12 09:00** → **Consultar**.

**Esperado:** Gravador Zoom F6 com **2** disponíveis; Cabo XLR 10 m com **20**. O calendário de
**Disponibilidade** mostra a ocupação por dia.

### 5. Criar orçamento e reserva

1. **Orçamentos → Novo orçamento**: cliente Joana Prado, retirada **D+10 09:00**, devolução
   **D+12 09:00**, validade **D+5**, itens **1 × Gravador Zoom F6** e **15 × Cabo XLR 10 m** (use
   **Adicionar item** para a segunda linha) → **Salvar rascunho**.
2. **Enviar versão 1** (o e-mail aparece no Mailpit). Em **Registrar aprovação do cliente**, informe
   **Joana Prado** → **Registrar aprovação**.
3. **Converter em reserva**.

**Esperado:** orçamento com total **R$ 600,00** (2 diárias × R$ 150,00 + 2 diárias × 15 × R$ 10,00) e
caução prevista de **R$ 500,00**; a conversão abre a reserva **Confirmada**, com origem no orçamento.
Converter de novo não cria outra reserva. A consulta do passo 4 passa a mostrar 1 gravador e 5 cabos.

### 6. Disputar a última unidade e rejeitar a confirmação incompatível

1. **Reservas → Nova reserva** para **Produtora Horizonte Ltda.**, mesmo período, **1 × Gravador Zoom F6**,
   política **Solicitação** → **Registrar reserva** (fica "Solicitada", sem alocação).
2. Nova reserva igual, política **Bloqueio temporário** → registrada: ela fica com o último gravador.
3. Mais uma reserva igual com **Bloqueio temporário** → recusada: "Disponibilidade insuficiente para o
   período solicitado", com o produto em falta.
4. Abra a reserva solicitada do item 1 e clique em **Confirmar reserva**.

**Esperado:** a confirmação é recusada ("Confirmação recusada: …") e a reserva continua **Solicitada**;
nenhuma unidade é alocada duas vezes. As reservas da Produtora Horizonte Ltda. saem com a condição
negociada de 8% do seed (R$ 276,00 em vez de R$ 300,00), o que não muda o resultado deste passo; a condição
é o assunto do passo 15. Em `/metrics`, `locentra_domain_conflicts_total{code="unavailable"}`
aumenta a cada recusa. (A disputa realmente simultânea, com duas transações ao mesmo tempo, é
comprovada pelo teste automatizado e pela suíte `test/concurrency`.)

### 7. Gerar contrato

Na reserva convertida, em **Contrato e orçamento**, clique em **Gerar contrato**.

**Esperado:** contrato **C-…** emitido, com termos congelados (itens, preços, caução, período e política
de cancelamento) e o **PDF versão 1** para download, com a menção ao aceite eletrônico simples. O
aceite pode ser registrado em **Registrar aceite da versão 1**.

### 8. Registrar retirada

1. No painel **Financeiro** da reserva, **Registrar caução** (Depósito pago, R$ 500,00). Na página da
   caução, **Registrar recebimento** (Pix, R$ 500,00).
2. Em **Retirada e devolução**, **Iniciar retirada**. Na conferência, informe o patrimônio alocado
   (GRAV-F6-001 ou GRAV-F6-002, conforme a coluna "Alocado") e **15** cabos → **Registrar conferência**.
3. Em **Quem está retirando**, mantenha **Joana Prado (cliente)** → **Registrar entrega**.

**Esperado:** caução **Retida** com saldo R$ 500,00; reserva **Em andamento**; o gravador entregue fica
"Com cliente". Antes do início previsto, a entrega é antecipada: a alocação passa a começar no
instante da entrega.

### 9. Devolução parcial e avaria

**Registrar devolução**: gravador com resultado **Avariado** e observação **Tela trincada**; cabos com
**10** unidades **Sem ocorrências** → **Registrar devolução**.

**Esperado:** a reserva continua **Em andamento** (5 cabos com o cliente); o gravador vai para
inspeção; o registro de avaria **AV-…** fica "Aguardando aprovação" (o custo estimado pode ser revisado
no próprio registro).

### 10. Encaminhar item para inspeção

1. **Registrar devolução** de **2** cabos **Sem ocorrências**, marcando **Exige inspeção**, observação
   **Conector frouxo**.
2. **Retiradas e devoluções → Inspeções**: há duas pendentes. Nos cabos, **Aprovar e liberar**. No
   gravador, informe o motivo **Tela precisa de troca** → **Reprovar e abrir manutenção**.
3. Abra o registro de avaria (**Retiradas e devoluções → Avarias**), anexe uma foto (PNG, JPEG, WebP ou
   PDF) em **Anexos**, informe **Valor da cobrança 200,00** → **Aprovar cobrança**.

**Esperado:** os 2 cabos voltam a ficar disponíveis; o gravador fica "Em manutenção" com a ordem
**OM-…** em **Manutenção**; a avaria fica "Cobrança aprovada" (sem evidência anexada, a aprovação é
recusada).

### 11. Finalizar devolução e ajustar caução

1. **Registrar devolução** dos **3** cabos restantes **Sem ocorrências**.
2. No painel **Financeiro** da reserva (use **Sincronizar cobranças** se o worker ainda não as gerou):
   cobranças de **Locação R$ 600,00** e **Avaria R$ 200,00**.
3. Na caução: **Aplicar caução** à cobrança de avaria (R$ 200,00); depois **Devolver** R$ 300,00 por Pix.

**Esperado:** reserva **Concluída**; cobrança de avaria **Quitada**; caução **Encerrada** com saldo
R$ 0,00. Em **Financeiro**, o diário contábil (saldos por conta) mostra a caução como passivo, sem tocar
receita.

### 12. Confirmar pagamento simulado

1. Abra a cobrança de **Locação** e, em **Enviar cobrança**, escolha Pix, **R$ 500,00**, um vencimento
   futuro e o cenário **Sucesso** → **Enviar cobrança**.
2. Na página do pagamento, a situação começa em **Aguardando envio ao provedor**; depois que o worker
   registra a cobrança no simulador, passa a **Aguardando pagamento** (atualize a página). Clique em
   **Simular confirmação pelo provedor**.

**Esperado:** o evento do provedor é gravado e processado pelo worker; o pagamento fica **Confirmado** e
a cobrança de locação **Parcialmente paga**, com saldo de **R$ 100,00**. Clicar de novo em simular gera
"Evento repetido descartado", sem novo lançamento.

### 13. Repetir uma operação com a mesma chave de idempotência

1. **Usuários e permissões → Credenciais de integração**: nome **Demonstração**, tipo **API**, escopos
   `finance.read` e `finance.write` (pagamentos deste passo) e `customers.read` (consulta de clientes
   do passo 14) → **Criar credencial**. Copie o token exibido (aparece uma vez).
2. Com o identificador da cobrança de locação (parte final do endereço `/financeiro/cobrancas/<id>`),
   envie o mesmo pagamento duas vezes:

```bash
TOKEN='<token da credencial>'
COBRANCA='<id da cobrança de locação>'
for i in 1 2; do
  curl -s -i -X POST http://localhost:9292/api/v1/payments \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: demo-saldo-0001' \
    -d "{\"receivable_id\":\"$COBRANCA\",\"method\":\"pix\",\"amount_cents\":10000}"
done
```

3. Repita com a mesma chave e `"amount_cents":1`.

**Esperado:** as duas primeiras respostas são `201` com o mesmo `id`; a segunda traz
`idempotent-replayed: true`. A terceira responde `409` (`idempotency_key_reused`). A cobrança tem um
único pagamento manual de R$ 100,00 e fica **Quitada**.

### 14. Entrar na organização B e comprovar isolamento

1. **Trocar organização** (topo) → **Beta Eventos**.
2. Veja **Clientes**, **Reservas** e **Produtos e kits**: somente os dados da Beta (Casamentos
   Primavera ME, gerador, cadeiras e mesas).
3. Abra o endereço de uma reserva da Alfa (copiado no passo 5).
4. Com o token da Alfa (passo 13), `curl -s http://localhost:9292/api/v1/customers -H "Authorization: Bearer $TOKEN"`.

**Esperado:** nenhum dado da Alfa aparece na Beta; o endereço da reserva da Alfa responde **Página não
encontrada** (404, sem revelar que o registro existe). A API responde `200` e o campo `data` traz
somente os clientes da Alfa (Joana Prado, Marina Souza e Produtora Horizonte Ltda.), sem Casamentos
Primavera ME: a credencial pertence à Alfa, independentemente da organização ativa no navegador. Uma
credencial sem o escopo `customers.read` recebe `403` (`forbidden`) nessa chamada. O mesmo isolamento
vale entrando como `paulo@beta.demo`. No banco, as políticas de RLS impedem a leitura de linhas de
outra organização mesmo com SQL incorreto.

### 15. Condições comerciais: cupom, condição negociada e tarifa

1. Entre com `ana@alfa.demo` e escolha **Alfa Audiovisual** (ou use **Trocar organização**).
2. Confira os cadastros: **Cupons** lista **BEMVINDO10** (10%, "0 de 100") e **PRIMEIRALOCACAO**;
   **Tarifas adicionais** lista **ENTREGA**, **MONTAGEM** e **LIMPEZA**; em **Clientes → Produtora Horizonte
   Ltda.**, a seção **Condições negociadas** mostra a condição de **8%** em **Todos os produtos**, vigente.
3. **Reservas → Nova reserva**: cliente **Produtora Horizonte Ltda.**, retirada **D+20 09:00**, devolução
   **D+22 09:00**, **1 × Câmera Sony FX6**; em **Tarifas adicionais**, escolha **Entrega e retirada no
   local** e deixe o valor em branco (vale o padrão); em **Cupom**, digite **bemvindo10** (minúsculas são
   aceitas); política **Confirmar agora** → **Registrar reserva**.
4. Abra **Cupons → BEMVINDO10**. Depois volte à reserva e use **Cancelar reserva** (informe um motivo).
   Abra o cupom de novo.
5. Saia e entre com `bruno@alfa.demo` (atendente). Abra **Reservas → Nova reserva**.
6. Saia, entre com `ana@alfa.demo` e escolha **Beta Eventos** (gerente). Em **Reservas → Nova reserva**,
   para **Casamentos Primavera ME**, mesmo período, **1 × Gerador 5 kVA**, cupom **BEMVINDO10** →
   **Registrar reserva**.

**Esperado:**

- Item 3: a reserva **Confirmada** mostra, em valores, subtotal **R$ 828,00** com a nota "o subtotal já
  considera a condição negociada (−R$ 72,00)" (2 diárias × R$ 450,00 = R$ 900,00, menos 8%), **Cupom
  BEMVINDO10 (10%)** de **−R$ 82,80**, **Entrega e retirada no local R$ 150,00**, **Total contratado
  R$ 895,20** e **Caução prevista R$ 3.000,00**. A linha do item traz a coluna **Condição** com
  "−8% (−R$ 72,00)".
- Item 4: antes do cancelamento, o cupom mostra usos ativos "1 de 100; restantes: 99" e a reserva na seção
  **Usos**, com situação "Ativo". Depois do cancelamento, "0 de 100; restantes: 100", e a mesma linha
  aparece como "Liberado: reserva cancelada": o uso é liberado sem apagar o registro.
- Item 5: o atendente vê a tarifa somente pelo valor padrão ("Entrega e retirada no local · R$ 150,00"),
  sem o campo de valor e sem tarifas avulsas, com o aviso "Tarifas são aplicadas pelo valor padrão. Valor
  diferente e tarifa avulsa exigem a permissão de ajustar tarifas (gerente, administrador ou
  proprietário)." O menu dele tem **Cupons** e **Tarifas adicionais** para consulta, sem os botões de
  cadastro.
- Item 6: a reserva é recusada com "cupom inexistente": o cupom da Alfa não existe na Beta, que tem os
  próprios cupons (**PRIMAVERA15**).

Os mesmos cadastros estão na API (`/api/v1/coupons`, `/api/v1/fees`,
`/api/v1/customers/<id>/price-agreements`) e na CLI (`bin/locentra coupons list`), com credenciais que
tenham os escopos `coupons.read`, `fees.read` e `price_agreements.read`.

## Observabilidade durante o roteiro

- Toda resposta traz `x-request-id`; um cliente pode enviar o próprio identificador
  (`-H 'X-Request-Id: demo-pagamento-0001'`, 8 a 64 caracteres `[A-Za-z0-9._-]`).
- O mesmo identificador aparece como `correlation_id` nas tarefas e nos logs do worker:
  `docker compose logs worker | grep 'demo-pagamento-0001'` mostra `job.finished` de
  `payments.submit` e `external.call` (serviço `simulator`, operação `create_charge`).
- `curl -s http://localhost:9292/metrics | grep -E 'domain_conflicts|jobs_(queue_size|retries|dead)|http_requests_total'`
  mostra conflitos por código, a fila (atualizada pelo worker a cada minuto) e as requisições por rota
  modelo. Nenhum rótulo contém identificadores.

## Execução automatizada

```bash
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/demo_flow_test.rb
docker compose run --rm dev bundle exec ruby -Ilib -Itest test/integration/demo_commercial_terms_test.rb
docker compose run --rm dev bundle exec rake test:browser   # fluxos da interface no Chromium
```
