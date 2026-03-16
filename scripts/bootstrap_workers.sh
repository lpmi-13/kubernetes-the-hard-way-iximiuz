#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

missing_packages=()
for package in socat conntrack ipset; do
  if ! dpkg -s "${package}" >/dev/null 2>&1; then
    missing_packages+=("${package}")
  fi
done

if [ "${#missing_packages[@]}" -gt 0 ]; then
  apt-get update
  apt-get -y install "${missing_packages[@]}"
fi

mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /etc/containerd \
  /var/lib/kubelet \
  /var/lib/kubernetes \
  /var/run/kubernetes

WORKER_SRC_DIR="${SCRIPT_DIR}/worker"

for bin in containerd containerd-shim-runc-v2 runc kubelet; do
  [ -f "${WORKER_SRC_DIR}/${bin}" ] || { echo "missing worker binary: ${bin}" >&2; exit 1; }
  install -m 0755 "${WORKER_SRC_DIR}/${bin}" "/usr/local/bin/${bin}"
done

WORKER_NUMBER=$(hostname | awk -F '-' '{print $2}')
POD_CIDR="10.200.${WORKER_NUMBER}.0/24"
NODE_IP=$(tailscale ip -4)
echo "[worker] Tailscale IP: ${NODE_IP}"

cp "${SCRIPT_DIR}/configs/containerd-config.yaml" /etc/containerd/config.toml

sed "s|POD_CIDR|${POD_CIDR}|g" "${SCRIPT_DIR}/configs/kubelet-config.yaml" > /var/lib/kubelet/kubelet-config.yaml

cp "${SCRIPT_DIR}/units/containerd.service" /etc/systemd/system/containerd.service
sed "s|NODE_IP|${NODE_IP}|g" "${SCRIPT_DIR}/units/kubelet.service" > /etc/systemd/system/kubelet.service

swapoff -a

systemctl daemon-reload
systemctl enable containerd kubelet
systemctl start containerd kubelet
