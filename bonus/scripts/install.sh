#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing base packages"
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates git

# Docker: install only if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker Engine"
  curl -fsSL https://get.docker.com | sudo sh
  sudo systemctl enable --now docker
  sudo groupadd -f docker
  sudo usermod -aG docker "$USER"
  echo "!! Docker installed. If 'docker ps' says permission denied, log out and back in (or run: newgrp docker)"
else
  echo "==> Docker already installed, skipping"
fi

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  echo "==> Installing kubectl"
  KVER="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -fsSLO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
else
  echo "==> kubectl already installed, skipping"
fi

# k3d
if ! command -v k3d >/dev/null 2>&1; then
  echo "==> Installing k3d"
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
else
  echo "==> k3d already installed, skipping"
fi

# Helm 4 (the GitLab chart's dependency script needs v4+)
if ! command -v helm >/dev/null 2>&1 || ! helm version --short | grep -q '^v4'; then
  echo "==> Installing Helm 4"
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
  chmod +x /tmp/get_helm.sh
  /tmp/get_helm.sh
  rm -f /tmp/get_helm.sh
else
  echo "==> Helm 4 already installed, skipping"
fi

echo "==> Versions"
docker --version
kubectl version --client
k3d version
