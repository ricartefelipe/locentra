# Política de caução

Implementação: módulo financeiro (`docs/modulos/financeiro.md`).

- A caução prevista de uma reserva é a soma da caução unitária de cada produto × quantidade, congelada no
  snapshot da reserva.
- **Caução não é receita.** O recebimento credita a conta de passivo `deposit_liability`; nada é lançado em
  contas de receita.
- **Tipos:**
  - `paid_deposit` (implementado): valor efetivamente pago (Pix, boleto, transferência ou dinheiro, manual ou
    pelo provedor).
  - `card_preauthorization` (modelado e recusado): exigiria tokenização de cartão no provedor; o produto não
    recebe nem armazena número do cartão (PAN) ou CVV.
- **Aplicação:** a caução pode quitar cobranças da mesma reserva (por exemplo, avaria ou falta aprovadas), até o
  menor entre o saldo da caução e o saldo da cobrança. Lançamento: débito `deposit_liability`, crédito
  `receivable` (a receita da avaria já foi reconhecida na emissão da cobrança).
- **Devolução:** o saldo remanescente é devolvido ao cliente como saída manual registrada (débito
  `deposit_liability`, crédito `cash`). Não há estorno automático pelo provedor.
- **Imutabilidade:** movimentos de caução são somente inserção; saídas são limitadas ao saldo por gatilho;
  correções por operações compensatórias.
- **Autorização:** `deposits.manage` (proprietário, administrador, gerente, financeiro); cobranças de avaria e
  falta exigem evidência e aprovação por `damage_charges.approve` antes de existirem.
- **Encerramento:** ao concluir a devolução, a equipe aplica a caução às cobranças aprovadas e devolve o saldo;
  o painel financeiro da reserva mostra caução recebida, aplicada, devolvida e saldo.
