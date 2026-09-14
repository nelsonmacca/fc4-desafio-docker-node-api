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
