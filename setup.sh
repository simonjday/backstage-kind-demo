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

echo "==> Syncing config/build files into scaffolded app"
cp app-config.production.yaml "${APP_DIR}/app-config.production.yaml"
cp Dockerfile "${APP_DIR}/packages/backend/Dockerfile"
cp dockerignore "${APP_DIR}/.dockerignore"

echo "==> Building Backstage image"
cd "${APP_DIR}"
docker build -t backstage-test:local -f packages/backend/Dockerfile . --no-cache
kind load docker-image backstage-test:local --name "${CLUSTER_NAME}"

echo "==> Applying manifests"
cd - >/dev/null
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-postgres-secret.yaml
kubectl apply -f manifests/02-postgres.yaml

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
