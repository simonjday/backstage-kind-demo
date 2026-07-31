# packages/backend/Dockerfile — place at this path in your scaffolded app
FROM node:22-bookworm-slim AS build
WORKDIR /app
RUN corepack enable

# tree-sitter-json and other native deps need a C/C++ toolchain to build —
# the slim base image doesn't ship one.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      make \
      g++ \
    && rm -rf /var/lib/apt/lists/*

COPY . .
RUN yarn install --immutable
RUN yarn tsc
RUN yarn build:backend --config ../../app-config.yaml --config ../../app-config.production.yaml

FROM node:22-bookworm-slim
WORKDIR /app
RUN corepack enable

# `yarn workspaces focus` needs the root lockfile/config to resolve against —
# the skeleton tarball alone only contains the backend package's own files.
COPY --from=build /app/yarn.lock /app/package.json /app/.yarnrc.yml ./
COPY --from=build /app/.yarn ./.yarn
COPY --from=build /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz

RUN yarn workspaces focus --all --production && yarn cache clean

COPY --from=build /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

COPY app-config.yaml app-config.production.yaml ./
ENV NODE_ENV=production
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
