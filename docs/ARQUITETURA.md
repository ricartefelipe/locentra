# Arquitetura do Locentra

Monólito modular com arquitetura hexagonal pragmática. Este documento evolui junto com o código;
o estado de cada parte está em `docs/STATUS.md`.

## Camadas

| Camada | Diretório | Responsabilidade | Pode depender de |
|---|---|---|---|
| Domínio | `lib/locentra/domain` | Entidades, value objects, máquinas de estado e regras puras | stdlib, tzinfo |
| Aplicação | `lib/locentra/application` | Casos de uso: autorização, coordenação de domínio, transações e portas | Domínio |
| Infraestrutura | `lib/locentra/infrastructure` | PostgreSQL, pool, repositórios SQL, fila, e-mail, PDF, arquivos, provedores | Domínio, Aplicação |
| Interfaces | `lib/locentra/interfaces/{http,cli}` | Rack/Puma, API, interface web, CLI | Aplicação |
| Composição | `lib/locentra/system.rb` | Composition root: monta dependências a partir da configuração | Todas |

Carregar `locentra/domain` não abre conexões, não inicia threads e não lê variáveis de ambiente.

## Motor de disponibilidade (domínio)

- `Period`: intervalo `[início, fim)` em UTC; períodos adjacentes não se sobrepõem.
- `Availability::Peak`: ocupação máxima simultânea por varredura de eventos, recortada à janela
  consultada. Em empates, saídas são processadas antes de entradas.
- `Availability::StockLedger`: capacidade de estoque quantitativo; disponível = capacidade − pico.
- `Availability::AssetSchedule`/`AssetPicker`: ativos individuais livres na janela, considerando
  bloqueios operacionais (inspeção, manutenção, trânsito) e seleção determinística sem repetição.
- `Availability::DemandExpander`: expande kits em componentes e agrega a demanda por produto físico,
  para que o mesmo componente pedido por caminhos diferentes seja verificado contra uma única capacidade.

As garantias sob concorrência ficam no PostgreSQL (seção a ser detalhada com a fatia de reservas).
