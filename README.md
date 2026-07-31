# backstage-kind-demo

Disposable test instance of [Backstage](https://backstage.io) running on a
[kind](https://kind.sigs.k8s.io/) cluster on Apple Silicon (M-series Mac).
Guest auth, in-cluster Postgres, nginx ingress — no external dependencies
beyond Docker Desktop and Node 22.

Built to smoke-test a scaffolder template (`backstage-template.yaml`) for
self-service OpenShift namespace onboarding before wiring it to a real
backend API.

## Quick start

```bash
# 1. Scaffold the Backstage app itself (not included in this repo — it's the
#    generated app source, kept separate from the cluster config below)
npx @backstage/create-app@latest --path ~/dev/backstage-test
cd ~/dev/backstage-test

# 2. Copy config/build files from this repo into the scaffolded app,
#    overwriting the scaffolded defaults:
cp /path/to/backstage-kind-demo/app-config.production.yaml ./app-config.production.yaml
cp /path/to/backstage-kind-demo/Dockerfile ./packages/backend/Dockerfile
cp /path/to/backstage-kind-demo/dockerignore ./.dockerignore

# 3. Confirm yarn/corepack works locally, then build + deploy:
corepack enable
yarn install

cd /path/to/backstage-kind-demo
./scripts/setup.sh
```

Then visit **http://localhost:8080**.

Tear down completely:
```bash
./scripts/teardown.sh
```

## What's in this repo

| Path | Purpose |
|---|---|
| `kind-backstage.yaml` | kind cluster config (control-plane node, ingress port mappings) |
| `app-config.production.yaml` | Backstage backend config overlay — Postgres connection, guest auth |
| `Dockerfile` | Multi-stage build for the Backstage backend image (place at `packages/backend/Dockerfile` in the scaffolded app) |
| `dockerignore` | Replaces `create-app`'s default `.dockerignore` — the default excludes `packages/*/src`, which breaks an in-container `tsc`/build |
| `manifests/00-namespace.yaml` | `backstage` namespace |
| `manifests/01-postgres-secret.yaml` | DB credentials (test-only values — replace before reusing anywhere real) |
| `manifests/02-postgres.yaml` | Postgres StatefulSet + Service |
| `manifests/03-backstage-deployment.yaml` | Backstage Deployment + Service |
| `manifests/04-ingress.yaml` | nginx Ingress routing `localhost` → Backstage |
| `backstage-template.yaml` | Example scaffolder template — self-service namespace onboarding form |
| `scripts/setup.sh` | One-shot cluster create + build + deploy |
| `scripts/teardown.sh` | `kind delete cluster` |

## Requirements

- Docker Desktop for Mac (Apple Silicon), 6+ CPUs / 8GB+ RAM allocated
- `kind`, `kubectl` (`brew install kind kubectl`)
- Node.js 22 (`brew install node@22`) — earlier Backstage scaffolds tolerated
  Node 20, but the current `create-app` pulls in native deps (`isolated-vm`,
  node-gyp's bundled `undici`) that require Node 22's V8/runtime
- `corepack enable` — required for Yarn 4, not enabled by default

## Notes

- Uses direct `kubectl apply`, not GitOps — this is a throwaway test cluster.
  Don't reuse these manifests as-is against a persistent/shared cluster
  without putting them behind ArgoCD or equivalent first.
- `imagePullPolicy: Never` on the Backstage Deployment — every code change
  needs `docker build` + `kind load docker-image` again, there's no live
  reload path in-cluster.
- **`create-app`'s default `.dockerignore` excludes `packages/*/src` and
  `plugins`** — it assumes you build the backend on the host *before*
  `docker build` and the Dockerfile just packages the prebuilt tarballs.
  This repo's Dockerfile builds inside the container instead (`yarn tsc` +
  `yarn build:backend` run in the build stage), so it needs those source
  dirs present in the build context. Replace the scaffolded `.dockerignore`
  with `dockerignore` from this repo (rename to `.dockerignore` in the
  scaffolded app) before building.
- Full write-up: link to the accompanying Medium post goes here once published.

## Troubleshooting

Real issues hit building this exact stack (Node 22 scaffold, Yarn 4.13.0,
Apple Silicon) — in the order you're likely to hit them:

**`yarn: command not found`**
Corepack ships with Node but isn't enabled by default.
```bash
corepack enable
corepack prepare yarn@stable --activate
```

**`kubectl wait: error: no matching resources found`**
`kubectl wait` requires the target pod to already exist — it won't wait for
one to be *created*. Poll for existence first:
```bash
until kubectl get pods -n <namespace> -l <selector> 2>/dev/null | grep -q <name>; do sleep 2; done
kubectl wait --namespace <namespace> --for=condition=ready pod --selector=<selector> --timeout=120s
```
`scripts/setup.sh` already does this for ingress-nginx, Postgres, and Backstage.

**Native module build fails (`tree-sitter-json`, `cpu-features`, etc.) with exit code 1**
The slim base image has no C/C++ toolchain. Add before `COPY . .`:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
```

**Same native modules still fail after adding the toolchain — `isolated-vm` errors on `v8::SourceLocation`, or node-gyp errors with `webidl.util.markAsUncloneable is not a function`**
This is a Node version problem, not a toolchain problem. `isolated-vm` and
node-gyp's bundled `undici` both need APIs only present in Node 22's V8/runtime.
**Use `node:22-bookworm-slim`, not `node:20`, in both Dockerfile stages** — this
was the actual root cause behind several of the errors above, not the
toolchain. Match your local Node version too:
```bash
brew install node@22
```

**`yarn tsc` — "No inputs were found in config file"**
`create-app`'s default `.dockerignore` excludes `packages/*/src` and
`plugins`, since it assumes you build on the host before `docker build`. This
repo's Dockerfile builds inside the container, so it needs source present.
Replace `.dockerignore` with `dockerignore` from this repo.

**`yarn build:backend` — "Config file .../packages/backend/app-config.yaml does not exist"**
The build script's working directory is `packages/backend/`, so config paths
need to point back to the repo root:
```dockerfile
RUN yarn build:backend --config ../../app-config.yaml --config ../../app-config.production.yaml
```

**Runtime stage — "current global version of Yarn is 1.22.22" / Corepack version mismatch**
Each build stage is a fresh container — `corepack enable` from the build
stage doesn't carry over. Run it again in the runtime stage, before any
`yarn` command:
```dockerfile
FROM node:22-bookworm-slim
WORKDIR /app
RUN corepack enable
```

**Runtime stage — `yarn install --frozen-lockfile --production` fails silently (exit code 1, no useful output)**
These are deprecated Yarn Classic flags that don't map cleanly onto Yarn 4's
workspace model — and worse, the extracted skeleton tarball alone doesn't
include the root `yarn.lock`/`.yarnrc.yml`/`.yarn` directory needed to resolve
against. Fix is Backstage's own documented pattern: copy those root files
from the build stage first, then use `workspaces focus`:
```dockerfile
COPY --from=build /app/yarn.lock /app/package.json /app/.yarnrc.yml ./
COPY --from=build /app/.yarn ./.yarn
COPY --from=build /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz
RUN yarn workspaces focus --all --production && yarn cache clean
COPY --from=build /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz
```

All of the above is already baked into this repo's `Dockerfile` and
`dockerignore` — this section is here for anyone hitting the same errors
against a different scaffold version where the specifics may have shifted.

## License

MIT — see `LICENSE`.
