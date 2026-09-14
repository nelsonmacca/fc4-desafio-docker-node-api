# Do Dev à Produção: Containerizando uma API Node.js

Projeto: Full Cycle 4.0 — Docker e Containers
Entrega: containerização completa da API de feature flags (Node.js + TypeScript + PostgreSQL) em dois ambientes, desenvolvimento e produção.

## Sobre a entrega

Esta entrega adiciona toda a camada de containers de uma API REST de feature flags escrita em Node.js + TypeScript com persistência em PostgreSQL, sem alterar o código da aplicação. Um único `Dockerfile` multi-stage define os estágios `dev` (dependências completas e hot reload com `tsx watch`), `build` (compilação do TypeScript para `dist/`) e `production` (somente `dist/` e dependências de produção, usuário não-root, `HEALTHCHECK` e labels OCI). O ambiente de desenvolvimento é orquestrado pelo `compose.yaml`, com healthcheck do banco, migrações automáticas via serviço one-shot, `develop.watch` para sincronização de código e um Adminer opcional sob o profile `tools`.

A imagem de produção foi construída com Buildx a partir do estágio `production` para `linux/amd64` e `linux/arm64`, publicada no Docker Hub nas tags `1.0.0` e `latest` (mesmo digest) com attestations de SBOM e provenance. O `compose.prod.yaml` consome exclusivamente essa imagem publicada, com restart policy, limites de CPU e memória, volume nomeado e sem bind mounts. A análise do Docker Scout, salva em `reports/scout-cves.txt`, encerra com 0 CRITICAL, 0 HIGH, 2 MEDIUM e 0 LOW após o hardening da imagem (atualização do OpenSSL do sistema e remoção do npm do runtime).

## Arquitetura da solução

```text
Desenvolvimento (compose.yaml, projeto flags-api)

  .env ──► db (postgres:17.11-alpine3.24, healthcheck pg_isready, volume pgdata)
             │ service_healthy
             ▼
           migrate (build target dev, one-shot: npm run db:migrate, exit 0)
             │ service_completed_successfully
             ▼
           app (build target dev, CMD npm run dev, porta 3000, develop.watch)

           adminer (profile tools, http://localhost:8081) ── opcional

Produção (compose.prod.yaml, projeto flags-api-prod)

  .env ──► db (postgres:17.11-alpine3.24, healthcheck, volume pgdata, limites)
             │ service_healthy
             ▼
           migrate (imagem publicada 1.0.0, one-shot: node dist/db/migrate.js)
             │ service_completed_successfully
             ▼
           app (imagem publicada 1.0.0, HEALTHCHECK da imagem, porta 3000,
                restart unless-stopped, limites de CPU/memória)
```

Papéis dos serviços:

- `db`: PostgreSQL com versão fixada. Só é considerado pronto quando `pg_isready` responde via TCP, evitando o falso positivo do servidor temporário do `initdb`. Dados persistem em volume nomeado (`pgdata`).
- `migrate`: serviço de execução única. Espera o `db` ficar `healthy`, aplica as migrações pendentes (idempotente) e termina com exit code 0. Não tem restart policy.
- `app`: a API. Só inicia depois que o `db` está `healthy` e o `migrate` concluiu com sucesso, garantindo que `GET /flags` responda 200 na primeira subida.
- `adminer`: interface web para o banco, disponível somente com `--profile tools`.

Os dois ambientes compartilham a mesma imagem entre `migrate` e `app`. Em desenvolvimento é a imagem `flags-api:dev` construída localmente; em produção é a imagem publicada no Docker Hub. Os nomes de projeto são distintos (`flags-api` e `flags-api-prod`), então containers, volumes e networks não colidem.

## Imagem no Docker Hub

- Repositório: <https://hub.docker.com/r/nelsonmacca/fc4-desafio-docker-node-api>
- Imagem: `nelsonmacca/fc4-desafio-docker-node-api:1.0.0`
- Tag adicional: `latest` (aponta para o mesmo digest da `1.0.0`)
- Digest do image index (manifest list): `sha256:b21be5df84c0b7d9154cc3ba7cc5c18a86caf3b935f3f4f8f7ce9e0a75d6d63d`
- Manifest `linux/amd64`: `sha256:be7ce92584d296ade8b0d1bf1d6357811e688ae843e26afa28fd2798082e231f`
- Manifest `linux/arm64`: `sha256:401d5ac31ebb57c3e0d972e6b86389ec85f9e910cbdefbb686017a39e00a81d1`
- Revision (commit de origem, label OCI): `b99b90c7d7ac6d628f2bb0c6081c8a97e027a120`
- Created (label OCI): `2026-09-14T18:45:56Z`

```bash
docker pull nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

Plataformas publicadas no mesmo image index:

- `linux/amd64`
- `linux/arm64`

Comparação de tamanho (`docker image ls`, Docker Desktop com containerd image store):

| Imagem | Estágio | Tamanho reportado por `docker image ls` |
| --- | --- | --- |
| `flags-api:dev` (build local) | `dev` | ~291 MB |
| `nelsonmacca/fc4-desafio-docker-node-api:1.0.0` | `production` | ~313 MB |

O valor de ~313 MB é o que `docker image ls` exibe no Docker Desktop com containerd image store após `docker pull`, e ele inclui o conteúdo do image index multi-arch e das attestations puxadas junto. O conteúdo efetivo da variante `linux/amd64` (`docker image inspect`, campo `Size`) fica em torno de 61 a 62 MB, o mesmo valor que o Docker Scout reporta como `size 62 MB`. Para o critério do desafio vale o número exibido por `docker image ls`, que permanece abaixo dos 350 MB exigidos.

A diferença entre `dev` e `production` vem da composição de cada estágio: a `dev` carrega `devDependencies` (TypeScript, tsx, tipos), `tsconfig.json`, `src/` e o npm; a `production` contém apenas `dist/`, as dependências de produção (`express`, `pg`, `dotenv` e transitivas) e o runtime Node, sem npm.

## Decisões técnicas

### Dockerfile multi-stage

Um único `Dockerfile` na raiz, com uma `ARG NODE_VERSION=22.23.2-alpine3.24` compartilhada por todos os estágios:

- `dev`: parte de `node:22.23.2-alpine3.24`, define `WORKDIR /app` com posse do usuário `node`, copia `package.json` e `package-lock.json`, roda `npm ci` (com `devDependencies`, pois `NODE_ENV=development`), copia `tsconfig.json` e `src/`, e executa `npm run dev` (`tsx watch`). Roda como usuário `node` (UID 1000).
- `build`: deriva de `dev` (`FROM dev AS build`) e executa apenas `npm run build`, gerando `/app/dist`. Reaproveita todas as camadas do `dev`, sem reinstalar dependências.
- `production`: parte novamente de `node:22.23.2-alpine3.24`, declara as labels OCI, atualiza `libssl3`/`libcrypto3`, copia somente os manifestos, roda `npm ci --omit=dev`, remove o npm, copia `dist/` do estágio `build` e define `HEALTHCHECK` e `CMD ["node", "dist/server.js"]`. Nem `tsconfig.json`, nem `src/`, nem TypeScript entram nesse estágio.

### Imagem base de produção

Escolhida: `node:22.23.2-alpine3.24` (imagem oficial do Node, tag com patch do Node e da Alpine fixados).

Alternativas consideradas (tamanhos comprimidos do manifest `linux/amd64` no Docker Hub, medidos em 2026-09-14):

| Imagem base | Tamanho comprimido | Observações |
| --- | --- | --- |
| `node:22.23.2-alpine3.24` (escolhida) | ~57,7 MB | Node oficial, musl, usuário `node` (UID 1000), shell e `apk` disponíveis para inspeção e correções |
| `node:22.23.2-bookworm-slim` | ~79,9 MB | Node oficial, glibc e utilitários Debian; ~1,4x o tamanho da Alpine sem benefício para esta aplicação |
| `gcr.io/distroless/nodejs22-debian12` | ~52,6 MB | Menor superfície (sem shell, sem npm), porém sem tag de patch do Node (pin só por digest), sem usuário `node` UID 1000 e sem npm para o `npm ci --omit=dev` no próprio estágio |

Justificativa:

- Tamanho: a Alpine é ~22 MB menor que a `bookworm-slim` e apenas ~5 MB maior que a distroless.
- Simplicidade: a mesma `ARG NODE_VERSION` serve aos três estágios, e a imagem traz `apk` para atualizar pacotes do sistema quando o Scout aponta CVEs na base.
- Node oficial: manutenção e cadência de patches da própria imagem oficial, com tag de patch explícita (sem `latest`).
- Usuário `node`: a imagem oficial já traz o usuário `node` (UID/GID 1000), o mesmo usado no estágio `dev`, mantendo permissões consistentes entre ambientes.
- Compatibilidade com as dependências: `express`, `pg` e `dotenv` são JavaScript puro, sem binários nativos, então não dependem de glibc.

Ajustes aplicados no estágio `production`:

- O OpenSSL do sistema (`libssl3` e `libcrypto3`) é atualizado com `apk upgrade`, resolvendo as CVEs CRITICAL apontadas pelo Scout na base.
- O npm é usado somente durante o build (`npm ci --omit=dev`) e removido da imagem final (`/usr/local/lib/node_modules/npm`, `/usr/local/bin/npm` e `/usr/local/bin/npx`), eliminando as dependências vulneráveis embutidas no npm e reduzindo a superfície de ataque.
- O runtime executa diretamente `node dist/server.js` em exec form. O entrypoint da imagem oficial faz `exec` do comando, então o processo Node é o PID 1 e recebe `SIGTERM` diretamente.

### Estratégia de cache

- `package.json` e `package-lock.json` são copiados antes do restante do código em todos os estágios. A camada de `npm ci` só é invalidada quando um desses dois arquivos muda; alterações em `src/` reaproveitam a camada de dependências.
- `npm ci` (e não `npm install`) instala exatamente o que está no lockfile, sem modificá-lo.
- `RUN --mount=type=cache,target=/home/node/.npm,uid=1000,gid=1000` persiste o cache do npm entre builds no BuildKit. Mesmo quando a camada precisa ser refeita, os pacotes já baixados são reutilizados. `uid`/`gid` garantem que o usuário `node` consiga escrever no cache.
- O estágio `build` deriva do `dev`, então `--target dev` e `--target build` compartilham todas as camadas até a última `COPY`. O estágio `production` usa o mesmo mount de cache do npm.
- O `.dockerignore` exclui `node_modules`, `dist`, `.git`, `.env`, arquivos compose, documentação e `reports/`, mantendo o contexto de build pequeno e evitando invalidação de cache por arquivos irrelevantes.

### Migrações

As migrações não rodam sozinhas na aplicação, então cada compose declara um serviço one-shot `migrate` que usa a mesma imagem do `app`:

- Desenvolvimento: `command: ["npm", "run", "db:migrate"]` (executa `tsx src/db/migrate.ts`).
- Produção: `command: ["node", "dist/db/migrate.js"]` (runner compilado, pois a imagem de produção não contém npm nem tsx).
- O `migrate` depende do `db` com `condition: service_healthy`, não tem restart policy e termina com exit code 0.
- O `app` depende do `migrate` com `condition: service_completed_successfully`, além de depender do `db` com `service_healthy`. A API só sobe com o schema aplicado.
- O runner é idempotente: registra as migrações aplicadas na tabela `schema_migrations` e ignora as já executadas.

## Como rodar (desenvolvimento)

Pré-requisitos: Docker Desktop (ou Docker Engine) recente com Compose v2 e BuildKit.

```bash
cp .env.example .env
docker compose up
```

No Windows PowerShell:

```powershell
Copy-Item .env.example .env
docker compose up
```

O que acontece: o `db` sobe e fica `healthy`, o `migrate` aplica as migrações e termina, e o `app` inicia com `tsx watch`. A API responde em <http://localhost:3000>.

Verificação:

```bash
curl http://localhost:3000/health
curl http://localhost:3000/flags
```

- `GET /health` retorna 200 com `{"status":"ok","db":"up"}` quando a conexão com o banco está saudável (503 caso contrário).
- `GET /flags` retorna 200 com a lista de flags (vazia na primeira subida).

Para subir em segundo plano use `docker compose up -d`; para encerrar, `docker compose down` (adicione `-v` para descartar o volume do banco).

### Watch

```bash
docker compose watch
```

ou:

```bash
docker compose up --watch
```

Regras configuradas em `develop.watch` do serviço `app`:

| Caminho | Ação | Efeito |
| --- | --- | --- |
| `src/` | `sync` | Arquivo copiado para `/app/src` no container; o `tsx watch` reinicia o processo. Sem rebuild. |
| `package.json` | `rebuild` | Imagem reconstruída (camada `npm ci` invalidada) e container recriado. |
| `package-lock.json` | `rebuild` | Idem: o lock pode mudar sem alterar o `package.json`. |
| `tsconfig.json` | `sync+restart` | Arquivo copiado e container reiniciado (lido apenas na inicialização). |

Não há bind mount de código-fonte: o hot reload é feito exclusivamente pelo `develop.watch`.

### Ferramentas

```bash
docker compose --profile tools up -d
```

Sobe também o Adminer em <http://localhost:8081>. O serviço só é ativado com `--profile tools`; um `docker compose up` comum não o inicia.

Dados de conexão na tela de login do Adminer:

- Sistema: PostgreSQL
- Servidor: `db:5432` (pré-preenchido via `ADMINER_DEFAULT_SERVER`)
- Usuário, senha e banco: os valores de `DB_USER`, `DB_PASSWORD` e `DB_NAME` do seu `.env` (por padrão os do `.env.example`)

## Como rodar (produção)

Fluxo do avaliador (não há build local; a imagem `1.0.0` é puxada do Docker Hub):

```bash
cp .env.example .env
docker compose -f compose.prod.yaml up -d
```

No Windows PowerShell:

```powershell
Copy-Item .env.example .env
docker compose -f compose.prod.yaml up -d
```

O que acontece:

- O `compose.prod.yaml` não contém instrução `build`. Os serviços `migrate` e `app` usam `nelsonmacca/fc4-desafio-docker-node-api:1.0.0`.
- O `db` sobe e fica `healthy`; o `migrate` executa `node dist/db/migrate.js` e termina; o `app` sobe em seguida.
- O `app` herda o `HEALTHCHECK` da imagem e fica `healthy` após o `start_period` (10 s) e a primeira checagem bem-sucedida.
- Em produção real as variáveis viriam de um gerenciador de segredos; aqui o `.env` existe para permitir a subida local.

Estado dos serviços (`app` e `db` devem aparecer como `healthy`; `migrate` aparece como `Exited (0)`):

```bash
docker compose -f compose.prod.yaml ps
```

Testes:

```bash
curl http://localhost:3000/health
curl http://localhost:3000/flags
```

Encerramento:

```bash
docker compose -f compose.prod.yaml down
```

Para remover também o volume de dados do PostgreSQL:

```bash
docker compose -f compose.prod.yaml down -v
```

## Segurança e supply chain

### Usuário não-root

Desenvolvimento (com o ambiente no ar):

```bash
docker compose exec app id -u
```

Retorna `1000` (usuário `node`).

Produção, via metadados da imagem:

```bash
docker image inspect --format '{{ .Config.User }}' nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

Retorna `node`. Com o ambiente de produção no ar, também é possível confirmar no container em execução:

```bash
docker compose -f compose.prod.yaml exec app id -u
```

Retorna `1000`.

### HEALTHCHECK

O `HEALTHCHECK` está declarado na própria imagem `production`, não apenas no compose:

- Executa `node -e` com o módulo `http` nativo, sem `curl` ou `wget` (a Alpine não os traz e a imagem não os instala).
- Consulta `GET /health` em `127.0.0.1:${PORT}` (fallback 3000). Exit 0 somente para HTTP 2xx; exit 1 para erro de conexão, timeout ou status fora de 2xx (por exemplo 503 com banco indisponível).
- Parâmetros: `interval=30s`, `timeout=5s`, `start-period=10s`, `retries=3`.
- O `compose.prod.yaml` não redefine `healthcheck:`, então o Compose herda o da imagem e o usa para reportar `healthy` em `ps`.

Inspeção:

```bash
docker image inspect --format '{{ json .Config.Healthcheck }}' nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

Estado do container em produção:

```bash
docker inspect --format '{{ .State.Health.Status }}' flags-api-prod-app-1
```

### Labels OCI

```bash
docker image inspect --format '{{ json .Config.Labels }}' nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

Labels obrigatórias presentes na imagem:

| Label | Valor |
| --- | --- |
| `org.opencontainers.image.title` | `flags-api` |
| `org.opencontainers.image.description` | `API REST de CRUD de feature flags em Node.js + TypeScript com persistencia em PostgreSQL` |
| `org.opencontainers.image.version` | `1.0.0` |
| `org.opencontainers.image.source` | `https://github.com/nelsonmacca/fc4-desafio-docker-node-api` |

Labels extras, informadas no build via `--label`:

| Label | Valor |
| --- | --- |
| `org.opencontainers.image.revision` | `b99b90c7d7ac6d628f2bb0c6081c8a97e027a120` |
| `org.opencontainers.image.created` | `2026-09-14T18:45:56Z` |

### Multi-arch

```bash
docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

A saída mostra um `application/vnd.oci.image.index.v1+json` com digest `sha256:b21be5df84c0b7d9154cc3ba7cc5c18a86caf3b935f3f4f8f7ce9e0a75d6d63d` e quatro manifests:

- `linux/amd64`: `sha256:be7ce92584d296ade8b0d1bf1d6357811e688ae843e26afa28fd2798082e231f`
- `linux/arm64`: `sha256:401d5ac31ebb57c3e0d972e6b86389ec85f9e910cbdefbb686017a39e00a81d1`
- dois manifests `unknown/unknown` com `vnd.docker.reference.type: attestation-manifest`, um para cada plataforma, que carregam o SBOM e o provenance.

O mesmo comando com a tag `latest` retorna o mesmo digest de index:

```bash
docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:latest
```

### SBOM

O SBOM (SPDX, gerado pelo BuildKit com syft) está anexado como attestation a cada plataforma. Para exibi-lo:

```bash
docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0 --format '{{ json .SBOM }}'
```

Resumo por plataforma (quantidade de pacotes e ferramenta geradora):

```bash
docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0 --format '{{ range $p, $v := .SBOM }}{{ $p }}: {{ len $v.SPDX.packages }} pacotes ({{ index $v.SPDX.creationInfo.creators 1 }}){{ "\n" }}{{ end }}'
```

Saída obtida:

```text
linux/amd64: 105 pacotes (Tool: syft-v1.51.0)
linux/arm64: 105 pacotes (Tool: syft-v1.51.0)
```

### Provenance

O provenance (SLSA, gerado pelo BuildKit) registra a origem do build:

```bash
docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0 --format '{{ json .Provenance }}'
```

Resumo dos campos relevantes:

```bash
docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0 --format '{{ range $p, $v := .Provenance }}{{ $p }}: target={{ index $v.SLSA.buildDefinition.externalParameters.request.args "target" }} revision={{ index $v.SLSA.buildDefinition.externalParameters.request.args "label:org.opencontainers.image.revision" }} created={{ index $v.SLSA.buildDefinition.externalParameters.request.args "label:org.opencontainers.image.created" }}{{ "\n" }}{{ end }}'
```

Saída obtida:

```text
linux/amd64: target=production revision=b99b90c7d7ac6d628f2bb0c6081c8a97e027a120 created=2026-09-14T18:45:56Z
linux/arm64: target=production revision=b99b90c7d7ac6d628f2bb0c6081c8a97e027a120 created=2026-09-14T18:45:56Z
```

O provenance também registra `vcs:source` apontando para o repositório GitHub, `vcs:revision` com o mesmo commit, a imagem base `node:22.23.2-alpine3.24` resolvida por digest e os `build-arg` `APP_VERSION=1.0.0` e `APP_SOURCE`.

### Docker Scout

Relatório completo:

```bash
docker scout cves nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

Verificação do critério (CRITICAL com correção disponível):

```bash
docker scout cves --only-severity critical --only-fixed nelsonmacca/fc4-desafio-docker-node-api:1.0.0
```

Resultado final, salvo em [reports/scout-cves.txt](reports/scout-cves.txt):

| Severidade | Quantidade |
| --- | --- |
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 2 |
| LOW | 0 |

O comando `--only-severity critical --only-fixed` retorna `No vulnerable packages detected`.

CVEs remanescentes (ambas MEDIUM, no pacote `qs 6.15.3`, dependência transitiva do Express):

| CVE | Pacote | Versão corrigida | CVSS |
| --- | --- | --- | --- |
| CVE-2026-82562 | `qs 6.15.3` | 6.16.0 | 6.3 |
| CVE-2026-82417 | `qs 6.15.3` | 6.16.0 | 6.3 |

Justificativa: existe correção para as duas CVEs na versão `qs 6.16.0`. Porém, aplicá-la exigiria alterar o `package-lock.json` (o `npm ci` instala exatamente a versão fixada no lock), e o desafio proíbe modificar os arquivos da aplicação, incluindo o lockfile. Por isso as duas CVEs permanecem na imagem e ficam documentadas aqui. Nenhuma delas é CRITICAL ou HIGH, então o critério de aceite é atendido. O plano de mitigação, fora do escopo desta entrega, é atualizar o lock para `qs >= 6.16.0` e republicar a imagem.

### Hardening da imagem

- `libssl3` e `libcrypto3` atualizados via `apk upgrade` no estágio `production`, eliminando as CVEs CRITICAL do OpenSSL apontadas na imagem base.
- npm e npx removidos do runtime após o `npm ci --omit=dev`: as dependências vulneráveis embutidas no npm deixam de existir na imagem, e o container não tem como instalar pacotes em execução.
- Resultado: 0 CRITICAL e 0 HIGH no Scout após o hardening.
- Node executa como PID 1 (`CMD` em exec form, entrypoint da imagem oficial faz `exec`), recebendo `SIGTERM` diretamente.
- Graceful shutdown: o handler de `SIGTERM`/`SIGINT` em `src/server.ts` fecha o servidor HTTP e o pool do PostgreSQL, com timeout interno de 8 s. `docker stop` encerra o container antes do SIGKILL de 10 s.
- Usuário não-root (`node`, UID 1000) em `dev` e `production`; `.env` nunca entra na imagem (`.dockerignore`).
- PostgreSQL de produção sem `ports:` publicadas: acessível apenas pela network interna do Compose.

## Validação

Todos os comandos abaixo são executados a partir da raiz do repositório. Onde indicado, o ambiente correspondente deve estar no ar.

### Dockerfile e contexto de build

| Critério | Comando de verificação | Esperado |
| --- | --- | --- |
| Estágios `dev`, `build` e `production` | `grep -n '^FROM .* AS ' Dockerfile` | 3 linhas: `AS dev`, `AS build`, `AS production` |
| Nenhuma imagem com tag `latest` ou sem tag | `grep -n -e '^FROM' -e 'image:' Dockerfile compose.yaml compose.prod.yaml` | Todas as referências com tag fixada; nenhuma `:latest` |
| `.dockerignore` presente com `node_modules`, `dist`, `.git`, `.env` | `grep -n -e '^node_modules$' -e '^dist$' -e '^\.git$' -e '^\.env$' .dockerignore` | 4 linhas |
| Dependências com `RUN --mount=type=cache` | `grep -n '^RUN --mount=type=cache' Dockerfile` | 2 instruções (`dev` e `production`) |
| Build do estágio `dev` | `docker build --target dev -t flags-api:dev .` | Conclui sem erro |
| Build do estágio `production` | `docker build --target production -t flags-api:production .` | Conclui sem erro |

### Ambiente de desenvolvimento

| Critério | Comando de verificação | Esperado |
| --- | --- | --- |
| Subida sem passos manuais | `cp .env.example .env && docker compose up -d` | `db` healthy, `migrate` exit 0, `app` em execução |
| `GET /flags` retorna 200 | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/flags` | `200` |
| `GET /health` retorna 200 | `curl -s http://localhost:3000/health` | `{"status":"ok","db":"up"}` |
| `db` com healthcheck | `grep -n -A6 'healthcheck:' compose.yaml` e `docker compose ps db` | Healthcheck `pg_isready`; status `healthy` |
| `app` depende de `db` com `service_healthy` | `grep -n -B3 'condition:' compose.yaml` | Em `app`: `db: condition: service_healthy` e `migrate: condition: service_completed_successfully` |
| Watch: `src/` sincroniza sem rebuild | `docker compose watch` e editar um arquivo em `src/` | Log de sync e reinício do `tsx watch`, sem rebuild |
| Watch: `package.json` dispara rebuild | `docker compose watch` e editar `package.json` (reverter em seguida) | Log de rebuild e recriação do `app` |
| Profile `tools` sobe o Adminer | `docker compose --profile tools up -d && curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081` | `200` |
| UID diferente de 0 | `docker compose exec app id -u` | `1000` |
| `.env` ignorado e `.env.example` versionado | `git check-ignore .env && git ls-files .env.example` | `.env` e `.env.example` impressos, respectivamente |
| Migrações aplicadas automaticamente | `docker compose ps -a migrate` | `Exited (0)` |
| Encerrar o ambiente | `docker compose down` (ou `down -v`) | Containers removidos |

### Imagem de produção e Docker Hub

| Critério | Comando de verificação | Esperado |
| --- | --- | --- |
| Plataformas `linux/amd64` e `linux/arm64` | `docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0` | Manifests `linux/amd64` e `linux/arm64` |
| Attestations de SBOM e provenance | Mesmo comando acima | Dois manifests `attestation-manifest`, um por plataforma |
| SBOM legível | `docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0 --format '{{ json .SBOM }}'` | Documento SPDX por plataforma |
| Provenance legível | `docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:1.0.0 --format '{{ json .Provenance }}'` | Documento SLSA com `target=production` |
| Tags `1.0.0` e `latest` no mesmo digest | `docker buildx imagetools inspect nelsonmacca/fc4-desafio-docker-node-api:latest` | `Digest: sha256:b21be5df84c0...` (igual ao da `1.0.0`) |
| Tamanho <= 350 MB | `docker pull --platform linux/amd64 nelsonmacca/fc4-desafio-docker-node-api:1.0.0 && docker image ls nelsonmacca/fc4-desafio-docker-node-api` | ~313 MB |
| `User` não-root | `docker image inspect --format '{{ .Config.User }}' nelsonmacca/fc4-desafio-docker-node-api:1.0.0` | `node` |
| `HEALTHCHECK` configurado | `docker image inspect --format '{{ json .Config.Healthcheck }}' nelsonmacca/fc4-desafio-docker-node-api:1.0.0` | Teste `node -e ...` em `/health` |
| Labels OCI (4 obrigatórias) | `docker image inspect --format '{{ json .Config.Labels }}' nelsonmacca/fc4-desafio-docker-node-api:1.0.0` | `title`, `description`, `version`, `source` presentes |
| Container `healthy` pelo `HEALTHCHECK` da imagem | `docker compose -f compose.prod.yaml ps app` | `healthy` |
| `docker stop` em menos de 10 s | `time docker stop flags-api-prod-app-1` (com o ambiente de produção no ar) | Encerra em poucos segundos, sem esperar o SIGKILL |

### Relatório do Docker Scout

| Critério | Comando de verificação | Esperado |
| --- | --- | --- |
| Relatório completo salvo | `cat reports/scout-cves.txt` | Saída completa do `docker scout cves` da imagem `1.0.0` |
| Zero CRITICAL com correção disponível | `docker scout cves --only-severity critical --only-fixed nelsonmacca/fc4-desafio-docker-node-api:1.0.0` | `No vulnerable packages detected` |
| HIGH e CRITICAL sem fix documentadas | Seção "Docker Scout" deste README | 0 HIGH e 0 CRITICAL; 2 MEDIUM justificadas |

### Ambiente de produção

| Critério | Comando de verificação | Esperado |
| --- | --- | --- |
| Sem instrução `build` | `grep -n '^\s*build:' compose.prod.yaml` | Nenhuma linha (exit code 1) |
| Imagem do Docker Hub pela tag semver | `grep -n 'fc4-desafio-docker-node-api' compose.prod.yaml` | `nelsonmacca/fc4-desafio-docker-node-api:1.0.0` |
| Restart policy em `app` e `db` | `grep -n 'restart:' compose.prod.yaml` | `unless-stopped` nos dois serviços |
| Limites de CPU e memória | `grep -nA4 'resources:' compose.prod.yaml` | `cpus` e `memory` em `app` e `db` |
| Limites aplicados nos containers | `docker inspect --format '{{ .HostConfig.NanoCpus }} {{ .HostConfig.Memory }}' flags-api-prod-app-1 flags-api-prod-db-1` | Valores diferentes de 0 |
| Sem bind mount de código-fonte | `docker inspect --format '{{ json .Mounts }}' flags-api-prod-app-1` | `[]` |
| Dados do PostgreSQL em volume nomeado | `docker volume ls --filter name=flags-api-prod_pgdata` | Volume listado |
| Subida do avaliador | `cp .env.example .env && docker compose -f compose.prod.yaml up -d` | Serviços no ar |
| `GET /health` retorna 200 | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/health` | `200` |
| `GET /flags` retorna 200 | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/flags` | `200` |
| `app` e `db` healthy | `docker compose -f compose.prod.yaml ps` | `app` e `db` com `(healthy)`; `migrate` com `Exited (0)` |
| Encerrar o ambiente | `docker compose -f compose.prod.yaml down` (ou `down -v`) | Containers removidos |

### Consistência geral

| Critério | Comando de verificação | Esperado |
| --- | --- | --- |
| Código da aplicação não alterado | `git log --oneline -- src package.json package-lock.json tsconfig.json` | Nenhum commit posterior aos commits da aplicação base (a partir de `def32de` só há alterações de containerização) |
| Sem credenciais hardcoded no Dockerfile e nos compose | `grep -n -i password Dockerfile compose.yaml compose.prod.yaml` | Somente `${DB_PASSWORD:?...}` e um comentário; nenhum valor literal |
| Único arquivo versionado com credenciais | `git ls-files '.env*'` | Apenas `.env.example` |

## Estrutura do entregável

```text
.
├── Dockerfile
├── .dockerignore
├── .gitignore
├── compose.yaml
├── compose.prod.yaml
├── .env.example
├── reports/
│   └── scout-cves.txt
├── src/                  (não alterado)
├── package.json          (não alterado)
├── package-lock.json     (não alterado)
├── tsconfig.json         (não alterado)
└── README.md
```

## Repositórios

- GitHub: <https://github.com/nelsonmacca/fc4-desafio-docker-node-api>
- Docker Hub: <https://hub.docker.com/r/nelsonmacca/fc4-desafio-docker-node-api>
- Repositório base do desafio: <https://github.com/devfullcycle/fc4-desafio-docker-node-api>
