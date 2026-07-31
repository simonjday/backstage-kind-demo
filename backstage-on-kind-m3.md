# Test Backstage Instance on kind (M3 MacBook Pro)

Standalone, disposable Backstage instance for testing the namespace-onboarding
scaffolder template (`backstage-template.yaml`) against a real UI. Uses direct
`kubectl apply` throughout, not GitOps — this is a throwaway test cluster, not
`kind-devops-lab`. If you want it to persist, point ArgoCD at the manifests
afterward.

Everything here targets Apple Silicon (arm64). Backstage's official images and
Postgres are both multi-arch, so no emulation needed.

## 0. Prerequisites

```bash
# Docker Desktop for Mac (Apple Silicon) — must be running before anything else
brew install --cask docker

# kind, kubectl
brew install kind kubectl

# Node.js 22 (Backstage's current create-app requires Node 22 — native deps
# like isolated-vm and node-gyp's bundled undici fail to compile on Node 20;
# check backstage.io/docs/getting-started for the current requirement)
brew install node@22
echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# yarn (Backstage's supported package manager)
corepack enable
```

Give Docker Desktop at least 6 CPUs / 8GB RAM in Settings → Resources — the
Backstage backend + Postgres + ingress controller inside kind will otherwise
starve on the defaults.

Verify:
```bash
docker version --format '{{.Server.Arch}}'   # expect: arm64
node --version                                 # expect: v22.x
kind version
kubectl version --client
```

## 1. Create the kind Cluster

```yaml
# kind-backstage.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: backstage-test
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
```

```bash
kind create cluster --config kind-backstage.yaml
kubectl cluster-info --context kind-backstage-test
```

Install an ingress controller (nginx, kind-flavored manifest handles the
`ingress-ready` node label above):

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# kubectl wait errors immediately with "no matching resources found" if the
# pod hasn't been scheduled yet — wait for it to exist first
until kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q controller; do
  sleep 2
done

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

## 2. Scaffold the Backstage App

Do this on your Mac's filesystem, not in-cluster — you build a Docker image
from it afterward.

```bash
mkdir -p ~/dev/backstage-test && cd ~/dev/backstage-test
npx @backstage/create-app@latest --path .
# Prompts: name it e.g. "backstage-test"
```

This creates `packages/app` (frontend) and `packages/backend`. Confirm it runs
locally first, before touching Kubernetes:

```bash
yarn install
yarn dev
# opens http://localhost:3000 — Ctrl+C once confirmed working
```

## 3. Configure for In-Cluster Postgres + Guest Auth

Test instance — use guest auth, skip real SSO/GitHub integration setup.

```yaml
# app-config.production.yaml  (place at repo root, alongside app-config.yaml)
app:
  baseUrl: http://localhost:8080

backend:
  baseUrl: http://localhost:8080
  listen:
    port: 7007
  csp:
    connect-src: ["'self'", 'http:', 'https:']
  cors:
    origin: http://localhost:8080
  reading:
    allow:
      - host: raw.githubusercontent.com
      - host: github.com
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}

auth:
  environment: development
  providers:
    guest:
      # guest auth is blocked outside NODE_ENV=development by default —
      # our Dockerfile (§4) sets NODE_ENV=production for the runtime image,
      # so this override is required. Never do this for anything real.
      dangerouslyAllowOutsideDevelopment: true

catalog:
  rules:
    # Default rules exclude Template kind from url-type locations (templates
    # execute scaffolder actions, treated as more sensitive than a Component).
    - allow: [Component, System, API, Resource, Location, Template]
  locations:
    - type: url
      target: https://github.com/simonjday/agentgateway-demo/blob/main/catalog-info.yaml
      # swap/remove for whichever repo you want registered — or point at the
      # namespace-onboarding-api repo to test the scaffolder template end to end
```

## 4. Dockerfile and .dockerignore

Backstage's `create-app` generates its own version of both, but replace them
with the versions below — the scaffolded defaults break an in-container build
in two separate ways (see §12 Troubleshooting for why each piece here exists):

```dockerfile
# packages/backend/Dockerfile
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
# The scaffolder backend requires this on Node 20+ (isolated-vm sandboxing
# conflicts with V8's node snapshot feature otherwise).
ENV NODE_OPTIONS=--no-node-snapshot
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
```

`create-app`'s default `.dockerignore` excludes `packages/*/src` and
`plugins` — it assumes you build the backend on the host *before*
`docker build`, then the Dockerfile just packages prebuilt tarballs. Since
this Dockerfile builds inside the container instead, replace it:

```
.git
.github
.vscode
node_modules
**/node_modules
**/dist
**/dist-types
.yarn/cache
.yarn/install-state.gz
*.log
.DS_Store
```

```bash
cd ~/dev/backstage-test
cp path/to/Dockerfile packages/backend/Dockerfile
cp path/to/dockerignore .dockerignore
```

## 5. Build and Load Image into kind

kind doesn't pull from Docker Hub for local images — build locally, then load
directly into the cluster's node, skipping a registry entirely:

```bash
cd ~/dev/backstage-test
docker build -t backstage-test:local -f packages/backend/Dockerfile . --no-cache
kind load docker-image backstage-test:local --name backstage-test
```

Re-run both lines any time you change app code. Expect the first build to
take 60–90 seconds — most of it is `yarn install` resolving and building
Backstage's native dependencies from scratch inside the container.

## 6. Kubernetes Manifests

```yaml
# manifests/00-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: backstage
```

```yaml
# manifests/01-postgres-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: backstage
type: Opaque
stringData:
  POSTGRES_USER: backstage
  POSTGRES_PASSWORD: backstage-test-only   # test cluster only — never reuse this value anywhere real
  POSTGRES_DB: backstage
```

```yaml
# manifests/02-postgres.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: backstage
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef: { name: postgres-credentials }
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: 500m, memory: 512Mi }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests: { storage: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: backstage
spec:
  selector: { app: postgres }
  ports:
    - port: 5432
      targetPort: 5432
```

```yaml
# manifests/03-backstage-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backstage
  namespace: backstage
spec:
  replicas: 1
  selector:
    matchLabels: { app: backstage }
  template:
    metadata:
      labels: { app: backstage }
    spec:
      containers:
        - name: backstage
          image: backstage-test:local
          imagePullPolicy: Never   # forces use of the image loaded via `kind load`
          ports:
            - containerPort: 7007
          env:
            - name: POSTGRES_HOST
              value: postgres.backstage.svc.cluster.local
            - name: POSTGRES_PORT
              value: "5432"
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef: { name: postgres-credentials, key: POSTGRES_USER }
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: postgres-credentials, key: POSTGRES_PASSWORD }
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits: { cpu: 1, memory: 1Gi }
          readinessProbe:
            httpGet: { path: /healthcheck, port: 7007 }
            initialDelaySeconds: 15
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: backstage
  namespace: backstage
spec:
  selector: { app: backstage }
  ports:
    - port: 7007
      targetPort: 7007
```

```yaml
# manifests/04-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: backstage
  namespace: backstage
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  rules:
    - host: localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backstage
                port:
                  number: 7007
```

## 7. Apply Everything

```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-postgres-secret.yaml
kubectl apply -f manifests/02-postgres.yaml

kubectl wait --namespace backstage \
  --for=condition=ready pod \
  --selector=app=postgres \
  --timeout=90s

kubectl apply -f manifests/03-backstage-deployment.yaml
kubectl apply -f manifests/04-ingress.yaml

kubectl wait --namespace backstage \
  --for=condition=ready pod \
  --selector=app=backstage \
  --timeout=180s
```

Backstage's first boot runs DB migrations — if the readiness probe is slow to
go green, check logs rather than assuming failure:

```bash
kubectl logs -n backstage deploy/backstage -f
```

## 8. Access It

```bash
open http://localhost:8080
```

(Port 8080 → kind's `extraPortMappings` → ingress-nginx → Service → Pod,
per the cluster config in step 1.)

## 9. Test the Namespace-Onboarding Template

Add the template to `app-config.production.yaml`'s `catalog.locations`, or
register it live via the UI: **Create → Register Existing Component**, pointing
at the raw URL of `backstage-template.yaml` from the design doc's repo.

Two things worth confirming before registering, since both surfaced as real
errors when building this:

- The template file must have a top-level `spec.type` (e.g.
  `infrastructure`, `service`, `website`) — it's a required field, easy to
  miss when hand-writing a Template entity.
- The config already needs `backend.reading.allow` for
  `raw.githubusercontent.com`/`github.com` and a `catalog.rules` entry
  allowing `Template` kind (both included in §3's config block above) —
  without them, registration fails with "is not allowed" or "is not of an
  allowed kind" respectively.

If you push a fix to the template file and re-registering still shows the
old error, GitHub's raw-content CDN may be serving a stale cached copy from
a different edge — cache-bust the URL with a throwaway query string
(`?v=2`) when retrying rather than assuming something's stuck in the catalog.

Once it registers, **Create** → it should appear as "Request a Namespace"
with the four parameter pages (Basics / Sizing & Network / Security &
Compliance / Lifecycle) built in the earlier design doc.

The template's submit step uses the built-in `debug:log` action rather than
a real HTTP call — there's no built-in generic HTTP POST action in
Backstage, and the original design assumed one (`http:backstage:request`)
that only exists via a separate plugin. `debug:log` logs every submitted
parameter, which is enough to confirm the full form → scaffolder pipeline
works end to end without any external dependency. See §13's Troubleshooting
entry for wiring up a real HTTP action if you want to actually hit an
endpoint (e.g. `httpbin.org/post` for a smoke test, or the real onboarding
API).

## 10. One-Shot Setup Script

```bash
#!/usr/bin/env bash
# scripts/setup.sh
set -euo pipefail

CLUSTER_NAME="backstage-test"
APP_DIR="${HOME}/dev/backstage-test"

echo "==> Creating kind cluster"
kind create cluster --config kind-backstage.yaml

echo "==> Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo "==> Building Backstage image"
cd "${APP_DIR}"
docker build -t backstage-test:local -f packages/backend/Dockerfile .
kind load docker-image backstage-test:local --name "${CLUSTER_NAME}"

echo "==> Applying manifests"
cd - >/dev/null
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-postgres-secret.yaml
kubectl apply -f manifests/02-postgres.yaml
kubectl wait --namespace backstage --for=condition=ready pod \
  --selector=app=postgres --timeout=90s
kubectl apply -f manifests/03-backstage-deployment.yaml
kubectl apply -f manifests/04-ingress.yaml
kubectl wait --namespace backstage --for=condition=ready pod \
  --selector=app=backstage --timeout=180s

echo "==> Done. Visit http://localhost:8080"
```

## 11. Teardown

```bash
#!/usr/bin/env bash
# scripts/teardown.sh
set -euo pipefail
kind delete cluster --name backstage-test
```

Full cluster deletion — nothing persists since Postgres's PVC dies with the
kind node. If you want state to survive `kind delete cluster`, back the PVC
with a hostPath on the Mac instead of kind's default local-path provisioner,
but for a disposable test instance this is rarely worth the extra config.

## 12. Known Limitations of This Setup

- **Guest auth only** — fine for smoke-testing the scaffolder template UI, not
  representative of your eventual OIDC-backed production Backstage.
- **No GitOps** — deliberately, since this cluster is disposable. Don't reuse
  these manifests as-is against `kind-devops-lab`; render them through
  ArgoCD/Gitea first if you want a persistent internal developer portal.
- **Single replica, no HA** — a test instance, not a target for load testing
  the onboarding API itself.
- **`imagePullPolicy: Never`** — means every code change requires a rebuild +
  `kind load docker-image` cycle; there's no live-reload path for the in-cluster
  container the way `yarn dev` gives you locally.

## 13. Troubleshooting

Real issues hit building this exact stack (Node 22 scaffold, Yarn 4.13.0,
Apple Silicon), roughly in the order you'd hit them:

**`yarn: command not found`**
Corepack ships with Node but isn't enabled by default.
```bash
corepack enable
corepack prepare yarn@stable --activate
```

**`kubectl wait: error: no matching resources found`**
`kubectl wait` requires the target pod to already exist — it won't wait for
one to be *created*. Poll for existence first, then wait for readiness:
```bash
until kubectl get pods -n <namespace> -l <selector> 2>/dev/null | grep -q <name>; do sleep 2; done
kubectl wait --namespace <namespace> --for=condition=ready pod --selector=<selector> --timeout=120s
```
§10's setup script already does this for ingress-nginx, Postgres, and Backstage.

**Native module build fails (`tree-sitter-json`, `cpu-features`, `better-sqlite3`) — exit code 1**
The slim base image ships no C/C++ toolchain. Add before `COPY . .`:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
```

**Same modules still fail after adding the toolchain — `isolated-vm` errors on `v8::SourceLocation`, or node-gyp errors with `webidl.util.markAsUncloneable is not a function`**
This is a Node version problem, not a toolchain problem — don't keep adding
system packages. `isolated-vm` and node-gyp's bundled `undici` both need
APIs only present in Node 22's V8/runtime. **Use `node:22-bookworm-slim`,
not `node:20`, in both Dockerfile stages.** Match locally too:
```bash
brew install node@22
```
Docker platform (arm64 vs amd64 emulation) is a red herring here if you're
already on native Apple Silicon — verify with `docker version --format
'{{.Server.Arch}}'` before chasing it, but don't expect it to be the fix.

**`yarn tsc` — "No inputs were found in config file"**
`create-app`'s default `.dockerignore` excludes `packages/*/src` and
`plugins`, since it assumes the backend is built on the host before
`docker build`. This guide's Dockerfile builds inside the container, so it
needs source present — replace `.dockerignore` per §4.

**`yarn build:backend` — "Config file .../packages/backend/app-config.yaml does not exist"**
The build script's working directory is `packages/backend/`, so config
paths must point back to the repo root:
```dockerfile
RUN yarn build:backend --config ../../app-config.yaml --config ../../app-config.production.yaml
```

**Runtime stage — "current global version of Yarn is 1.22.22" / Corepack version mismatch**
Each `FROM` stage is a fresh container — `corepack enable` from the build
stage doesn't carry over. Run it again in the runtime stage before any
`yarn` command.

**Runtime stage — `yarn install --frozen-lockfile --production` fails silently (exit code 1, no useful output)**
These are deprecated Yarn Classic flags that don't map cleanly onto Yarn 4's
workspace model, and the extracted skeleton tarball alone doesn't include
the root `yarn.lock`/`.yarnrc.yml`/`.yarn` directory needed to resolve
against. Fix is Backstage's own documented pattern — copy those root files
from the build stage, then use `workspaces focus` (already reflected in §4's
final Dockerfile):
```dockerfile
COPY --from=build /app/yarn.lock /app/package.json /app/.yarnrc.yml ./
COPY --from=build /app/.yarn ./.yarn
RUN yarn workspaces focus --all --production && yarn cache clean
```

**Getting a real error instead of a truncated "exit code 1"**
Docker's summary output often hides the actual compiler/node-gyp error.
Temporarily wrap the failing `RUN` to dump the log:
```dockerfile
RUN yarn install --frozen-lockfile || \
    (find /tmp -name 'build.log' -print -exec cat {} \; ; exit 1)
```
Remove it once you've got a real error to work from — it's a diagnostic
step, not something to ship.

**Guest sign-in fails — "Failed to sign in as a guest using the auth backend" dialog in the browser, backend pod logs show `NotAllowedError: The guest provider cannot be used outside of a development environment`**
Backstage blocks guest auth whenever `NODE_ENV=production`, which the
Dockerfile in §4 sets deliberately for the runtime image. Fix in
`app-config.production.yaml`:
```yaml
auth:
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
```
This requires a full rebuild (`docker build ... && kind load ...`), not just
`kubectl rollout restart` — the config file is baked into the image at build
time, not mounted live from a ConfigMap.

**Register Existing Component fails — "Reading from '...raw.githubusercontent.com/...' is not allowed"**
Backstage refuses to fetch from arbitrary hosts unless explicitly
allow-listed (or configured as a GitHub integration with a token). Fix:
```yaml
backend:
  reading:
    allow:
      - host: raw.githubusercontent.com
      - host: github.com
```
Same rebuild requirement — baked into the image.

**Register Existing Component fails — "is not of an allowed kind for that location"**
Default catalog rules exclude `Template` kind from URL-registered locations
(templates execute scaffolder actions, treated as more sensitive than a
plain `Component`). Fix:
```yaml
catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template]
```

**Template validation fails — "/spec must have required property 'type'"**
`spec.type` is required on every Template entity (e.g. `service`, `website`,
`infrastructure`) and easy to omit when hand-writing one:
```yaml
spec:
  type: infrastructure
```

**Same validation error persists after fixing and pushing the template file**
GitHub's raw-content CDN caches per-edge for a few minutes; a retry can hit
a still-stale edge. Cache-bust with a throwaway query parameter:
```
https://raw.githubusercontent.com/<org>/<repo>/main/backstage-template.yaml?v=2
```
If the entity page shows "Entity not found" at this point, there's nothing
persisted to unregister — the earlier failures were live validation
responses, not a stuck broken entity. The cache-bust alone resolves it.

**Form submits but the task fails — "...scaffolder backend plugin requires that it be started with the --no-node-snapshot option"**
The scaffolder's action sandboxing (`isolated-vm` again — same package from
the native-module saga in §4) needs V8's node snapshot feature disabled on
Node 20+. Fix in the Dockerfile's runtime stage:
```dockerfile
ENV NODE_OPTIONS=--no-node-snapshot
```

**Task fails — "Template action with ID '...' is not registered"**
Only Backstage's actual built-in actions work without extra setup —
`fetch:*`, `github:*`, `debug:log`, `catalog:*`, `fs:*` (check your
backend's startup logs for the exact list). There's no built-in generic
HTTP POST action, so §9's template uses `debug:log` for its submit step —
it logs the submitted parameters, proving the form → scaffolder pipeline
works without needing an external plugin. For a real HTTP call, install
`@roadiehq/scaffolder-backend-module-http-request` (registers
`http:backstage:request`) and add it to `packages/backend/src/index.ts`.
