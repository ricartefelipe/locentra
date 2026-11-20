# Política de precificação

Implementação: `lib/locentra/domain/pricing.rb`. Valores comerciais do catálogo são definidos por cada
organização; os planos da plataforma são hipóteses de produto.

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
3. Condição negociada do cliente (`customer_price_agreements`, por produto ou geral, maior vigente).
4. Subtotal = soma das linhas.
5. Cupom (percentual ou fixo, limitado ao subtotal; validade, valor mínimo e limite de utilizações; o consumo
   ocorre com lock na criação da reserva).
6. Desconto manual autorizado, limitado por papel (proprietário/administrador 100%, gerente 20%,
   atendente 5%, demais 0%).
7. Tarifas adicionais (entrega, montagem etc.).
8. Caução prevista = soma da caução unitária × quantidade (fora do total da locação; ver política de caução).

## Snapshots e alterações

- Cada item de reserva guarda o snapshot completo (tabela, unidades, descrição, descontos e totais); a
  reserva guarda o resumo. Alterações no catálogo não alteram reservas, orçamentos aprovados nem contratos.
- **Extensão:** o valor original é preservado; a diferença entre o preço do novo período (calculado com a
  tabela do snapshot) e o valor original é gravada como ajuste (`reservation_adjustments`, tipo `extension`)
  e, em contratos, como aditivo.
- **Atraso:** multa = preço do tempo excedente (após a tolerância) pela tabela do snapshot × multiplicador.
- **Cancelamento:** percentual da política congelada no contrato conforme a antecedência (padrão: ≥ 72 h 0%,
  ≥ 24 h 30%, < 24 h 100%), gravado como ajuste `cancellation_fee`.
- Ajustes viram cobranças pela sincronização idempotente do módulo financeiro.
