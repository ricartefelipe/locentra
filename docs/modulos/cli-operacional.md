# Módulo: CLI operacional (`bin/locentra`)

Cobre RF-40 (CLI operacional com os mesmos casos de uso e permissões) e complementa RF-36
(credenciais de integração com escopos, validade e revogação) e RF-41 (auditoria). Não há migration:
o módulo usa `api_credentials` (tipo `cli`, migration 0005), `jobs`/`job_attempts` (0004) e
`audit_events` (0001).

Comandos administrativos de banco (migrations, status, seed) continuam separados em
`bin/locentra-admin`, que usa `MIGRATION_DATABASE_URL`. A CLI operacional nunca usa essa credencial.

## Camadas

| Camada | Arquivos |
|---|---|
| Aplicação | `application/jobs.rb` (`Jobs::ListFailures`, `Jobs::RetryJob`, `Jobs::ErrorText`), `application/integrations.rb` (`WhoAmI`; filtro `kind:` em `AuthenticateCredential`), `GetReservation#by_reference`, `GetAsset#by_reference`, filtro `skus:` em `CheckAvailability` |
| Persistência | `Jobs::Queue#lock`, `CredentialRepository#find`, `AvailabilityRepository#product_ids_by_sku`; `AccessRepository#active_credential` passa a devolver o tipo e, como `CredentialRepository#find_active`, exige organização ativa; `ReservationRepository#search` aceita `customer_names:`; `Jobs::Queue` identifica cada tentativa por `attempt_id` |
| Interface | `interfaces/cli/operational.rb` (entrada, autenticação, erros e códigos de saída), `invocation.rb` (comandos, opções e ajuda), `commands.rb` (execução e apresentação), `token_source.rb` (origem da credencial), `output.rb` (redação, formatação humana e JSON) |
| Executável | `bin/locentra` |
| Composição | `System#build_cli_use_cases` (`whoami`, `list_failed_jobs`, `retry_job`) |

Os demais comandos usam casos de uso já existentes: `get_organization`, `check_availability`,
`list_reservations`, `get_reservation`, `get_customer`, `get_asset`, `reconcile_payments` e `finance`
(relatório de conciliação).

## Identidade e credencial

1. A credencial é criada na interface web em **Usuários e permissões > Credenciais de integração**,
   tipo **CLI operacional**. Os escopos são permissões da matriz (`Domain::Identity::PERMISSIONS`) e não
   podem exceder as do criador; a validade é de 1 a 365 dias; o segredo aparece uma única vez e o banco
   guarda somente o SHA-256. Credenciais `cli` não exigem o recurso `api` do plano.
2. O token é lido de `LOCENTRA_TOKEN` ou do arquivo indicado em `--token-file CAMINHO` (que tem
   precedência). O arquivo é aberto sem seguir links simbólicos e verificado pelo descritor aberto:
   arquivo regular, do usuário efetivo, sem permissão para grupo e outros (`chmod 600` ou `400`), até
   512 bytes. O token **não** é aceito como argumento: `--token` é recusado com código 64 e abreviações
   de opções estão desativadas (`--tok...` não vira `--token-file`).
3. `AuthenticateCredential#call(token, kind: "cli")` verifica o formato, o hash, a validade, a revogação e
   a situação da organização (somente `active`) e devolve um `Actor` do tipo `cli`. Credencial de outro tipo é tratada como inválida e não tem o último
   uso atualizado. A API HTTP passou a chamar o mesmo caso de uso com `kind: "api"`: token da CLI na API
   recebe 401 e token da API na CLI recebe 77.
4. Em toda transação, `UnitOfWork#run` recarrega a credencial pelo identificador (não revogada, não
   expirada, da mesma organização, do mesmo tipo do ator e com a organização ativa) e substitui os escopos
   pelos do banco antes de autorizar. Revogação, expiração, redução de escopos ou suspensão/encerramento da
   organização valem na operação seguinte, como nos vínculos de usuários. A regra vale também para a API.
5. A auditoria registra `actor_type = 'cli'`, `actor_id` = identificador da credencial e `request_id` =
   UUID gerado para cada execução da CLI.
6. Banco: `DATABASE_URL` com o papel `locentra_app` (sem superuser e sem `BYPASSRLS`; RLS forçada). Na
   montagem, a CLI abre a primeira conexão e confere o papel no próprio banco, com ou sem
   `MIGRATION_DATABASE_URL` no ambiente: superusuário ou `BYPASSRLS`, proprietário de tabelas do schema
   (credencial de migrations, inclusive por herança de papel) e papel com políticas `USING (true)` (papel do
   worker, que lê a fila de todas as organizações) são recusados com código 2, antes da autenticação. Se
   `DATABASE_URL` for igual a `MIGRATION_DATABASE_URL` ou usar o mesmo usuário, a recusa ocorre sem
   conectar. URL que o libpq não consegue interpretar também é erro de configuração (2), com a senha
   mascarada. O pool da CLI tem 2 conexões e nome `cli`.

## Comandos

| Comando | Caso(s) de uso | Escopo(s) | Observações |
|---|---|---|---|
| `whoami` | `whoami` | nenhum além de credencial válida | Credencial (nome, tipo, validade, último uso), organização e escopos atuais |
| `availability --inicio I --fim F [--filial F] [--produto P]` | `get_organization`, `check_availability` | `availability.read` | Filial por código ou id (padrão: a única filial ativa); produtos por SKU ou id, repetidos ou separados por vírgula (padrão: todos os ativos). SKU ou id inexistente é erro de validação |
| `reservations list [--situacao S] [--cliente ID] [--busca T] [--de I] [--ate I] [--ordem=O] [--limite N] [--deslocamento N]` | `list_reservations` | `reservations.read` (+ `customers.read` para o nome do cliente) | `--de`: reservas que terminam depois do instante; `--ate`: que começam antes. Ordens: `-starts_at` (padrão), `starts_at`, `-created_at`, `created_at`, `code` (use `--ordem=-created_at`). Limite de 1 a 100. Sem `customers.read`, a regra é aplicada em `ListReservations` (vale para qualquer interface): o nome não é devolvido (a coluna mostra o identificador do cliente e o JSON omite `customer_name`) e `--busca` considera apenas o código da reserva |
| `reservations show CÓDIGO\|ID` | `get_reservation` (`by_reference`), `get_customer` | `reservations.read` (+ `customers.read` para o nome do cliente) | Sem `customers.read`, o cliente aparece apenas pelo identificador |
| `asset show PATRIMÔNIO\|ID` | `get_asset` (`by_reference`) | `catalog.read` | Situação física (situação, condição, filial, bloqueio operacional por inspeção pendente ou ordem de manutenção ativa, se aceita novas alocações), alocações e bloqueios, histórico |
| `finance reconcile` | `reconcile_payments`, `finance#report` | `finance.write` e `finance.read` | `finance.read` é conferido antes de executar, para não conciliar sem poder exibir o relatório. Correções seguras aplicadas pela conciliação são auditadas como `cli` |
| `jobs failures [--limite N]` | `list_failed_jobs` | `jobs.manage` | Tarefas `dead` da organização, mais recentes primeiro (padrão 50, máximo 100) |
| `jobs retry ID` | `retry_job` | `jobs.manage` | Bloqueia a tarefa (`FOR UPDATE`), exige situação `dead`, volta a `pending` com tentativas zeradas e audita `job.retried` (tipo, tentativas anteriores e erro redigido). Tarefa em outra situação: conflito (69). Em `job_attempts`, a numeração continua após o reprocessamento, tentativas ainda abertas (lease vencido sem retorno do worker) são encerradas como `lease_lost` e cada tentativa é encerrada pelo próprio identificador, sem alterar tentativas anteriores |

`jobs failures` exige `jobs.manage` (e não um escopo de leitura) porque a mensagem de erro de uma
tarefa pode revelar detalhes de integrações. Tarefas de outra organização ou sem organização não são
visíveis: filtro explícito por `organization_id` e RLS.

### Instantes

`--inicio`, `--fim`, `--de` e `--ate` aceitam:

- ISO 8601 com fuso: `2026-03-10T08:00:00Z`, `2026-03-10T05:00-03:00`;
- data e hora locais da organização (fuso IANA): `2026-03-10T05:00`;
- somente data (`--de`/`--ate` e também `--inicio`/`--fim`): início do dia local, `2026-03-10`.

Horários locais inexistentes no fuso são rejeitados e ambíguos resolvem para a primeira ocorrência
(ADR-005). Períodos são `[início, fim)` em UTC.

## Saída

- **Humana** (padrão): português, horários no fuso da organização (indicado na saída), valores em reais.
  Caracteres de controle vindos de dados gravados (sequências de escape, quebras de linha) são trocados
  por espaço, para não alterar o terminal nem forjar linhas.
- **JSON** (`--json`): objeto único no stdout, chaves fixas por comando, instantes em ISO 8601 UTC e
  valores monetários como na API v1 (`amount_cents`, `currency`, `formatted`). A redação de segredos é
  aplicada a cada chave e valor antes da serialização, de modo que o documento é sempre JSON válido.

| Comando | Chaves de primeiro nível |
|---|---|
| `whoami` | `actor_type`, `organization` (`id`, `name`, `slug`, `time_zone`), `credential` (`id`, `name`, `kind`, `created_at`, `expires_at`, `last_used_at`, `scopes`) |
| `availability` | `branch` (`id`, `code`, `name`), `period`, `time_zone`, `data[]` (`product_id`, `sku`, `name`, `tracking`, `available`, `total`) |
| `reservations list` | `data[]` (campos da reserva da API v1 + `status_label` e, com `customers.read`, `customer_name`), `pagination` (`limit`, `offset`, `total`, `next_offset`) |
| `reservations show` | `reservation` (+ `notes`), `customer` (`id` e, com `customers.read`, `name`), `branch`, `items[]`, `allocations` (`assets[]`, `stock[]`) |
| `asset show` | `asset` (`status`, `condition`, `branch`, `unavailable_until`, `operational_hold`, `allocatable`, `operationally_blocked`, …), `product`, `allocations[]`, `history[]` |
| `finance reconcile` | `report` (`id`, `provider`, `status`, `window_start`, `started_at`, `finished_at`, `summary`, `error`), `items[]` |
| `jobs failures` | `data[]` (`id`, `kind`, `attempts`, `max_attempts`, `last_error`, `correlation_id`, `created_at`, `updated_at`, `finished_at`) |
| `jobs retry` | `job` (`id`, `kind`, `status`, `previous_attempts`) |

Erros vão para o stderr: em texto (`erro: ...`) ou, com `--json`, como
`{"error":{"code","message","details","exit_code","request_id"}}`. `details.fields` traz os erros
por campo de validação e `details.shortages` as faltas de disponibilidade.

## Códigos de saída

| Código | Significado | Exemplos |
|---|---|---|
| 0 | Sucesso | |
| 1 | Erro de negócio ou validação | instante inválido, SKU inexistente, reserva ou tarefa inexistente ou de outra organização (`not_found`), nenhuma conta de provedor ativa |
| 2 | Configuração ou conexão | credencial ausente, arquivo de credencial inseguro, `DATABASE_URL` ausente, inválida ou com papel inadequado (migrations, worker, superusuário, `BYPASSRLS`), banco inacessível, tempo de espera do pool esgotado |
| 64 | Uso incorreto | comando, subcomando ou opção desconhecidos, argumento ausente ou excedente, `--token` |
| 69 | Indisponível ou conflito | tarefa que não está `dead`, conflito de estado, provedor de pagamentos fora do ar (relatório `failed` é exibido) |
| 70 | Erro interno inesperado | registrado no log (stderr) com o `request_id` |
| 77 | Permissão negada | credencial inválida, revogada, expirada, de outro tipo ou de organização suspensa ou encerrada; escopo insuficiente |
| 130 | Interrompido (Ctrl+C) | |

## Segredos e logs

- Toda a saída (stdout, stderr e log) passa por `CLI::Redactor`: a credencial em uso, as senhas das URLs
  de banco do ambiente (`DATABASE_URL`, `MIGRATION_DATABASE_URL`, `WORKER_DATABASE_URL`), qualquer token
  `lcn_...` e senhas em URLs ou parâmetros de conexão (`password=...`) são substituídos por `[omitido]`.
  Texto humano é redigido linha a linha; JSON (stdout, erros e log) é redigido valor a valor antes da
  serialização. Valores gravados com aparência de segredo (por exemplo, observações com `password=...`)
  também são mascarados. Mensagens de erro de uso não repetem valores informados.
- A CLI não exibe a dica do token nem o documento do cliente.
- `last_error` das tarefas passa por `Jobs::ErrorText.redact` na aplicação, tanto na listagem quanto na
  auditoria: tokens `lcn_...`, chaves do Asaas (`$aact_...`), credenciais em URLs, parâmetros de consulta e
  pares sensíveis em `chave=valor`, `chave: valor` ou JSON, inclusive com nomes compostos (`access_token`,
  `client_secret`, `x-api-key`), valores entre aspas e cabeçalhos com esquema (`Authorization: Bearer ...`).
- O log estruturado (JSON por linha) vai para o stderr com o nível de `LOCENTRA_CLI_LOG_LEVEL`
  (padrão `warn`), sem token e com o `request_id` da execução. Erros internos são registrados no
  nível `error`.

## Execução

Com Docker Compose, usando o ambiente da aplicação (papel `locentra_app`) e passando o token pelo
ambiente do processo atual (`-e LOCENTRA_TOKEN` sem valor não coloca o segredo na linha de comando):

```bash
read -rs LOCENTRA_TOKEN && export LOCENTRA_TOKEN
docker compose run --rm -e LOCENTRA_TOKEN web ruby bin/locentra whoami
docker compose run --rm -e LOCENTRA_TOKEN web ruby bin/locentra availability --inicio 2026-03-10T08:00 --fim 2026-03-11T08:00 --produto CAM-01
docker compose run --rm -e LOCENTRA_TOKEN web ruby bin/locentra reservations list --situacao confirmed --de 2026-03-01 --json
docker compose run --rm -e LOCENTRA_TOKEN web ruby bin/locentra jobs retry 01960f3e-0000-7000-8000-000000000001
```

Com arquivo: `install -m 600 /dev/null ~/.locentra-token`, grave o token no arquivo e use
`bin/locentra --token-file ~/.locentra-token whoami`. Em sistemas de arquivos sem permissões POSIX
(alguns volumes montados), a verificação do arquivo falha; use `LOCENTRA_TOKEN`.

## Testes

| Arquivo | Cobertura |
|---|---|
| `test/cli/identity_test.rb` | `whoami` humano e JSON; credencial revogada, expirada, inexistente, malformada e do tipo `api` (77, sem atualizar o último uso); organização suspensa ou encerrada (77, inclusive para ator já autenticado); escopo insuficiente (77); revalidação da credencial e dos escopos pela UnitOfWork após a autenticação; regras do arquivo de credencial; credencial ausente, credencial de migrations, banco inacessível (2); URL malformada repetida pelo libpq com a senha mascarada (2, sem erro interno); papel do proprietário e do worker recusados sem `MIGRATION_DATABASE_URL` (2); erros de uso sem repetir valores (64); ajuda e versão |
| `test/cli/availability_test.rb` | Saída humana com horário local e filtro por SKU; JSON com ISO 8601, filial por código e id, produtos mistos, período semiaberto; erros de validação (1); filial obrigatória com várias filiais (64); escopo (77) |
| `test/cli/reservations_test.rb` | Listagem humana e JSON com situação, cliente, janela por data local, busca, ordenação e paginação; validações (1); detalhes por código e id, humano e JSON; nome do cliente (listagem, busca e detalhes) somente com `customers.read`; observações com `password=...` em JSON válido; neutralização de caracteres de controle; não encontrado e isolamento entre organizações |
| `test/cli/assets_test.rb` | Situação física, bloqueios, ordem de manutenção e histórico (humano); JSON por id; não encontrado, isolamento e escopo |
| `test/cli/finance_test.rb` | Conciliação humana com correção de webhook perdido auditada como `cli`; JSON; sem conta (1); `finance.read`/`finance.write` (77, sem executar); provedor fora do ar (69, relatório `failed`, chave não exibida) |
| `test/cli/jobs_test.rb` | Tarefas mortas humano e JSON com erro redigido (inclusive `Authorization: Bearer`, `access_token`, `client_secret` e erro terminado em `password=...`, com JSON válido); reprocessamento humano e JSON auditado com `actor_type = 'cli'`; segunda tentativa em conflito (69); sem `jobs.manage` (77, sem auditoria); isolamento entre organizações; identificador e limite inválidos (1) |
| `test/cli/redaction_test.rb` | `Redactor` e `SafeOutput` sem banco: texto, JSON indentado e compacto e log; propriedade: qualquer combinação de fragmentos sensíveis e caracteres de sintaxe produz JSON válido e sem segredos |
| `test/cli/subprocess_test.rb` | `bin/locentra` como processo separado (relógio real, System próprio): JSON, `--token-file`, permissão insegura (2) e códigos de saída no shell |
| `test/integration/jobs_lookups_test.rb` | `whoami`, buscas por código/patrimônio, filtro por SKU, listagem de reservas sem `customers.read` e tarefas mortas com atores da equipe (papel recarregado do banco) |
| `test/integration/worker_test.rb` | Reprocessamento: numeração contínua em `job_attempts`, tentativa abandonada encerrada como `lease_lost` e nenhuma tentativa anterior sobrescrita |
| `test/http/api_test.rb` | Credencial `cli` recusada pela API (401) sem atualizar o último uso; credenciais de organização suspensa recusadas (401) |
| `test/unit/application/base_test.rb` | UnitOfWork recusa ator cujo tipo difere do tipo da credencial |
| `test/unit/application/jobs_error_text_test.rb` | Redação de `last_error`: cabeçalhos com esquema, nomes compostos, valores entre aspas, chaves do provedor e texto comum preservado |

## Limitações

- A CLI expõe somente os comandos listados acima; operações de escrita além de `finance reconcile` e
  `jobs retry` (reservas, retiradas, devoluções, pagamentos) continuam na interface web e na API.
- `jobs failures` não tem deslocamento: mostra as `--limite` tarefas mortas mais recentes (até 100).
- Não há leitura interativa do token nem integração com cofres de segredos; o operador fornece o token
  por variável de ambiente ou arquivo protegido.
- A verificação do arquivo de credencial depende de permissões POSIX e do usuário efetivo do processo.
