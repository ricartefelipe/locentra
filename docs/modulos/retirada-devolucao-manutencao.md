# Módulo: retirada, devolução, inspeção, avarias, manutenção, transferências e atrasos

Cobre RF-09, RF-22 a RF-27 e parte de RF-14. Migration: `db/migrations/0009_retirada_devolucao_manutencao.sql`.

## Visão geral

| Camada | Arquivos |
|---|---|
| Domínio | `domain/fulfillment.rb` (retirada, devolução, multa), `domain/maintenance.rb` (inspeção, ordem, avaria), `domain/transfers.rb`, `domain/alerts.rb` |
| Aplicação | `application/operations.rb` (serviços compartilhados), `fulfillment.rb`, `returns.rb`, `inspections.rb`, `maintenance.rb`, `transfers.rb`, `overdue.rb` |
| Persistência | `persistence/fulfillment.rb`, `maintenance.rb`, `transfers.rb`, `alerts.rb` |
| Interface | `interfaces/http/web/fulfillment_controllers.rb`, `maintenance_controllers.rb`, `views/operations/`, `views/maintenance/`, `views/transfers/` |
| Composição | `System#build_operations_use_cases`, `Routes.draw_operations` |

Casos de uso registrados: `start_pickup`, `check_pickup`, `deliver_pickup`, `cancel_pickup`, `get_pickup`,
`register_return`, `return_form`, `get_return`, `approve_inspection`, `reject_inspection`, `list_inspections`,
`create_damage_report`, `revise_damage_report`, `approve_damage_charge`, `dismiss_damage_report`, `get_damage_report`,
`list_damage_reports`, `open_maintenance_order`, `start_maintenance`, `complete_maintenance`, `cancel_maintenance`,
`list_maintenance_orders`, `get_maintenance_order`, `request_transfer`, `dispatch_transfer`, `receive_transfer`,
`cancel_transfer`, `list_transfers`, `detect_overdue`, `resolve_alert`, `operations_board`, `reservation_operations`.

## Modelo de dados

Todas as tabelas têm `organization_id NOT NULL`, `UNIQUE (organization_id, id)`, chaves estrangeiras compostas para
tabelas do mesmo tenant e RLS forçada (`app_enable_tenant_rls`). `DELETE` é revogado de `locentra_app` e
`locentra_worker` em todas elas.

| Tabela | Conteúdo | Garantias |
|---|---|---|
| `pickups` | Retirada da reserva: situação, quem retirou (cliente ou contato autorizado, nome e CPF), datas | Índice único parcial: uma retirada não cancelada por reserva. Gatilho impede alteração após `delivered`/`cancelled` |
| `pickup_lines` | Uma linha por alocação ativa (ativo ou estoque): previsto, conferido, entregue, devolvido, faltante, motivo da liberação | Índices únicos parciais por `asset_allocation_id` e `stock_allocation_id` (linhas não canceladas). `CHECK (returned + missing <= delivered)`. Gatilho: após a entrega só os acumulados mudam, e só para mais |
| `returns` | Devolução (total ou parcial): instante, quem recebeu, multa total, se concluiu a reserva | Somente inserção (`REVOKE UPDATE, DELETE`). Índice único parcial: uma única devolução conclui a reserva |
| `return_lines` | Item devolvido: resultado `ok`/`damaged`/`missing`, quantidade, exige inspeção, observações | Somente inserção. Índice único parcial por linha de retirada de ativo (ativo devolvido uma vez). `CHECK`: avaria exige inspeção; falta não passa por inspeção |
| `inspections` | Item (ativo ou quantidade de estoque com bloqueio) aguardando liberação; origem (devolução ou manutenção) e decisão | Uma inspeção pendente por ativo. Gatilho impede alteração após a decisão |
| `maintenance_orders` | Ordem `OM-nnnnnn`: item, serviço, situação anterior do ativo, custo, inspeção posterior, motivo de cancelamento | Uma ordem ativa por ativo. Concluída exige custo. Gatilho impede alteração após `completed`/`cancelled` |
| `damage_reports` | Avaria ou falta `AV-nnnnnn`: descrição, severidade, custo estimado, cobrança aprovada e ajuste gerado | Um registro não descartado por item devolvido (sem cobrança duplicada). Aprovado exige `adjustment_id`. Gatilho impede alteração após a decisão |
| `transfers` | Transferência `TR-nnnnnn` de ativo ou de quantidade de estoque entre filiais | Uma transferência ativa por ativo; origem ≠ destino. Gatilho impede alteração após `received`/`cancelled` |
| `reservation_alerts` | Alertas `overdue`, `affected_by_overdue`, `asset_unavailable`, com reserva relacionada, detalhes e resolução | `UNIQUE (organization_id, dedup_key)`: um alerta por situação. Resolvido exige `resolution`. Gatilho impede alteração após a resolução |

Tabelas existentes usadas: `asset_allocations`/`stock_allocations` (liberação, redução e bloqueios `kind = 'block'`),
`asset_events` (histórico), `stock_movements` (`loss`, `transfer_out`, `transfer_in`), `reservation_adjustments`
(`late_fee`, `damage`, `missing`), `attachments` (`owner_type = 'damage_report'` e `'maintenance_order'`),
`reservations.overdue_since` e `jobs` (e-mail `late_return`).

## Máquinas de estado

```
Retirada:        picking ──► delivered
                    └──────► cancelled
Linha retirada:  pending ⇄ checked ──► delivered | partial | not_delivered
                    └───────┴──────► cancelled (separação cancelada)
Reserva:         confirmed ──(entrega)──► in_progress ──(tudo devolvido ou faltante)──► completed
Inspeção:        pending ──► approved | rejected (abre ordem de manutenção)
Ordem:           open ──► in_progress ──► completed
                   └──────────┴───────► cancelled
Avaria/falta:    open ──► approved (cobrança) | dismissed
Transferência:   requested ──► in_transit ──► received
                     └──────► cancelled (somente antes da saída)
Alerta:          open ──► resolved
```

Situação do ativo (máquina existente em `Domain::Catalog`): entrega `available → checked_out`; devolução
`checked_out → available | in_inspection | lost`; reprovação `in_inspection → in_maintenance`; conclusão
`in_maintenance → available | in_inspection`; saída `available → in_transit`; recebimento `in_transit → available`
com troca de filial. Todas geram `asset_events` com referência ao registro de origem.

## Regras

### Retirada
- **Separação** (`start_pickup`): reserva confirmada; uma linha por alocação ativa. Repetir devolve a retirada em
  andamento (sob lock da reserva).
- **Conferência** (`check_pickup`): o patrimônio lido deve ser do mesmo produto, da filial da reserva e estar
  `available`. Se diferir do alocado, a alocação é reatribuída à unidade lida sob savepoint; a exclusion
  constraint recusa unidades já alocadas no período. Estoque é conferido por quantidade (0 a prevista). Erros de
  vários itens são reunidos numa única resposta; nada é gravado se algum item falhar.
- **Entrega** (`deliver_pickup`): exige ao menos um item conferido e o retirante — o próprio cliente pessoa física ou
  um contato com `authorized_pickup` e CPF válido (cliente pessoa jurídica retira somente por contato). Ativos
  entregues vão a `checked_out`; itens não conferidos têm a alocação liberada e a linha registra
  `not_delivered`/`partial` com o motivo; a quantidade de estoque não conferida deixa de ocupar o estoque. A reserva
  passa a `in_progress` e o evento `reservation.picked_up` é publicado.
- **Retirada duplicada**: lock da reserva e verificação de estado (segunda entrega recebe `Conflict`
  `already_picked_up`); no banco, índices únicos parciais em `pickups` e `pickup_lines`.

### Devolução
- Total ou parcial; cada item com resultado `ok`, `damaged` ou `missing` e a marca "exige inspeção". Avaria sempre
  exige inspeção; falta nunca. Avarias e faltas exigem descrição.
- O acumulado devolvido + faltante de cada linha nunca passa do entregue: verificado no domínio sob lock das linhas
  (`Conflict` `already_returned`) e garantido pelo `CHECK` do banco.
- Ativo `ok` sem inspeção volta a `available`; na devolução antecipada, a preparação posterior do produto continua
  bloqueando o ativo até o menor entre o fim original e agora + preparação. Com inspeção ou avaria, vai a
  `in_inspection` (indisponível até a decisão). Faltante vai a `lost`; reservas futuras são realocadas como em
  `ChangeAssetStatus` e as que ficam sem unidade recebem alerta `asset_unavailable`.
- Estoque: a alocação da reserva é reduzida pela quantidade devolvida. Com inspeção ou avaria, as unidades ficam sob
  bloqueio `[agora, ∞)` até a liberação. Faltas geram baixa (`stock_movements` `loss`). Bloqueio ou baixa que
  descubra reservas futuras gera alerta `asset_unavailable` para cada uma (nenhuma reserva é cancelada).
- Avarias e faltas abrem registro em `damage_reports` (falta com custo estimado = custo de reposição × quantidade).
- Devolução parcial mantém a reserva em `in_progress`; quando tudo foi devolvido ou registrado como faltante, a
  reserva vai a `completed` e os alertas de atraso relacionados são resolvidos automaticamente.
- **Multa por atraso**: devolução após o fim previsto calcula `Domain::Pricing::LateFee` com a tabela do snapshot do
  item e grava `reservation_adjustments` `late_fee` por item. Itens simples são cobrados pela quantidade devolvida;
  faltas não geram multa (são cobradas como reposição). Kits são cobrados pela quantidade do item quando a última
  pendência do kit é resolvida.
- Evento `reservation.returned` com resultado, conclusão e multa.

### Inspeção, manutenção e avarias
- Aprovar libera o item: ativo `available`; bloqueio de estoque encerrado ajustando o fim do período para o instante
  da aprovação (e desativado).
- Reprovar exige motivo e abre ordem de manutenção; o ativo vai a `in_maintenance`, reservas futuras são realocadas e
  as sem substituto recebem alerta. O bloqueio de estoque passa a pertencer à ordem.
- Ordem manual: ativo `available` (ativo em inspeção é encaminhado pela reprovação); reservas futuras sem substituto
  impedem a abertura. Estoque: as unidades precisam estar livres no horizonte de 366 dias.
- Concluir registra o custo; o item volta a `available` ou segue para nova inspeção. Cancelar devolve o item à
  situação anterior (inspeção, quando veio de inspeção reprovada, com nova inspeção pendente).
- Cobrança de avaria ou falta: somente por quem tem `damage_charges.approve` e com ao menos uma evidência anexada
  (rota `/anexos`, `owner_type = 'damage_report'`). A aprovação grava `reservation_adjustments` `damage`/`missing` com
  o valor informado ou o estimado. Registros podem ser revisados enquanto abertos ou descartados com motivo.
- A tela do ativo não altera manualmente a situação de ativo com cliente, em trânsito, com inspeção pendente ou com
  ordem de manutenção ativa (`Conflict` `asset_in_operation`).

### Transferências
- Ativo: solicitação exige ativo `available`; uma transferência ativa por ativo. Na saída, o ativo não pode ter
  alocações ativas futuras (reservas ou bloqueios) e passa a `in_transit` — indisponível em todas as filiais, pois a
  filial só muda no recebimento.
- Estoque: a quantidade sai do estoque de origem na saída, desde que o pico reservado no horizonte continue coberto,
  e entra no estoque de destino (criado se necessário) no recebimento.
- Cancelável somente antes da saída.

### Atrasos e alertas
- `detect_overdue` (executado pelo worker em `organization.tick`): reservas `in_progress` com `ends_at` vencido e itens
  pendentes recebem `overdue_since` (fim previsto) e um alerta `overdue` por fim previsto. Reservas futuras que usam
  os mesmos ativos ainda com o cliente, ou cuja capacidade de estoque fica descoberta pelas unidades em atraso,
  recebem `affected_by_overdue` com a reserva de origem. O e-mail `late_return` é enfileirado uma única vez por
  reserva (`unique_key`). Nada é cancelado automaticamente.
- Prazo estendido para o futuro limpa `overdue_since` e resolve os alertas abertos. Alertas resolvidos não são
  recriados (chave de deduplicação). A resolução manual exige o registro da decisão.

## Permissões

| Operação | Permissão |
|---|---|
| Separação, conferência, entrega, devolução, resolução de alertas | `fulfillment.write` |
| Aprovar/reprovar inspeção, registrar e revisar avaria, anexar evidência | `inspections.write` |
| Aprovar ou descartar cobrança de avaria/falta | `damage_charges.approve` |
| Ordens de manutenção | `maintenance.write` |
| Transferências | `assets.write` |
| Consultas e painel | `reservations.read` (listas de manutenção e transferências: `catalog.read`) |

Recursos de outra organização resultam em `NotFound` (RLS e filtros explícitos por `organization_id`).

## Interface

- `/operacao`: retiradas do dia (e atrasadas), devoluções previstas, atrasos, alertas com resolução, inspeções
  pendentes, avarias aguardando aprovação e transferências em andamento.
- `/operacao/retiradas/:id`: conferência por patrimônio/quantidade e entrega; `/operacao/reservas/:id/devolucao`:
  devolução por item; `/operacao/devolucoes/:id`: comprovante com multa.
- `/operacao/inspecoes`, `/operacao/avarias`, `/operacao/avarias/:id` (evidências pela rota `/anexos`).
- `/manutencao`, `/manutencao/:id` (anexos da ordem), `/transferencias`.
- Navegação "Retiradas e devoluções" (`fulfillment.write`) e "Manutenção" (`maintenance.write`). Na tela da reserva,
  ações conforme o estado (iniciar/continuar retirada, registrar devolução) e resumo de retiradas, devoluções,
  avarias e alertas. Na tela do ativo disponível, atalhos para manutenção e transferência.

## Decisões

- **Bloqueio de estoque sem fim definido**: inspeções e manutenções de estoque usam alocação `kind = 'block'` com
  período `[início, ∞)`. As ocupações de estoque (`AvailabilityRepository#stock_occupancies`) passaram a ser recortadas
  à janela consultada, o que mantém o cálculo de pico inalterado para períodos finitos.
- **Devolução libera a alocação do ativo**: em vez de encurtar a alocação da reserva (que uma extensão posterior
  voltaria a ampliar), a alocação é desativada e, quando cabe, um bloqueio de preparação é criado.
- **Códigos sequenciais** `OM-`, `AV-` e `TR-` usam `organization_counters`; na transferência, o código é obtido logo
  antes da inserção para que o lock do contador não serialize validações concorrentes.
- **Gatilhos de imutabilidade** usam `ERRCODE = 'check_violation'`, traduzido para erro de validação.
- **Alertas deduplicados por chave** (`overdue:<reserva>:<fim>`, `affected:<reserva>:<origem>:<recurso>`,
  `unavailable:<reserva>:<recurso>:<origem>`), com `ON CONFLICT DO NOTHING`.
- Bloqueios temporários vencidos deixaram de ser considerados na realocação de reservas futuras de um ativo.

## Limitações

- Itens não entregues na retirada não alteram automaticamente o valor da reserva; ficam registrados nas linhas para
  tratamento financeiro.
- A extensão de reserva em andamento (caso de uso existente) recalcula o ajuste de todos os itens, inclusive os já
  devolvidos.
- Estoque devolvido antes do fim fica disponível imediatamente (sem tempo de preparação); ativo devolvido após o fim
  previsto não recebe bloqueio de preparação adicional.
- Multa de kit usa a quantidade total do item, mesmo que parte do kit não tenha sido entregue.
- O custo estimado de faltas usa o custo de reposição vigente do produto no momento da devolução.
- Recebimento de transferência de estoque é integral (sem recebimento parcial).
- Ativo extraviado que reaparece segue o fluxo existente da tela do ativo (`lost → in_inspection → available`), sem
  registro em `inspections`.
- Não há endpoints de API nem comandos de CLI para estas operações; somente a interface web.

## Como testar

```bash
RUN="/caminho/para/tmp/dev/run.sh"
bash "$RUN" "$PWD" <banco> bundle exec rake test:unit                                    # domínio
bash "$RUN" "$PWD" <banco> bundle exec ruby -Ilib -Itest test/integration/fulfillment_flow_test.rb
bash "$RUN" "$PWD" <banco> bundle exec ruby -Ilib -Itest test/integration/damage_flow_test.rb
bash "$RUN" "$PWD" <banco> bundle exec ruby -Ilib -Itest test/integration/maintenance_transfer_overdue_test.rb
bash "$RUN" "$PWD" <banco> bundle exec ruby -Ilib -Itest test/concurrency/fulfillment_race_test.rb
bash "$RUN" "$PWD" <banco> bundle exec ruby -Ilib -Itest test/http/operations_pages_test.rb
DK_EXTRA="-e COVERAGE_CHECK=1" bash "$RUN" "$PWD" <banco> bundle exec rake test:all
```

| Cenário obrigatório | Teste |
|---|---|
| Retirada duplicada sequencial / concorrente | `test_duplicate_pickup_is_rejected_sequentially_and_by_constraints`; `test_concurrent_deliveries_of_the_same_pickup_hand_over_once`, `test_unique_indexes_block_duplicate_pickup_even_without_reservation_lock` |
| Devolução duplicada sequencial / concorrente | `test_duplicate_asset_return_is_rejected_sequentially_and_by_constraint`; `test_concurrent_returns_of_the_same_asset_register_once`, `test_concurrent_stock_returns_never_exceed_delivered_quantity` |
| Devolução parcial | `test_partial_return_keeps_reservation_in_progress_then_total_completes` |
| Avaria → indisponibilidade e manutenção | `test_damage_makes_item_unavailable_and_rejection_opens_maintenance` |
| Inspeção bloqueando disponibilidade (CheckAvailability) | `test_inspection_blocks_availability_until_released` |
| Transferência sem duplicidade | `test_asset_transfer_without_duplicity_between_branches`, `test_concurrent_transfer_requests_for_the_same_asset_keep_a_single_destination` |
| Atraso com alertas e reserva futura afetada | `test_overdue_creates_unique_alerts_identifies_affected_reservations_and_emails_once`, `test_worker_tick_detects_overdue_and_sends_late_return_email` |
| Multa por atraso | `test_late_return_records_late_fee_with_snapshot_table`, `test_late_fee_policy_for_simple_items_and_kits` |
| Cobrança exige evidência e permissão | `test_damage_charge_requires_evidence_and_permission`, `test_concurrent_charge_approvals_record_a_single_adjustment` |
| Isolamento | `test_operations_resources_are_isolated_between_organizations`, `test_other_tenant_operations_are_not_found` |
