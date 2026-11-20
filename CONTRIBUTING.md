# Contribuindo com o Locentra

## Fluxo de branches (GitFlow)

| Branch | Origem | Destino | Uso |
|---|---|---|---|
| `main` | — | — | Versões estáveis de produção. Cada merge recebe tag anotada `vX.Y.Z`. |
| `develop` | `main` | — | Integração contínua das funcionalidades. |
| `feature/<descricao>` | `develop` | `develop` (PR) | Uma funcionalidade ou fatia vertical. |
| `release/<versao>` | `develop` | `main` (PR) e `develop` | Estabilização de versão: somente correções, versão e changelog. |
| `hotfix/<versao>` | `main` | `main` (PR) e `develop` | Correção urgente em produção; também aplicada à release ativa, se houver. |

Regras:

- Não desenvolva diretamente em `main` ou `develop`. Crie a branch antes da primeira alteração.
- Merges preservam a identidade da branch com commit de merge (equivalente a `git merge --no-ff`).
  No GitHub, use **Create a merge commit**; squash e rebase não são usados nas branches GitFlow.
- Não faça force push em branches compartilhadas e não reescreva histórico publicado.
- Não contorne hooks, proteções de branch ou checks obrigatórios.
- Após resolver conflitos, execute novamente as verificações afetadas antes de concluir o merge.
- Tags são anotadas: `git tag -a v1.2.0 -m "Locentra 1.2.0"`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/), em português, pequenos e coesos:

```
feat(reservas): confirmar reserva com revalidação atômica
fix(financeiro): impedir reembolso acima do saldo elegível
test(disponibilidade): propriedades do cálculo de pico
docs(arquitetura): descrever coordenador de transações
chore(ci): adicionar análise da imagem
```

Tipos: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`.
Alterações incompatíveis usam `!` (`feat(api)!:`) e rodapé `BREAKING CHANGE:`.

## Versionamento

[SemVer](https://semver.org/lang/pt-BR/). A versão fica em `lib/locentra/version.rb` e é alterada
somente em branches `release/*` ou `hotfix/*`. O histórico de mudanças fica em `CHANGELOG.md`.

## Pull requests

Use o modelo em `.github/pull_request_template.md`, com as seções **Problema**, **Alteração**,
**Validação** e **Limitações**. O merge exige os checks de CI configurados como obrigatórios e as
aprovações configuradas na proteção da branch. A seção de validação deve listar os comandos
efetivamente executados e seus resultados.

## Ambiente e verificações locais

Pré-requisitos: Docker com Compose v2. Ruby local é opcional (versão em `.ruby-version`).

```bash
bin/setup                                   # constrói imagens, sobe PostgreSQL e Mailpit, aplica migrations e seed
docker compose run --rm dev bundle exec rake test:unit
docker compose run --rm dev bundle exec rake test:all
docker compose run --rm dev bundle exec rake test:browser    # Chromium headless (BROWSER_PATH já definido na imagem)
docker compose run --rm dev bundle exec rubocop
docker compose run --rm dev bundle exec rake audit
```

Antes de abrir um PR:

1. `rubocop` sem ofensas.
2. Suítes afetadas verdes (`test:unit` sempre; suítes com banco quando houver SQL, transações ou RLS).
3. `docs/STATUS.md` atualizado com o que foi implementado, testado e o que permanece limitado.
4. Decisões arquiteturais novas registradas em `docs/DECISOES.md`.

## Padrões de código

- Ruby sem framework de aplicação e sem ORM. Domínio e aplicação não dependem de HTTP, banco ou
  bibliotecas de infraestrutura.
- Dependências por construtor; composição em vez de herança; sem monkey patches, sem estado global
  mutável e sem metaprogramação para dados recebidos.
- Dinheiro em centavos inteiros (`Locentra::Domain::Money`); instantes em UTC; regras locais com
  fuso IANA da organização.
- SQL explícito e parametrizado; ordenação e filtros dinâmicos somente por allowlist.
- Toda consulta a dados de tenant ocorre dentro de transação com contexto de organização definido.
