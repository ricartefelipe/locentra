# Máquinas de estado

Todas as transições são definidas no domínio (`lib/locentra/domain`) e aplicadas sob lock da linha
correspondente. Transições inválidas geram `Domain::InvalidTransition`.

## Reserva (`Domain::Reservations::TRANSITIONS`)

```
requested ──► held ──► confirmed ──► in_progress ──► completed
    │           │          │
    │           ├──► expired (bloqueio temporário vencido)
    ├───────────┴──────────┴──► cancelled
    └──► confirmed (confirmação direta com alocação atômica)
```

- `requested`: solicitação sem garantia de disponibilidade (sem alocação).
- `held`: bloqueio temporário com `hold_expires_at`; válido enquanto `agora < hold_expires_at`.
- Estados que ocupam disponibilidade: `held`, `confirmed`, `in_progress`.
- Confirmação e expiração concorrentes: decide quem obtém o lock da reserva, comparando o instante atual com
  `hold_expires_at`; a varredura usa `SKIP LOCKED`.

## Ativo (`Domain::Catalog::ASSET_TRANSITIONS`)

```
available ──► checked_out | in_inspection | in_maintenance | in_transit | lost | retired
checked_out ──► available | in_inspection | lost
in_inspection ──► available | in_maintenance | lost | retired
in_maintenance ──► available | in_inspection | retired
in_transit ──► available (recebimento na filial de destino) | lost
lost ──► in_inspection | retired
retired (final)
```

A situação física é distinta da disponibilidade futura, que deriva das alocações. Cada mudança gera
`asset_events`.

## Orçamento e contrato

Ver [`modulos/orcamentos-contratos.md`](modulos/orcamentos-contratos.md#máquinas-de-estado):
`draft → sent → approved | rejected | expired`, `approved → converted`; contrato
`issued → active | closed | cancelled`, `active → closed | cancelled`.

## Operação (retirada, devolução, inspeção, manutenção, transferência, alertas)

Ver [`modulos/retirada-devolucao-manutencao.md`](modulos/retirada-devolucao-manutencao.md#máquinas-de-estado).

## Financeiro (pagamento, reembolso, caução)

Ver [`modulos/financeiro.md`](modulos/financeiro.md#máquinas-de-estado). Pagamentos confirmados, falhos ou
cancelados são finais e imutáveis; correções usam operações compensatórias.

## Tarefa da fila (`jobs`)

```
pending ──(reivindicação com lease)──► running ──► succeeded
   ▲                                     │
   └──(falha: backoff)───────────────────┤
                                         ├──► dead (tentativas esgotadas ou falha permanente)
running com lease vencido ──► elegível para nova reivindicação (novo token)
dead ──(reprocessamento autorizado, jobs.manage)──► pending
```

Somente o detentor do `lease_token` atual conclui ou reagenda a tarefa.
