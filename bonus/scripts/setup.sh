#!/usr/bin/env bash
set -euo pipefail

CLUSTER=iot
ARGO_VERSION=v3.5.5
GITLAB_CHART_REPO=https://gitlab.com/gitlab-org/charts/gitlab.git
GITLAB_CHART_REF="2fc7f47418d09e0b44914d0e1ae3686f0e7be5e0"
CHART_DIR="$HOME/.cache/iot-gitlab-chart"
GL_TOKEN="iot-setup-token-0123456789"      # throwaway token for a local lab
RESUME="${RESUME:-0}"                      # RESUME=1 skips cluster + GitLab install
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

# --- Helpers ---------------------------------------------------------------

# Wait until pods matching a label exist, then until they are Ready
wait_for_pod() {   # usage: wait_for_pod <label> <namespace> <timeout>
  local label=$1 ns=$2 timeout=$3
  for i in $(seq 1 60); do
    kubectl get pod -l "$label" -n "$ns" --no-headers 2>/dev/null | grep -q . && break
    sleep 5
  done
  kubectl wait --for=condition=Ready pod -l "$label" -n "$ns" --timeout="$timeout"
}

# Background helper: pull every image used in the gitlab namespace on the host
# (resumable, with retries) and import it into the cluster
prepull_loop() {
  local seen=/tmp/iot-prepulled.txt
  : > "$seen"
  while true; do
    for img in $(kubectl get pods -n gitlab -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | sort -u); do
      grep -qxF "$img" "$seen" && continue
      echo "$img" >> "$seen"
      for i in 1 2 3 4 5; do docker pull -q "$img" >/dev/null 2>&1 && break || sleep 10; done
      k3d image import "$img" -c "$CLUSTER" >/dev/null 2>&1 || true
    done
    sleep 10
  done
}

PREPULL_PID=""
stop_prepull() {
  if [ -n "$PREPULL_PID" ]; then kill "$PREPULL_PID" 2>/dev/null || true; PREPULL_PID=""; fi
}
trap stop_prepull EXIT

# --- Cluster, chart, dependencies, GitLab install ---------------------------
if [ "$RESUME" != "1" ]; then

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

  # --- Dependencies (PostgreSQL, Valkey, object storage), with retries ---
  echo "==> Provisioning PostgreSQL, Valkey and object storage"
  helm repo remove garage >/dev/null 2>&1 || true
  prepull_loop &
  PREPULL_PID=$!
  ok=0
  for attempt in 1 2 3; do
    if ( cd "$CHART_DIR" && bash scripts/dev_dependencies.sh setup ); then ok=1; break; fi
    echo "!! dependency setup failed or timed out (attempt $attempt), retrying"
    sleep 15
  done
  if [ "$ok" != "1" ]; then
    echo "!! PostgreSQL/Valkey/Garage did not become ready"
    exit 1
  fi

  # --- Pre-pull the GitLab chart images on the host ---
  echo "==> Listing GitLab images"
  IMAGES=$( cd "$CHART_DIR" && helm dependency update >/dev/null 2>&1 \
    && helm template gitlab . -n gitlab --skip-crds \
         -f .values/dev-external.values.yaml \
         -f "$CONFS/gitlab-values.yaml" 2>/dev/null \
    | grep -E '^\s*-?\s*image:' | sed -E 's/.*image:[[:space:]]*//; s/"//g' | sort -u || true )

  if [ -z "$IMAGES" ]; then
    echo "!! Could not list the GitLab images, the background puller will handle them"
  else
    echo "==> Pre-pulling $(echo "$IMAGES" | wc -l) images"
    for img in $IMAGES; do
      echo "  - $img"
      ok=0
      for i in 1 2 3 4 5; do
        if docker pull -q "$img" >/dev/null 2>&1; then ok=1; break; fi
        sleep 10
      done
      if [ "$ok" = "1" ]; then
        k3d image import "$img" -c "$CLUSTER" >/dev/null 2>&1 || echo "    (import failed, the node will pull it)"
      else
        echo "    (pull failed, the node will retry)"
      fi
    done
  fi

  echo "==> Installing GitLab"
  ( cd "$CHART_DIR" \
    && helm upgrade --install gitlab . -n gitlab --create-namespace \
         --skip-crds \
         --timeout 900s \
         -f .values/dev-external.values.yaml \
         -f "$CONFS/gitlab-values.yaml" )
  # --skip-crds: K3s's bundled Traefik already provides the Gateway API CRDs

else
  echo "==> RESUME=1: skipping cluster creation and GitLab install"
  [ -n "$PREPULL_PID" ] || { prepull_loop & PREPULL_PID=$!; }
fi

echo "==> Waiting for GitLab to be ready (can be slow on a first run)"
wait_for_pod app=webservice gitlab 2400s
wait_for_pod app=toolbox gitlab 600s
stop_prepull

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
  && git push -q "http://root:$GL_TOKEN@gitlab.local/root/mlamrani.git" main ) \
  || echo "(push skipped or already done)"
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
