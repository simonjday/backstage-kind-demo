# backstage-kind-demo

Disposable test instance of [Backstage](https://backstage.io) running on a
[kind](https://kind.sigs.k8s.io/) cluster on Apple Silicon (M-series Mac).
Guest auth, in-cluster Postgres, nginx ingress — no external dependencies
beyond Docker Desktop and Node 22.

Built to smoke-test two scaffolder templates for self-service OpenShift
namespace onboarding: **Request a Namespace** (creates a real, but inert,
pending-approval namespace in this same kind cluster) and **Approve
Namespace Request** (provisions it — quota, limits, network policy — and
flips it to approved). Both run against the actual cluster Backstage itself
is deployed in, via a small custom scaffolder action.

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
cp /path/to/backstage-kind-demo/.dockerignore ./.dockerignore

# 3. Add the custom kubernetes scaffolder action:
mkdir -p packages/backend/src/modules
cp /path/to/backstage-kind-demo/kubernetesActions.ts \
   packages/backend/src/modules/kubernetesActions.ts
yarn --cwd packages/backend add @kubernetes/client-node js-yaml
yarn --cwd packages/backend add -D @types/js-yaml

# Then add to packages/backend/src/index.ts (near the other backend.add calls):
#   import { kubernetesActionsModule } from './modules/kubernetesActions';
#   backend.add(kubernetesActionsModule);

# 4. Confirm yarn/corepack works locally, then build + deploy:
corepack enable
yarn install

cd /path/to/backstage-kind-demo
./setup.sh
```

`setup.sh` does steps 2–3 for you automatically (copies the module,
installs the deps) and prints a reminder if `index.ts` still needs the
manual two-line wire-up.

Then visit **http://localhost:8080**.

Tear down completely:
```bash
./teardown.sh
```

## Approval workflow

Two templates, meant to be run as two separate steps (ideally by two
different people — see the caveat below). Confirmed working end to end
against a real kind cluster: request → pending namespace → approve → real
`ResourceQuota`/`LimitRange`/`NetworkPolicy` applied.

1. **Request a Namespace** (`backstage-template.yaml`) — the existing
   four-page form. Its submit step now calls the custom `kubernetes:apply`
   action to create a real `Namespace` object in this kind cluster, labelled
   `status: pending-approval`, with all the submitted parameters stored as
   annotations (`requested-by`, `resource-profile`, `network-zone`,
   `scc-requirement`, `data-classification`, etc.). The namespace exists but
   is otherwise inert — no quota, no limits, no network policy yet.

2. **Approve Namespace Request** (`backstage-template-approve.yaml`) —
   takes the pending namespace's name plus an approver name, then calls the
   custom `kubernetes:namespace-provision` action to apply a `ResourceQuota`,
   `LimitRange`, and `NetworkPolicy` sized/scoped by whatever
   profile/zone the approver confirms, and relabels the namespace
   `status: approved` with an `approved-by` annotation.

Check what's pending at any point directly:
```bash
kubectl get ns -l status=pending-approval
kubectl get ns -l status=approved
kubectl describe ns <name>   # see the annotations/labels either step set
kubectl get resourcequota,limitrange,networkpolicy -n <name>   # after approval
```

**Register both templates** the same way as before — `Register Existing
Component`, pointed at each file's raw GitHub URL once pushed.

**Quote every interpolated manifest value.** All `${{ ... }}` substitutions
inside a `manifest: |` block (and any plain step `input:` value that isn't
already enum-constrained) must be wrapped in double quotes, e.g.
`name: "${{ parameters.project_name }}"`. Without quoting, a free-text field
containing only digits (e.g. an on-call ID like `123`) gets rendered as an
unquoted YAML scalar, which `js-yaml` parses as a *number* rather than a
string — Kubernetes then rejects the whole object with `HTTP 400: cannot
unmarshal number into Go struct field ObjectMeta.metadata.annotations of
type string`. Both templates already have this fixed throughout.

**`requested-by` and `expiry-date` may show up empty** in `kubectl
describe` — under guest auth, `${{ user.entity.metadata.name }}` doesn't
resolve to a usable value (there's no real signed-in identity behind it),
and `expiry-date` is simply blank if left empty in the optional Lifecycle
step. Neither is a bug; both would populate normally with real auth
configured and/or the field actually filled in.

**On the "two different people" part**: this demo runs on guest auth, which
is a single anonymous identity — there's no real second user to approve as.
`approver_name` is a free-text field standing in for that. With real auth
configured (GitHub OAuth, say), the approval template's `approver_name`
step could be dropped entirely in favor of deriving it automatically from
the signed-in user via `${{ user.entity.metadata.name }}`, and a real
permission policy could enforce that the requester and approver aren't the
same identity — the piece this demo can't show without swapping guest auth
out for something with real distinct logins.

**RBAC**: the Backstage pod needs permission to create/patch `Namespace`,
`ResourceQuota`, `LimitRange`, and `NetworkPolicy` objects — granted via
`manifests/05-rbac.yaml` (a dedicated `backstage` ServiceAccount +
ClusterRole + ClusterRoleBinding, referenced by
`03-backstage-deployment.yaml`'s `serviceAccountName`). Apply
`05-rbac.yaml` before the Deployment if you're doing this by hand rather
than via `setup.sh`.

**Enforcement — nothing actually stops workloads in a pending namespace by
default.** A namespace with no quota yet is *more* permissive than an
approved one, not less — labels and annotations alone don't block
anything. `manifests/06-kyverno-policy.yaml` closes this gap with a Kyverno
`ClusterPolicy` that denies `Pod`/`Deployment`/`ReplicaSet`/`StatefulSet`/
`DaemonSet`/`Job` creation in any namespace labelled
`status: pending-approval`, regardless of RBAC or quota state — the layer
that actually holds even if someone has broader cluster access. `setup.sh`
installs Kyverno via Helm and applies this policy automatically; by hand:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm upgrade --install kyverno kyverno/kyverno --namespace kyverno --create-namespace --wait
kubectl apply -f manifests/06-kyverno-policy.yaml
```

Verify it's actually blocking:

```bash
# after running "Request a Namespace" — pick whatever name you used
kubectl run test-pod --image=nginx -n <your-namespace>
# expect: admission webhook denied the request — Namespace "..." is pending approval

# after running "Approve Namespace Request" for the same namespace, retry:
kubectl run test-pod --image=nginx -n <your-namespace>
# expect: pod created successfully (though it'll likely stay Pending on a
# single-node kind cluster depending on the quota's pod count — that's fine,
# admission accepted it, which is what we're checking)
```


## What's in this repo

| Path | Purpose |
|---|---|
| `kind-backstage.yaml` | kind cluster config (control-plane node, ingress port mappings) |
| `app-config.production.yaml` | Backstage backend config overlay — Postgres connection, guest auth, `backend.reading.allow` for GitHub raw content, `catalog.rules` allowing Template kind |
| `Dockerfile` | Multi-stage build for the Backstage backend image (place at `packages/backend/Dockerfile` in the scaffolded app) |
| `.dockerignore` | Replaces `create-app`'s default `.dockerignore` — the default excludes `packages/*/src`, which breaks an in-container `tsc`/build |
| `kubernetesActions.ts` | Custom scaffolder actions — `kubernetes:apply` (generic manifest apply) and `kubernetes:namespace-provision` (quota/limits/netpol by profile/zone) |
| `manifests/00-namespace.yaml` | `backstage` namespace |
| `manifests/01-postgres-secret.yaml` | DB credentials (test-only values — replace before reusing anywhere real) |
| `manifests/02-postgres.yaml` | Postgres StatefulSet + Service |
| `manifests/03-backstage-deployment.yaml` | Backstage Deployment + Service, runs as the `backstage` ServiceAccount |
| `manifests/04-ingress.yaml` | nginx Ingress routing `localhost` → Backstage |
| `manifests/05-rbac.yaml` | ServiceAccount + ClusterRole + ClusterRoleBinding so the pod can manage namespaces/quota/limits/netpol |
| `manifests/06-kyverno-policy.yaml` | Kyverno `ClusterPolicy` blocking workload creation in any `status: pending-approval` namespace |
| `backstage-template.yaml` | "Request a Namespace" — creates a pending-approval namespace in this cluster |
| `backstage-template-approve.yaml` | "Approve Namespace Request" — provisions it and flips it to approved |
| `setup.sh` | One-shot cluster create + build + deploy, including the kubernetes-actions module |
| `teardown.sh` | `kind delete cluster` |
| `push-to-github.sh` | `git init` + `gh repo create` to publish this repo (requires `gh` CLI authenticated) |

## Requirements

- Docker Desktop for Mac (Apple Silicon), 6+ CPUs / 8GB+ RAM allocated
- `kind`, `kubectl`, `helm` (`brew install kind kubectl helm`)
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
  dirs present in the build context. Copy this repo's `.dockerignore` over
  the scaffolded app's default before building (same filename, no rename
  needed — it won't show in a plain `ls`/`tree` locally, use `-a`).
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
`setup.sh` already does this for ingress-nginx, Postgres, and Backstage.

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
Replace `.dockerignore` with `.dockerignore` from this repo (same name — just copy it over directly).

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

**Guest sign-in fails — "Failed to sign in as a guest using the auth backend" dialog, backend logs show `NotAllowedError: The guest provider cannot be used outside of a development environment"`**
Backstage blocks guest auth by default whenever `NODE_ENV=production` — which
our Dockerfile sets deliberately for the runtime image. Fix in
`app-config.production.yaml`:
```yaml
auth:
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
```
Requires a rebuild (`docker build ... && kind load ...`) since the config
file is baked into the image, not mounted live — a plain
`kubectl rollout restart` alone won't pick it up.

**Register Existing Component fails — "Reading from '...raw.githubusercontent.com/...' is not allowed"**
Backstage refuses to fetch from arbitrary hosts unless explicitly
allow-listed (or configured as a GitHub integration with a token). Fix in
`app-config.production.yaml`:
```yaml
backend:
  reading:
    allow:
      - host: raw.githubusercontent.com
      - host: github.com
```
Same rebuild requirement as above — baked into the image.

**Register Existing Component fails — "is not of an allowed kind for that location"**
Default catalog rules exclude `Template` kind from URL-registered locations,
since templates execute scaffolder actions and are treated as more sensitive
than a plain `Component`. Fix in `app-config.production.yaml`:
```yaml
catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template]
```

**Template validation fails — "/spec must have required property 'type'"**
`spec.type` is a required field on Template entities (categorizes the
template, e.g. `service`, `website`, `infrastructure`) and is easy to omit
when hand-writing one. Add it to the template YAML itself:
```yaml
spec:
  type: infrastructure
```

**Same validation error persists even after fixing and pushing the template file**
GitHub's raw-content CDN (Fastly) caches per-edge for a few minutes, and a
retry can hit a still-stale edge. Cache-bust with a throwaway query
parameter when re-registering:
```
https://raw.githubusercontent.com/<org>/<repo>/main/backstage-template.yaml?v=2
```
If the entity page shows "Entity not found" after this kind of failure,
there's nothing stuck to unregister — the error was a live validation
response, not a persisted broken entity. The cache-bust alone is the fix.

**Form submits but the task fails — "When using Node.js version 20 or newer, the scaffolder backend plugin requires that it be started with the --no-node-snapshot option"**
The scaffolder's action sandboxing (via `isolated-vm`, same package from the
native-module saga above) needs V8's node snapshot feature disabled on
Node 20+. Fix — add to the Dockerfile's runtime stage:
```dockerfile
ENV NODE_OPTIONS=--no-node-snapshot
```

**Task fails — "Template action with ID '...' is not registered"**
Only Backstage's actual built-in actions work out of the box (`fetch:*`,
`github:*`, `debug:log`, `catalog:*`, `fs:*`, etc — check your backend's
startup logs for the exact enabled list). There is no built-in generic HTTP
POST action; `backstage-template.yaml`'s submit step uses `debug:log` for
this reason — it logs the submitted parameters without needing any external
plugin, which is enough to prove the form → scaffolder pipeline works.
To actually make an HTTP call, install a plugin that provides one (e.g.
`@roadiehq/scaffolder-backend-module-http-request`, which registers
`http:backstage:request`) and register it in
`packages/backend/src/index.ts` — see the comment block in
`backstage-template.yaml` for the exact steps.

All of the above is already baked into this repo's `Dockerfile`,
`.dockerignore`, `app-config.production.yaml`, and `backstage-template.yaml`
— this section is here for anyone hitting the same errors against a
different scaffold version where the specifics may have shifted.

**Custom action fails to compile — `createTemplateAction<{...}>` gives "Expected 2 type arguments, but got 1"**
The exact generic signature of `createTemplateAction` (and
`@kubernetes/client-node`'s object-API typings) varies enough across
versions that pinning strict generics is fragile. `kubernetesActions.ts`
deliberately avoids explicit generics and uses `any` at a few call sites
instead — not idiomatic, but robust to whatever version actually gets
installed by `yarn add` on a given day.

**Same file fails differently — "Type 'string' is not assignable to type '(zImpl: ...) => ZodType<...>'"**
This means the installed `@backstage/plugin-scaffolder-node` expects
**Zod schemas**, not plain JSON-schema objects, for `schema.input` — it
must be a function receiving a zod implementation:
```typescript
schema: {
  input: (z: any) => z.object({ manifest: z.string() }),
}
```
`kubernetesActions.ts` already uses this form.

**Custom action runs but the Kubernetes API rejects it — "cannot unmarshal number into Go struct field ObjectMeta.metadata.annotations of type string"**
Any `${{ ... }}` value substituted into a `manifest: |` YAML block (or a
plain step `input:` value) that happens to be all-digits (e.g. someone
types `123` into a free-text on-call ID field) renders unquoted, and
`js-yaml` parses it as a number — but Kubernetes annotations/labels must be
strings. Fix: wrap every interpolated value in double quotes,
`"${{ parameters.foo }}"`, everywhere it appears in a manifest — not just
the ones that look like they might be numeric. Both templates in this repo
already do this throughout.

**A cache-bust retry appears to still show the old broken content**
Don't trust a single fetch as proof either way — CDN caching can be
inconsistent across edges, and a fetch from one location isn't guaranteed
to reflect what another location (e.g. your Backstage pod) sees. If a
direct `curl` with a fresh random query param confirms the file is
actually correct on GitHub, but Backstage still errors identically, the
stale copy is on Backstage's side — delete the entity (`Catalog` →
navigate to it directly by URL → **⋮** → Unregister) and register fresh
rather than continuing to retry the same URL.

## License

MIT — see `LICENSE`.
