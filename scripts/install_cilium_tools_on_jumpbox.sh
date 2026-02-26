#!/usr/bin/env bash
set -euo pipefail

CILIUM_CLI_VERSION="v0.16.25"
HELM_VERSION="v3.17.0"

# Install Cilium CLI
if [ ! -f /usr/local/bin/cilium ]; then
  echo "[cilium] installing Cilium CLI ${CILIUM_CLI_VERSION}"
  curl -sL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
    | tar xz -C /usr/local/bin
else
  echo "[cilium] Cilium CLI already installed"
fi

# Install Helm
if [ ! -f /usr/local/bin/helm ]; then
  echo "[helm] installing Helm ${HELM_VERSION}"
  curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar xz --strip-components=1 -C /usr/local/bin linux-amd64/helm
else
  echo "[helm] Helm already installed"
fi

cilium version --client
helm version --short
