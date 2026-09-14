# syntax=docker/dockerfile:1

# Versao explicitamente fixada da imagem oficial Node 22 (sem `latest`).
# Tag verificada no Docker Hub em 2026-09-14: e a mesma imagem para a qual
# `node:22-alpine` aponta hoje (digest sha256:c610fcdf...).
ARG NODE_VERSION=22.23.2-alpine3.24

# ---------------------------------------------------------------------------
# dev: ambiente de desenvolvimento com hot reload (tsx watch)
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION} AS dev

ENV NODE_ENV=development

WORKDIR /app

# A imagem oficial ja traz o usuario `node` (uid/gid 1000). O WORKDIR e criado
# como root, entao transferimos a posse antes de trocar de usuario.
RUN chown node:node /app
USER node

# Manifestos primeiro: a camada de dependencias so e invalidada quando
# package.json ou package-lock.json mudam (no compose, `rebuild` no package.json).
COPY --chown=node:node package.json package-lock.json ./

# Cache do npm persistido entre builds via mount de cache do BuildKit.
# uid/gid garantem que o usuario `node` consiga escrever no cache.
# npm ci com NODE_ENV=development instala tambem as devDependencies (tsx, tsc).
RUN --mount=type=cache,target=/home/node/.npm,uid=1000,gid=1000 \
    npm ci --no-audit --no-fund

# Codigo necessario ao desenvolvimento. `src/` sera sincronizado pelo
# `develop.watch` do compose; por isso pertence ao usuario `node`.
COPY --chown=node:node tsconfig.json ./
COPY --chown=node:node src ./src

EXPOSE 3000

CMD ["npm", "run", "dev"]

# ---------------------------------------------------------------------------
# build: compila TypeScript -> dist/ (tsc)
# ---------------------------------------------------------------------------
# Deriva do estagio dev porque ele ja contem exatamente o que a compilacao
# exige: mesma imagem Node 22 fixada, manifestos copiados antes do codigo,
# `npm ci` com devDependencies (typescript) sob RUN --mount=type=cache,
# tsconfig.json e src/ pertencentes ao usuario `node`. Nenhuma camada de
# dependencia e reinstalada: `--target dev` e `--target build` compartilham
# o cache ate a ultima COPY, e este estagio acrescenta apenas a compilacao.
# O estagio roda como `node` (herdado de USER node), sem root.
FROM dev AS build

# `tsc` le tsconfig.json (rootDir=src, outDir=dist) e gera /app/dist.
RUN npm run build

# ---------------------------------------------------------------------------
# production: runtime enxuto, somente dist/ + dependencias de producao
# ---------------------------------------------------------------------------
# Imagem base: a mesma node:<versao>-alpine fixada do dev/build.
# Alternativas consideradas:
# (tamanhos comprimidos dos manifests linux/amd64, medidos em 2026-09-14)
#   - gcr.io/distroless/nodejs22-debian12 (52,6 MB): menor superficie (sem
#     shell, sem npm), porem sem tag de patch do Node (pin apenas por digest),
#     sem npm para `npm ci --omit=dev` no proprio estagio e sem usuario `node`
#     uid 1000 (usa uid 65532), o que quebraria a consistencia de permissoes
#     com o estagio dev. Tambem impede a inspecao via `docker exec` exigida
#     nesta etapa. Ganho de apenas ~5 MB sobre a Alpine.
#   - node:22.23.2-bookworm-slim (79,9 MB): glibc e ferramentas Debian, mas
#     ~1,4x o tamanho da Alpine (57,7 MB) sem beneficio para esta aplicacao,
#     cujas dependencias (express, pg, dotenv) sao JS puro e nao dependem de
#     glibc nem de binarios nativos.
# Alpine mantem uma unica ARG de versao para todos os estagios, o usuario
# `node` (uid 1000) da imagem oficial e um shell para inspecao. O npm da
# imagem base e usado apenas durante o build (`npm ci --omit=dev`) e removido
# do runtime ao final deste estagio para reduzir a superficie de ataque.
FROM node:${NODE_VERSION} AS production

# Metadados OCI. Valores que mudam a cada publicacao chegam por --build-arg
# (ou por --label no buildx, que sobrescreve LABEL), sem editar o Dockerfile.
ARG APP_VERSION=1.0.0
ARG APP_SOURCE=https://github.com/nelsonmacca/fc4-desafio-docker-node-api

LABEL org.opencontainers.image.title="flags-api" \
      org.opencontainers.image.description="API REST de CRUD de feature flags em Node.js + TypeScript com persistencia em PostgreSQL" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="${APP_SOURCE}"

ENV NODE_ENV=production

WORKDIR /app

# Correcao de seguranca (como root): a base traz libssl3/libcrypto3 3.5.7-r0
# (CVE-2026-63073 e CVE-2026-75803, CRITICAL); o Alpine 3.24 ja publica o
# 3.5.8-r0. Atualizamos somente esses dois pacotes do sistema.
# Observacao: o binario `node` desta imagem e linkado estaticamente com o
# OpenSSL embutido (process.config.variables.node_shared_openssl=false), logo
# process.versions.openssl continua reportando a versao compilada no Node
# (3.5.7) ate uma nova release do Node; so uma nova tag da imagem base corrige
# isso, o que nao faz parte desta etapa.
RUN apk upgrade --no-cache libssl3 libcrypto3

RUN chown node:node /app
USER node

# Somente os manifestos: necessarios ao `npm ci` (que exige o lock) e ao
# npm para resolver a arvore de producao. Nada de tsconfig.json ou src/.
COPY --chown=node:node package.json package-lock.json ./

# Apenas dependencias de producao (sem typescript, tsx, @types).
# Mesmo mount de cache do npm dos outros estagios (uid/gid do usuario node).
RUN --mount=type=cache,target=/home/node/.npm,uid=1000,gid=1000 \
    npm ci --omit=dev --no-audit --no-fund

# npm so e necessario ate aqui (build). O runtime executa `node dist/server.js`
# e nunca chama npm/npx, entao removemos o npm global e seus executaveis para
# reduzir a superficie de ataque: as dependencias vulneraveis embutidas em
# /usr/local/lib/node_modules/npm (tar, brace-expansion, picomatch, pacote,
# sigstore, ...) deixam de existir na imagem. Caminhos verificados na base:
# `npm root -g` = /usr/local/lib/node_modules e npm/npx sao symlinks em
# /usr/local/bin apontando para ../lib/node_modules/npm/bin/*-cli.js.
# Os arquivos pertencem a root, por isso a remocao exige root.
USER root
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
USER node

# Artefato compilado vindo do estagio build; TypeScript nunca entra aqui.
COPY --from=build --chown=node:node /app/dist ./dist

EXPOSE 3000

# Healthcheck com o proprio Node (sem curl/wget): GET /health na porta PORT
# (fallback 3000). Exit 0 somente para HTTP 2xx; exit 1 em erro de conexao,
# timeout ou status fora de 2xx (ex.: 503 quando o banco esta indisponivel).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "-e", "const port = process.env.PORT || 3000; require('http').get({ host: '127.0.0.1', port, path: '/health', timeout: 4000 }, (res) => { res.resume(); process.exit(res.statusCode >= 200 && res.statusCode < 300 ? 0 : 1); }).on('timeout', function () { this.destroy(); process.exit(1); }).on('error', () => process.exit(1));"]

# Exec form, sem npm nem shell: o Node e o PID 1 e recebe SIGTERM diretamente
# (o handler em src/server.ts faz o graceful shutdown).
CMD ["node", "dist/server.js"]
