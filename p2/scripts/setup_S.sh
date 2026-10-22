#!/usr/bin/env bash
set -euo pipefail

# 1. Check if K3s is already running
if systemctl is-active --quiet k3s; then
  echo "[*] K3s service is already running. Skipping installation."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  k3s kubectl get nodes
  exit 0
fi

# 2. Check for port 6443 conflicts
if ss -tuln | grep -q ":6443 "; then
  echo "[-] Error: Port 6443 is already in use by another process." >&2
  ss -tulpn | grep ":6443" >&2
  exit 1
fi

# 3. Clean installation with timeout safeguards
echo "[+] No active K3s found. Installing K3s server..."

# Explicitly export the install version to skip GitHub release channel checks if DNS is slow
export INSTALL_K3S_CHANNEL="stable"

curl -sfL --connect-timeout 15 --retry 3 https://get.k3s.io | K3S_TOKEN="IOT_42_clus" sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-ip="192.168.56.110" \
  --advertise-address="192.168.56.110" \
  --tls-san="192.168.56.110"

# 4. Set up kubeconfig permissions (K3s symlinks kubectl automatically to /usr/local/bin/kubectl)
echo "[+] Configuring kubeconfig..."
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown -R "$(id -u):$(id -g)" "$HOME/.kube"
export KUBECONFIG="$HOME/.kube/config"

# 5. Wait for API and node readiness
echo "[+] Waiting for K3s node to be ready..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  sleep 2
done

# 6. Apply deployment manifest if it exists
if [ -f "dep_p2.yaml" ]; then
  kubectl apply -f dep_p2.yaml
fi

echo "[+] K3s server installed and verified ready."
