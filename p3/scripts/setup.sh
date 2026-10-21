#!/usr/bin/env bash
set -euo pipefail

CLUSTER=iot
ARGO_VERSION=v3.5.5
DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS="$DIR/../confs"

# --- Docker access (re-run with the docker group if needed) ---
if ! docker info >/dev/null 2>&1; then
  if getent group docker | grep -qw "$USER"; then
    echo "==> Applying docker group, re-running"
    exec sg docker -c "bash '$0'"
  fi
  echo "!! Cannot reach Docker. Is it installed and running?"
  exit 1
fi

echo "==> (Re)creating cluster '$CLUSTER'"
k3d cluster delete "$CLUSTER" 2>/dev/null || true
# CHANGE 1: second port mapping for the Argo CD UI (8080 -> NodePort 30081)
k3d cluster create "$CLUSTER" \
  -p "8888:30080@agent:0" \
  -p "8080:30081@agent:0" \
  --agents 1

echo "==> Waiting for nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# --- Pre-pull the big Argo CD image on the host, then load it into the cluster ---
IMG="quay.io/argoproj/argocd:$ARGO_VERSION"
echo "==> Pre-pulling $IMG"
for i in 1 2 3; do docker pull "$IMG" && break || sleep 5; done
k3d image import "$IMG" -c "$CLUSTER"

echo "==> Creating namespaces"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev    --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing Argo CD $ARGO_VERSION"
kubectl apply -n argocd --server-side -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGO_VERSION/manifests/install.yaml"

echo "==> Waiting for Argo CD deployments"
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s

# CHANGE 2: expose the UI as a NodePort instead of a fragile port-forward
echo "==> Exposing Argo CD UI on :8080"
kubectl patch svc argocd-server -n argocd --type merge -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"protocol":"TCP","targetPort":8080,"nodePort":30081}]}}'

echo "==> Applying Argo CD Application"
kubectl apply -f "$CONFS/application.yaml"

echo
echo "==> Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

echo
echo "UI:  https://localhost:8080  (user: admin)"
echo "App: curl http://localhost:8888/"
