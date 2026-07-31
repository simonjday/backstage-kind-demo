# Running Backstage on kind: A Disposable Test Instance on Apple Silicon

I wanted to test a self-service scaffolder template — a form for requesting
OpenShift namespace creation and access — against a real Backstage UI before
wiring it up to a live API. Rather than fighting for time on a shared
Backstage instance, I spun up a fully disposable one on a kind cluster,
locally, on an M3 MacBook Pro. This is the write-up, with the full
configuration in [github.com/simonjday/backstage-kind-demo](https://github.com/simonjday/backstage-kind-demo).

## Why kind, why local

Backstage's own getting-started docs point you at `yarn dev` running the app
directly on your machine, which is fine for frontend work but doesn't tell
you anything about how it behaves once it's actually running as a container
in Kubernetes — image builds, readiness probes, in-cluster Postgres,
ingress routing. Since the eventual target for this scaffolder template is a
Kubernetes-hosted developer portal, I wanted the test loop to match that
shape from the start, without needing a shared cluster or CI pipeline to
iterate.

kind gives you a full control plane in a Docker container in under a minute,
and on Apple Silicon everything involved — Backstage's official images,
Postgres, ingress-nginx — is multi-arch, so there's no emulation tax.

## The shape of it

```
kind cluster (backstage-test)
 └─ ingress-nginx  (localhost:8080 → Service)
     └─ backstage namespace
         ├─ postgres        (StatefulSet, 1Gi PVC)
         └─ backstage       (Deployment, guest auth, built locally)
```

Everything's built locally and loaded straight into the kind node with
`kind load docker-image` — no registry, no push step, nothing to clean up
externally.

## Cluster config

```yaml
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
```

The `ingress-ready=true` label is what lets kind's own ingress-nginx manifest
target the node correctly — miss this and the ingress controller pod sits in
`Pending` waiting for a node selector match that never happens.

## Scaffolding, building, loading

```bash
npx @backstage/create-app@latest --path ~/dev/backstage-test
cd ~/dev/backstage-test

# the scaffolded Dockerfile and .dockerignore both need replacing before this
# works — see "The parts that actually took time" below, or just use the
# versions in the repo directly
docker build -t backstage-test:local -f packages/backend/Dockerfile . --no-cache
kind load docker-image backstage-test:local --name backstage-test
```

That last line is the one that makes local iteration painless — the image
never leaves your machine, and `imagePullPolicy: Never` on the Deployment
forces Kubernetes to use exactly what you just loaded rather than reaching
for a registry.

## Guest auth, in-cluster Postgres

For a throwaway test instance there's no reason to stand up real SSO. Guest
auth plus a single Postgres StatefulSet is enough to get the catalog and
scaffolder working end to end:

```yaml
auth:
  environment: development
  providers:
    guest: {}

backend:
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}
```

The Postgres credentials come from a Secret, injected as env vars into the
Backstage Deployment — nothing exotic, just enough to keep the password out
of the manifest itself.

## Testing the actual template

The point of the exercise was the scaffolder template — a four-page form
(Basics, Sizing & Network, Security & Compliance, Lifecycle) for requesting
an OpenShift namespace. Registering it in Backstage is one
`Create → Register Existing Component` away, pointed at the raw template
URL — in theory. In practice this, and then actually running it, turned
out to be its own small gauntlet, covered below. Once past all of it I
could walk through the actual form fields, confirm the conditional
descriptions (e.g. flagging that `anyuid` or `confidential` data
classification triggers an approval step) rendered as expected, and catch a
couple of enum ordering issues I'd never have noticed just reading the YAML.

## The parts that actually took time

None of the above was the hard part. The Dockerfile was. `create-app`'s
scaffolded build assumes you compile the backend on the host and hand Docker
a pre-built tarball; I wanted a single self-contained build, which meant
fighting through a chain of issues that each looked like the last one until
they didn't:

- **Native modules failing to compile** (`tree-sitter-json`, `cpu-features`,
  `better-sqlite3`) — the slim base image has no C/C++ toolchain, so
  `python3`/`make`/`g++` had to go in before `yarn install`.
- **Same modules still failing after that** — turned out to be a Node
  version problem wearing a toolchain-shaped disguise. `isolated-vm` calls
  `v8::SourceLocation`, which doesn't exist in the V8 build shipped with
  Node 20; node-gyp's bundled `undici` hits the same wall from a different
  angle. Current Backstage scaffolds need Node 22, full stop.
- **`tsc` finding zero source files** — the scaffolded `.dockerignore`
  excludes `packages/*/src` on the assumption you're building outside the
  container. Had to replace it.
- **Config path resolution** — `yarn build:backend`'s working directory is
  `packages/backend/`, so config flags need `../../app-config.yaml`, not
  `app-config.yaml`.
- **Corepack not carrying over between build stages** — each `FROM` is a
  fresh container; enabling corepack in the build stage doesn't help the
  runtime stage.
- **Deprecated Yarn Classic flags silently failing under Yarn 4** — the
  fix was adopting Backstage's own documented runtime-stage pattern:
  copy the root lockfile/config from the build stage, then
  `yarn workspaces focus --all --production` instead of
  `yarn install --frozen-lockfile --production`.

Each of these produces a generic "exit code 1" from Docker's summary output
by default — getting the real compiler/node-gyp error required temporarily
piping the build log to stdout on failure. Worth doing early rather than
guessing at fixes against a truncated error.

Getting the *container built* was only half of it. Getting a working demo
inside it — registering the template, then actually running it — was its
own sequence:

- **Guest sign-in silently fails** with a "fallback to legacy guest token?"
  dialog, and the backend logs the real reason:
  `NotAllowedError: The guest provider cannot be used outside of a
  development environment`. Backstage blocks guest auth whenever
  `NODE_ENV=production` — which the Dockerfile sets deliberately for the
  runtime image. Fix is an explicit opt-out:
  `auth.providers.guest.dangerouslyAllowOutsideDevelopment: true`. Never do
  this anywhere real.
- **Registering the template fails** with "Reading from
  '...raw.githubusercontent.com/...' is not allowed" — Backstage won't
  fetch from arbitrary hosts unless allow-listed. Fix:
  `backend.reading.allow` with the host explicitly added.
- **Registering it again fails differently**: "is not of an allowed kind
  for that location." Default catalog rules exclude `Template` from
  URL-registered locations, since templates execute scaffolder actions and
  are treated as more sensitive than a plain `Component`. Fix:
  `catalog.rules` with `Template` added to the allow list.
- **Registering it a third time fails on the template itself**:
  `/spec must have required property 'type'`. `spec.type` is required on
  every Template entity and trivial to omit when hand-writing one.
- **Fixing and pushing the file didn't immediately fix the error** — GitHub's
  raw-content CDN caches per-edge for a few minutes, and a retry can land on
  a still-stale edge showing the old, broken content. A throwaway query
  string (`?v=2`) on the raw URL cache-busts it.
- **The template finally registers, the form finally submits — and the
  task immediately fails**: "the scaffolder backend plugin requires that it
  be started with the `--no-node-snapshot` option." Same `isolated-vm`
  dependency from the Dockerfile saga, still causing trouble, this time at
  runtime rather than build time. Fix: `NODE_OPTIONS=--no-node-snapshot` in
  the Dockerfile.
- **One more**: "Template action with ID 'http:backstage:request' is not
  registered." That action doesn't actually exist in Backstage core — I'd
  written the template assuming a generic HTTP-POST action that only ships
  via a separate community plugin. Swapped the step to the built-in
  `debug:log` instead, which logs every submitted parameter and proves the
  whole form → scaffolder pipeline works without needing any external
  dependency at all.

Seven straight fixes just to get one template to register and run —
each one a distinct, correctly-worded error pointing at a genuinely
different gate. None of it was hard once diagnosed; all of it was invisible
until hit.



This setup is deliberately throwaway: `kind delete cluster` wipes everything,
including the Postgres data, since nothing's backed by anything outside the
kind node. That's the right tradeoff for a few hours of template testing. It
is very much not the right tradeoff for an actual internal developer portal
— that needs real auth, GitOps-managed manifests instead of direct
`kubectl apply`, and persistent storage that survives the cluster itself.
But for validating a form before it goes anywhere near production, kind
create cluster to a working UI is hard to beat — especially now that the
Dockerfile fights above are already solved. Clone the repo, and it's genuinely
under an hour.

Full manifests, Dockerfile, and setup/teardown scripts — troubleshooting
notes included — are in
[github.com/simonjday/backstage-kind-demo](https://github.com/simonjday/backstage-kind-demo).
