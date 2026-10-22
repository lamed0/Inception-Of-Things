#!/usr/bin/env bash
set -euo pipefail

CLUSTER=iot
ARGO_VERSION=v3.5.5
GITLAB_CHART_REPO=https://gitlab.com/gitlab-org/charts/gitlab.git
GITLAB_CHART_REF="2fc7f47418d09e0b44914d0e1ae3686f0e7be5e0"
CHART_DIR="$HOME/.cache/iot-gitlab-chart"
GL_TOKEN="iot-setup-token-0123456789"      # throwaway token for a local lab
DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS="$DIR/../confs"

case "$GITLAB_CHART_REF" in
  ""|*PASTE*|*paste*|*"<"*) echo "!! Set GITLAB_CHART_REF to a real commit hash first"; exit 1 ;;
esac

# --- Docker access (re-run with the docker group if needed) ---
if ! docker info >/dev/null 2>&1; then
  if getent group docker | grep -qw "$USER"; then
    echo "==> Applying docker group, re-running"
    exec sg docker -c "bash '$0'"
  fi
  echo "!! Cannot reach Docker. Is it installed and running?"
  exit 1
fi

# --- Name resolution for GitLab (inside this machine) ---
grep -q "gitlab.local" /etc/hosts || echo "127.0.0.1 gitlab.local" | sudo tee -a /etc/hosts >/dev/null

echo "==> (Re)creating cluster '$CLUSTER'"
k3d cluster delete "$CLUSTER" 2>/dev/null || true
k3d cluster create "$CLUSTER" \
  -p "8888:30080@agent:0" \
  -p "8080:30081@agent:0" \
  -p "80:80@loadbalancer" \
  --agents 1
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> Waiting for Traefik (bundled ingress)"
for i in $(seq 1 60); do
  kubectl -n kube-system get deploy traefik >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n kube-system rollout status deploy/traefik --timeout=300s

# --- GitLab chart, pinned to a known-good commit ---
echo "==> Fetching GitLab chart ($GITLAB_CHART_REF)"
[ -d "$CHART_DIR/.git" ] || git clone "$GITLAB_CHART_REPO" "$CHART_DIR"
git -C "$CHART_DIR" fetch --quiet origin || true
git -C "$CHART_DIR" checkout --quiet "$GITLAB_CHART_REF"

echo "==> Provisioning PostgreSQL, Valkey and object storage"
helm repo remove garage >/dev/null 2>&1 || true
( cd "$CHART_DIR" && bash scripts/dev_dependencies.sh setup )

echo "==> Installing GitLab (10 to 20 minutes)"
( cd "$CHART_DIR" \
  && helm dependency update \
  && helm upgrade --install gitlab . -n gitlab --create-namespace \
       --skip-crds \
       --timeout 900s \
       -f .values/dev-external.values.yaml \
       -f "$CONFS/gitlab-values.yaml" )
# --skip-crds: K3s's bundled Traefik already provides the Gateway API CRDs

echo "==> Waiting for GitLab to be ready"
kubectl rollout status deploy/gitlab-webservice-default -n gitlab --timeout=1200s
kubectl rollout status deploy/gitlab-toolbox -n gitlab --timeout=600s

# --- Create the project and push the manifests ---
echo "==> Creating an API token for root"
kubectl exec -n gitlab deploy/gitlab-toolbox -c toolbox -- gitlab-rails runner "
u = User.find_by_username('root')
u.personal_access_tokens.where(name: 'iot-setup').destroy_all
t = u.personal_access_tokens.build(scopes: [:api], name: 'iot-setup', expires_at: 30.days.from_now)
t.set_token('$GL_TOKEN')
t.save!
"

echo "==> Creating the public project 'mlamrani'"
code=000
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "PRIVATE-TOKEN: $GL_TOKEN" \
    -d "name=mlamrani&visibility=public&initialize_with_readme=false" \
    http://gitlab.local/api/v4/projects || true)
  if [ "$code" = "201" ] || [ "$code" = "400" ]; then break; fi   # 400 = already exists
  sleep 5
done
if [ "$code" != "201" ] && [ "$code" != "400" ]; then
  echo "!! Could not create the GitLab project (last HTTP code: $code)"; exit 1
fi

echo "==> Pushing manifests to GitLab"
WORK="$(mktemp -d)"
cp -r "$CONFS/manifests" "$WORK/manifests"
( cd "$WORK" \
  && git init -q -b main \
  && git add . \
  && git -c user.name=iot -c user.email=iot@gitlab.local commit -q -m "initial manifests" \
  && git push -q "http://root:$GL_TOKEN@gitlab.local/root/mlamrani.git" main )
rm -rf "$WORK"

# --- Argo CD ---
IMG="quay.io/argoproj/argocd:$ARGO_VERSION"
echo "==> Pre-pulling $IMG"
for i in 1 2 3; do docker pull "$IMG" && break || sleep 5; done
k3d image import "$IMG" -c "$CLUSTER"

echo "==> Creating namespaces argocd and dev"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev    --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing Argo CD $ARGO_VERSION"
kubectl apply -n argocd --server-side -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGO_VERSION/manifests/install.yaml"
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s

echo "==> Exposing Argo CD UI on :8080"
kubectl patch svc argocd-server -n argocd --type merge -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"protocol":"TCP","targetPort":8080,"nodePort":30081}]}}'

echo "==> Applying Argo CD Application (source: GitLab)"
kubectl apply -f "$CONFS/application.yaml"

echo
echo "GitLab  : http://gitlab.local  (user: root)"
echo -n "  password: "
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo
echo "Argo CD : https://localhost:8080  (user: admin)"
echo -n "  password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "App     : curl http://localhost:8888/"
