# Política de precificação

Implementação: `lib/locentra/domain/pricing.rb` (motor de preços e cupom) e
`lib/locentra/domain/commercial_terms.rb` (cadastro de cupons, condições negociadas e tarifas adicionais).
Valores comerciais do catálogo são definidos por cada organização; os planos da plataforma são hipóteses de
produto. O cadastro das condições comerciais (telas, API, CLI, permissões, auditoria e concorrência) está em
[`modulos/condicoes-comerciais.md`](modulos/condicoes-comerciais.md).

## Representação

- Dinheiro em centavos inteiros (`Domain::Money`); `Float` é rejeitado. A API expõe
  `{"amount_cents": 12345, "currency": "BRL", "formatted": "R$ 123,45"}`.
- Percentuais em pontos-base (1% = 100 bps). Arredondamento **meio para cima** somente quando surge fração de
  centavo; rateios pelo método do maior resto preservam o total.
- Instantes em UTC; regras de calendário no fuso IANA da organização.

## Tabela de preços do produto

| Campo | Significado |
|---|---|
| `hourly_cents` | preço por hora |
| `daily_cents` | preço da diária |
| `weekly_cents` | preço da semana |
| `daily_mode` | `rolling_24h` (blocos de 24 h a partir da retirada) ou `calendar_day` (cada data local tocada pelo período) |
| `minimum_minutes` | período mínimo cobrado |
| `rounding_minutes` | arredondamento da cobrança por hora: 15, 30 ou 60 |
| `grace_minutes` | tolerância antes de cobrar a próxima unidade (hora, diária ou dia) |
| `late_fee_multiplier_bps` | multiplicador da multa por atraso (padrão 100%) |
| `quantity_tiers` | faixas por quantidade: `min_quantity` e `discount_bps` |

## Cálculo do preço unitário

1. Duração cobrável = máximo entre a duração e o período mínimo.
2. **Hora** (quando há preço por hora e a duração é menor que 24 h, ou não há diária/semana): minutos
   arredondados para cima em múltiplos de `rounding_minutes`, com tolerância sobre o excedente; o total por
   hora é limitado ao valor de uma diária, se existir.
3. **Diária de 24 h:** `ceil((duração − tolerância) / 24 h)`, mínimo 1. Ex.: retirada segunda 18h, devolução
   terça 9h → 1 diária.
4. **Dia de calendário:** número de datas locais tocadas por `[início, fim)`; se a devolução ocorre dentro da
   tolerância após a meia-noite, o último dia não conta. Ex.: segunda 18h a terça 9h → 2 dias. Mudanças de
   horário de verão são tratadas no fuso local (um dia de 23 h continua sendo um dia).
5. **Semana:** blocos de 7 dias; o restante é cobrado em diárias, limitado ao valor de uma semana adicional.
   Sem diária, semanas inteiras arredondadas para cima.

## Composição do total

1. Linha = preço unitário × quantidade.
2. Desconto da faixa de quantidade (maior faixa atingida).
3. Condição negociada do cliente, aplicada sobre o valor depois da faixa (ver abaixo).
4. Subtotal = soma das linhas.
5. Cupom (percentual ou fixo, limitado ao subtotal), somente em reservas.
6. Desconto manual autorizado, sobre o subtotal depois do cupom, limitado por papel
   (proprietário/administrador 100%, gerente 20%, atendente 5%, demais 0%).
7. Tarifas adicionais (entrega, montagem etc.).
8. Caução prevista = soma da caução unitária × quantidade (fora do total da locação; ver política de caução).

Todos os valores são inteiros em centavos e vale
`subtotal − cupom − desconto manual + tarifas = total` (a caução não entra no total).

Exemplo (passo 15 da demonstração): 1 câmera por 2 diárias de R$ 450,00 = R$ 900,00; condição negociada de
8% = −R$ 72,00, subtotal R$ 828,00; cupom de 10% = −R$ 82,80; tarifa de entrega R$ 150,00; total
R$ 895,20.

## Cupons

- **Cadastro:** código único por organização (3 a 40 caracteres: letras sem acento, números, hífen ou
  sublinhado; convertido para maiúsculas), tipo `percent` (0,01% a 100%, em pontos-base) ou `fixed` (valor em
  centavos), descrição, vigência, máximo de usos e subtotal mínimo. Código, tipo e valor não mudam depois do
  cadastro: para outro desconto, cadastra-se outro cupom. O campo "Cupom" da reserva aceita o código em
  maiúsculas ou minúsculas.
- **Vigência:** semiaberta `[início, fim)`, gravada em UTC e avaliada no instante da criação da reserva
  (`priced_at`), nunca no período da locação. Sem início, o cupom vale imediatamente; sem fim, não tem prazo.
  As telas e a CLI exibem os instantes no fuso da organização: para valer o dia 30/11 inteiro, o fim é
  01/12 00:00.
- **Subtotal mínimo:** comparado com o subtotal da reserva, depois das faixas de quantidade e das condições
  negociadas e antes do cupom.
- **Uso por reserva:** cada reserva criada com o cupom grava uma linha imutável no livro de usos
  (`coupon_redemptions`, no máximo uma por reserva) com o subtotal e o desconto. O uso é **ativo** enquanto
  a reserva está solicitada, confirmada, em andamento ou concluída, ou em bloqueio temporário ainda válido.
  Cancelamento e expiração do bloqueio **liberam** o uso sem nenhuma gravação: o estado do uso é derivado
  da situação da reserva, e um bloqueio vencido deixa de contar no mesmo instante, mesmo antes da varredura.
- **Limite:** `max_redemptions` limita os usos ativos. A verificação acontece na criação da reserva, com o
  cupom travado, e é repetida por um gatilho do banco. O máximo não pode ser reduzido abaixo dos usos ativos.
- **Base legada:** `coupons.redemptions` guarda os usos registrados até a versão 1.0.0, quando o contador só
  aumentava. A coluna ficou congelada: usos ativos = contador legado + usos ativos do livro.
- **Situação** (nesta ordem de precedência): desativado, expirado, agendado, esgotado, vigente. A recusa na
  reserva informa o motivo: "cupom inexistente", "cupom desativado", "cupom expirado", "cupom ainda não está
  vigente", "cupom esgotado" ou "subtotal abaixo do mínimo do cupom (R$ 300,00)".
- **Onde não se aplica:** orçamentos e solicitações do portal não aceitam cupom. A reserva convertida de um
  orçamento copia os preços do orçamento, sem cupom.
- Cupom usado (inclusive antes da versão 1.1.0) não é excluído; pode ser desativado.

## Condições negociadas por cliente

- Desconto percentual (0,01% a 90%) para um cliente, **geral** (todos os produtos) ou de **um produto**, com
  vigência `[início, fim)` avaliada no instante da precificação.
- Em cada linha vale o **maior** desconto entre a condição vigente do produto e a geral; em empate, a do
  produto. A condição é aplicada depois da faixa de quantidade e fica identificada no snapshot da linha.
- **Sem sobreposição:** o mesmo cliente não tem duas condições do mesmo escopo (geral, ou o mesmo produto)
  com vigências que se cruzam. A regra é verificada na aplicação e garantida por uma exclusion constraint.
- **Imutável:** depois de criada, a condição só recebe o encerramento, uma única vez, com motivo. O
  encerramento é imediato ou **agendado** para um instante futuro, anterior ao fim da vigência. Para trocar
  a condição sem intervalo, agenda-se o encerramento da atual para o instante em que a próxima começa.
- **Início e encerramento informados:** vazio vale o instante atual; um instante até 24 horas no passado é
  ajustado para o instante atual (o campo de data e hora dos formulários não tem segundos); mais de 24 horas
  no passado é recusado.
- Encerrar ou cadastrar condições não altera reservas, orçamentos e contratos já registrados. A extensão de
  uma reserva usa a condição gravada no snapshot da linha.

## Tarifas adicionais

- **Catálogo** da organização: código único (2 a 30 caracteres), nome, descrição e valor padrão. O código não
  muda. Alterar o valor padrão ou desativar a tarifa não muda documentos já registrados.
- **Aplicação:** reservas e orçamentos recebem até 10 tarifas; a mesma tarifa do catálogo não se repete no
  documento. Sem valor informado, vale o valor padrão vigente.
- **Ajustes** exigem a permissão `fees.override` (gerente, administrador ou proprietário): valor acima do
  padrão, valor abaixo do padrão e **tarifa avulsa** (descrição e valor, fora do catálogo). A redução é um
  desconto: fica limitada ao desconto manual máximo do papel sobre o valor padrão (gerente, 20%), e
  credenciais de integração não reduzem tarifas.
- **Continuidade na nova versão de orçamento:** a entrada idêntica a uma da versão anterior (mesma tarifa e
  mesmo valor, ou avulsa com a mesma descrição e o mesmo valor) já foi autorizada e é mantida sem nova
  autorização, mesmo que a tarifa tenha sido desativada. Uma tarifa do catálogo escolhida de novo sem valor
  usa o valor padrão vigente.
- Tarifas inativas não são aceitas em documentos novos. Os ajustes de tarifa são registrados na auditoria
  da reserva ou do orçamento e não fazem parte do snapshot de preços.
- Pela API, as tarifas são informadas somente na criação de reserva (não há API de orçamentos).

## Snapshots e alterações

- Cada item de reserva guarda o snapshot completo (tabela, unidades, descrição, descontos e totais); a
  reserva guarda o resumo. Alterações no catálogo, nos cupons, nas condições negociadas e nas tarifas não
  alteram reservas, orçamentos nem contratos já registrados. No banco, a coluna `pricing` de `reservations` e
  de `reservation_items` não pode ser alterada (gatilho).
- **Condições comerciais no snapshot:**

  | Onde | Chave | Conteúdo |
  |---|---|---|
  | Linha (`reservation_items.pricing`, `quote_versions.items[]`) | `negotiated_discount_bps`, `negotiated_discount_cents` | Desconto negociado aplicado à linha |
  | Linha | `negotiated_agreement_id` | Condição negociada aplicada (nulo sem condição) |
  | Resumo (`reservations.pricing`, `quote_versions.pricing`) | `coupon_code`, `coupon_discount_cents` | Código e desconto do cupom |
  | Resumo | `coupon` | Cupom como estava na precificação: `id`, `code`, `kind`, `value`, `description`, `valid_from`, `valid_until` (nulo sem cupom) |
  | Resumo | `agreements` | Condições aplicadas às linhas: `id`, `scope` (`general` ou `product`), `product_id`, `discount_bps`, `valid_from`, `valid_until`, `ended_at` |
  | Resumo | `fees`, `fees_cents` | Tarifas: `fee_id`, `code`, `description` (nome da tarifa ou texto da avulsa), `amount_cents`, `default_amount_cents` (nulo na avulsa), `source` (`catalog` ou `custom`); e a soma |

  Snapshots gravados antes do cadastro de condições comerciais não têm `coupon`, `agreements` nem
  `negotiated_agreement_id`; telas, PDF, termos de contrato e API tratam essas chaves como opcionais. O
  contrato copia cupom, condições e tarifas para os termos, e o PDF os descreve na seção "Valores".
- **Extensão:** o valor original é preservado; a diferença entre o preço do novo período (calculado com a
  tabela do snapshot) e o valor original é gravada como ajuste (`reservation_adjustments`, tipo `extension`)
  e, em contratos, como aditivo.
- **Atraso:** multa = preço do tempo excedente (após a tolerância) pela tabela do snapshot × multiplicador.
- **Cancelamento:** percentual da política congelada no contrato conforme a antecedência (padrão: ≥ 72 h 0%,
  ≥ 24 h 30%, < 24 h 100%), gravado como ajuste `cancellation_fee`.
- Ajustes viram cobranças pela sincronização idempotente do módulo financeiro.
