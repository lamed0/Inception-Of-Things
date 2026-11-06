#!/usr/bin/env bash
set -euo pipefail

# --- Configuration: Replace or inject these variables ---
K3S_SERVER_IP="${K3S_SERVER_IP:-192.168.56.110}"
K3S_URL="https://${K3S_SERVER_IP}:6443"
K3S_TOKEN="${K3S_TOKEN:-IOT_42_clus}"

# 1. Check if K3s agent is already installed and running  
if systemctl is-active --quiet k3s-agent; then
  echo "[*] K3s agent service is already running. Skipping installation."
  systemctl status k3s-agent --no-pager
  exit 0
fi

# 2. Verify server connectivity before proceeding
echo "[+] Checking connection to K3s control plane at ${K3S_URL}..."
if ! curl -sk --connect-timeout 5 "${K3S_URL}/ping" >/dev/null; then
  echo "[-] Error: Unable to reach K3s server at ${K3S_URL}. Ensure the server VM is running and port 6443 is accessible." >&2
  exit 1
fi

# 3. Clean installation if no existing instance is detected
echo "[+] Installing K3s agent..."
curl -sfL https://get.k3s.io | K3S_URL="${K3S_URL}" K3S_TOKEN="${K3S_TOKEN}" sh -s - agent --node-ip="192.168.56.111"

# 4. Wait for k3s-agent service to enter active running state
echo "[+] Waiting for k3s-agent service to become active..."
until systemctl is-active --quiet k3s-agent; do
  sleep 2
done

echo "[+] K3s agent installed and service is active."
