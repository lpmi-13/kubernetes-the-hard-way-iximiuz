#!/usr/bin/env bash
set -euo pipefail

apt-get update
apt-get -y install socat conntrack ipset

mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /etc/containerd \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

WORKER_SRC_DIR="${HOME}/worker"
CNI_SRC_DIR="${HOME}/cni-plugins"

for bin in containerd containerd-shim-runc-v2 runc kubelet kube-proxy; do
  [ -f "${WORKER_SRC_DIR}/${bin}" ] || { echo "missing worker binary: ${bin}" >&2; exit 1; }
  install -m 0755 "${WORKER_SRC_DIR}/${bin}" "/usr/local/bin/${bin}"
done
for plugin in bridge host-local loopback; do
  [ -f "${CNI_SRC_DIR}/${plugin}" ] || { echo "missing CNI plugin: ${plugin}" >&2; exit 1; }
  install -m 0755 "${CNI_SRC_DIR}/${plugin}" "/opt/cni/bin/${plugin}"
done

WORKER_NUMBER=$(hostname | awk -F '-' '{print $2}')
POD_CIDR="10.200.${WORKER_NUMBER}.0/24"

sed "s|SUBNET|${POD_CIDR}|g" ~/configs/10-bridge.conf > /etc/cni/net.d/10-bridge.conf
cp ~/configs/99-loopback.conf /etc/cni/net.d/99-loopback.conf

cp ~/configs/containerd-config.yaml /etc/containerd/config.toml

sed "s|POD_CIDR|${POD_CIDR}|g" ~/configs/kubelet-config.yaml > /var/lib/kubelet/kubelet-config.yaml
cp ~/configs/kube-proxy-config.yaml /var/lib/kube-proxy/kube-proxy-config.yaml

cp ~/units/containerd.service /etc/systemd/system/containerd.service
cp ~/units/kubelet.service /etc/systemd/system/kubelet.service
cp ~/units/kube-proxy.service /etc/systemd/system/kube-proxy.service

swapoff -a

systemctl daemon-reload
systemctl enable containerd kubelet kube-proxy
systemctl start containerd kubelet kube-proxy
