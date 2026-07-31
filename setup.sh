#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="backstage-test"
APP_DIR="${HOME}/dev/backstage-test"

if [ ! -d "${APP_DIR}" ]; then
  echo "ERROR: ${APP_DIR} not found."
  echo "Scaffold it first: npx @backstage/create-app@latest --path ${APP_DIR}"
  exit 1
fi

echo "==> Creating kind cluster"
kind create cluster --config kind-backstage.yaml

echo "==> Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "==> Waiting for ingress-nginx controller pod to be scheduled"
until kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q controller; do
  sleep 2
done

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo "==> Installing Kyverno (enforces the pending-approval namespace policy)"
if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm not found. Install it first: brew install helm"
  exit 1
fi
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --wait --timeout 180s

echo "==> Applying pending-approval enforcement policy"
kubectl apply -f manifests/06-kyverno-policy.yaml

echo "==> Syncing config/build files into scaffolded app"
cp app-config.production.yaml "${APP_DIR}/app-config.production.yaml"
cp Dockerfile "${APP_DIR}/packages/backend/Dockerfile"
cp .dockerignore "${APP_DIR}/.dockerignore"

echo "==> Syncing custom kubernetes scaffolder action"
mkdir -p "${APP_DIR}/packages/backend/src/modules"
cp kubernetesActions.ts "${APP_DIR}/packages/backend/src/modules/kubernetesActions.ts"

echo "==> Installing kubernetes-actions dependencies"
( cd "${APP_DIR}" && corepack enable \
  && yarn --cwd packages/backend add @kubernetes/client-node js-yaml \
  && yarn --cwd packages/backend add -D @types/js-yaml )

if ! grep -q "kubernetesActionsModule" "${APP_DIR}/packages/backend/src/index.ts" 2>/dev/null; then
  echo ""
  echo "!! MANUAL STEP REQUIRED before building: packages/backend/src/index.ts"
  echo "!! doesn't reference kubernetesActionsModule yet. Add these two lines"
  echo "!! (an import near the top, and backend.add(...) before backend.start()):"
  echo "!!   import { kubernetesActionsModule } from './modules/kubernetesActions';"
  echo "!!   backend.add(kubernetesActionsModule);"
  echo ""
fi

echo "==> Building Backstage image"
cd "${APP_DIR}"
docker build -t backstage-test:local -f packages/backend/Dockerfile . --no-cache
kind load docker-image backstage-test:local --name "${CLUSTER_NAME}"

echo "==> Applying manifests"
cd - >/dev/null
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-postgres-secret.yaml
kubectl apply -f manifests/02-postgres.yaml
kubectl apply -f manifests/05-rbac.yaml

echo "==> Waiting for postgres pod to be scheduled"
until kubectl get pods -n backstage -l app=postgres 2>/dev/null | grep -q postgres; do
  sleep 2
done
kubectl wait --namespace backstage --for=condition=ready pod \
  --selector=app=postgres --timeout=90s

kubectl apply -f manifests/03-backstage-deployment.yaml
kubectl apply -f manifests/04-ingress.yaml

echo "==> Waiting for backstage pod to be scheduled"
until kubectl get pods -n backstage -l app=backstage 2>/dev/null | grep -q backstage; do
  sleep 2
done
kubectl wait --namespace backstage --for=condition=ready pod \
  --selector=app=backstage --timeout=180s

echo "==> Done. Visit http://localhost:8080"
