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
- A expiração tem três gatilhos (varredura, tentativa de confirmação e alocação que encontra o bloqueio
  vencido ocupando o produto); todos gravam auditoria `reservation.expired` com o gatilho e publicam o evento
  `reservation.expired` na mesma transação. Pagamento recebido com o bloqueio já vencido e ainda não
  varrido é tratado como pagamento após a expiração (revisão e alerta).

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

## Condições comerciais

As situações de cupom, condição negociada e uso de cupom são **derivadas** dos dados e do instante da
consulta (não há coluna de situação), com a mesma regra no domínio (`Domain::Pricing`) e nas consultas SQL.
Detalhes em [`modulos/condicoes-comerciais.md`](modulos/condicoes-comerciais.md).

**Cupom** (`Coupon#status`), na ordem de precedência:

| Situação | Condição |
|---|---|
| `inactive` (desativado) | `active = false` |
| `expired` (expirado) | `valid_until <= agora` |
| `scheduled` (agendado) | `valid_from > agora` |
| `exhausted` (esgotado) | usos ativos `>= max_redemptions` |
| `active` (vigente) | nenhuma das anteriores |

Desativação e reativação são as únicas transições comandadas (`coupon.deactivated`, `coupon.reactivated`);
as demais acontecem com o tempo, com os usos e com a edição da vigência ou do máximo. Um cupom esgotado volta
a vigente quando um uso é liberado ou o máximo aumenta.

**Condição negociada** (`Agreement#status`), na ordem de precedência:

| Situação | Condição |
|---|---|
| `ended` (encerrada) | `ended_at <= agora` |
| `expired` (expirada) | `valid_until <= agora` |
| `scheduled` (agendada) | `valid_from > agora` |
| `active` (vigente) | nenhuma das anteriores |

```
scheduled ──(início)──► active ──(fim da vigência)──► expired
    │                      │
    └──────────────────────┴──(encerramento: imediato, ou agendado e chegado o instante)──► ended
```

O encerramento é registrado uma única vez. Com `ended_at` no futuro, a condição continua vigente (ou
agendada) com **encerramento agendado** e passa a encerrada quando o instante chega, sem nova gravação;
um encerramento já registrado, mesmo agendado, não é alterado nem repetido. Condição expirada não é
encerrada. Encerrar uma condição agendada antes do início deixa a vigência vazia.

**Tarifa adicional:** `active` (ativa) ⇄ `inactive` (inativa), por desativação e reativação. Tarifa inativa
não entra em documentos novos; continua nas entradas mantidas de uma nova versão de orçamento.

**Uso de cupom** (`Redemptions.state`), derivado da reserva que usou o cupom:

| Estado | Situação da reserva |
|---|---|
| `active` (ativo) | solicitada, confirmada, em andamento ou concluída; ou em bloqueio temporário com `hold_expires_at > agora` |
| `released_cancelled` (liberado: reserva cancelada) | cancelada |
| `released_expired` (liberado: bloqueio temporário expirado) | expirada, ou em bloqueio temporário já vencido e ainda não varrido |

A liberação não grava nada no cupom nem no livro de usos. Como um bloqueio vencido nunca volta a valer e
reservas canceladas ou expiradas são finais, um uso liberado não volta a ativo. Para o limite de usos, o
bloqueio vencido ainda conta durante a carência de 5 minutos (`Redemptions.counts_toward_limit?`), porque
uma confirmação iniciada antes do vencimento pode estar em andamento.

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
