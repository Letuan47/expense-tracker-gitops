#!/usr/bin/env bash
# ==============================================================================
# SRE Bootstrap Script: K3s Single-Node + Cert-Manager + ArgoCD + KSOPS (SOPS+age)
# Target: Ubuntu 22.04 / 24.04 LTS (x86_64) Staging VPS
# Usage:  sudo AGE_KEY_FILE=/path/to/staging-age.key ./scripts/bootstrap-k3s-staging.sh
# ==============================================================================
set -euo pipefail

echo "=== [1/6] Pre-flight System & Swap Check ==="
TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SWAP_TOTAL_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
echo "Detected RAM: ${TOTAL_MEM_MB} MB | Swap: ${SWAP_TOTAL_MB} MB"

if [ "${SWAP_TOTAL_MB}" -lt 1024 ] && [ ! -f /swapfile ]; then
  echo "Creating 2GB /swapfile to protect K3s & ArgoCD against OOM..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "=== [2/6] Configuring K3s Log Rotation & Image Garbage Collection ==="
mkdir -p /etc/rancher/k3s
cat <<'EOF' > /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0600"
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
  - "image-gc-high-threshold=80"
  - "image-gc-low-threshold=70"
  - "eviction-hard=memory.available<150Mi,nodefs.available<10%"
EOF

echo "=== [3/6] Installing K3s Single-Node ==="
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl wait --for=condition=Ready node --all --timeout=120s

echo "=== [4/6] Installing Cert-Manager for Automated Let's Encrypt TLS ==="
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=180s

echo "=== [5/6] Installing ArgoCD (Lean Single-Node Profile) ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml

# Disable SSO Dex & Notifications controller on Staging to save ~250MB RAM
kubectl -n argocd scale deployment argocd-dex-server --replicas=0 || true
kubectl -n argocd scale deployment argocd-notifications-controller --replicas=0 || true

echo "=== [6/6] Wiring SOPS + age Key & KSOPS into ArgoCD ==="
if [ -n "${AGE_KEY_FILE:-}" ] && [ -f "${AGE_KEY_FILE}" ]; then
  kubectl -n argocd create secret generic sops-age-key \
    --from-file=keys.txt="${AGE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✅ Loaded sops-age-key secret into argocd namespace."
else
  echo "⚠️  AGE_KEY_FILE not provided yet. Creating placeholder sops-age-key secret (replace before syncing encrypted secrets)."
  kubectl -n argocd create secret generic sops-age-key \
    --from-literal=keys.txt="# replace with age private key" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

kubectl apply -f "${REPO_ROOT}/argocd/cluster-issuer.yaml"
kubectl -n argocd patch configmap argocd-cm --type merge --patch-file "${REPO_ROOT}/argocd/ksops-patch.yaml" || true
kubectl -n argocd patch deployment argocd-repo-server --patch "$(awk '/^apiVersion: apps\/v1/,0' "${REPO_ROOT}/argocd/ksops-patch.yaml")"

kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

echo "✅ K3s + Cert-Manager + ArgoCD (with KSOPS) bootstrap completed!"
echo "Next step: kubectl apply -f ${REPO_ROOT}/argocd/project-staging.yaml -f ${REPO_ROOT}/argocd/application-staging.yaml"
