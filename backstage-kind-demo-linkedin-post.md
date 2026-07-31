Wanted to test a self-service namespace-onboarding form in Backstage before wiring it to a real API — so I spun up a fully disposable Backstage instance on a kind cluster, locally, on an M3 Mac.

No shared cluster, no CI pipeline, no external registry — just kind + Docker Desktop + guest auth + in-cluster Postgres. Took longer than expected once I hit a chain of Dockerfile issues (native module compile failures, a Node version mismatch masquerading as a toolchain problem, deprecated Yarn flags) — wrote all of them up so the next person doesn't have to re-debug the same chain.

Wrote up the full config: cluster setup, Dockerfile, manifests, and how I smoke-tested the scaffolder template itself.

📄 Full write-up: [link to Medium post]
💻 Repo with all manifests + scripts: github.com/simonjday/backstage-kind-demo

#Kubernetes #Backstage #PlatformEngineering #DevOps #kind #InternalDeveloperPortal
