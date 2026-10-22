#!/usr/bin/env bash
set -euo pipefail

# 1. Check if K3s is already installed and running
if systemctl is-active --quiet k3s; then
  echo "[*] K3s service is already running. Skipping installation."
  
  # Ensure the node is responsive
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl get nodes
  exit 0
fi

# 2. Check for port 6443 conflicts before starting
if ss -tuln | grep -q ":6443 "; then
  echo "[-] Error: Port 6443 is already in use by another process." >&2
  ss -tulpn | grep ":6443" >&2
  exit 1
fi

# 3. Clean installation if no existing instance is detected
echo "[+] No active K3s found. Installing K3s server..."
# curl -sfL https://get.k3s.io | sh -s - server \ 
#   --write-kubeconfig-mode 644
curl -sfL https://get.k3s.io | K3S_TOKEN="IOT_42_clus" sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-ip="192.168.56.110" \
  --advertise-address="192.168.56.110" \
  --tls-san="192.168.56.110"
# 4.install kubectl
echo "[+] Installing Kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# 5. Wait for API and node readiness
echo "[+] Waiting for K3s node to be ready..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  sleep 2
done
mkdir -p $HOME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
echo "192.168.56.110 app1.com" | sudo tee -a /etc/hosts > /dev/null
echo "[+] K3s server installed and verified ready."
