#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for file in \
  kube-apiserver \
  kube-controller-manager \
  kube-scheduler \
  kubectl \
  kube-apiserver.service \
  kube-controller-manager.service \
  kube-scheduler.service \
  kube-scheduler.yaml \
  ca.crt \
  ca.key \
  front-proxy-ca.crt \
  front-proxy-client.crt \
  front-proxy-client.key \
  kube-api-server.crt \
  kube-api-server.key \
  service-accounts.crt \
  service-accounts.key \
  encryption-config.yaml \
  kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig
do
  [ -f "${SCRIPT_DIR}/${file}" ] || { echo "missing ${file} in ${SCRIPT_DIR}" >&2; exit 1; }
done

mkdir -p /etc/kubernetes/config /var/lib/kubernetes

install -m 0755 "${SCRIPT_DIR}/kube-apiserver" /usr/local/bin/kube-apiserver
install -m 0755 "${SCRIPT_DIR}/kube-controller-manager" /usr/local/bin/kube-controller-manager
install -m 0755 "${SCRIPT_DIR}/kube-scheduler" /usr/local/bin/kube-scheduler
install -m 0755 "${SCRIPT_DIR}/kubectl" /usr/local/bin/kubectl

install -m 0644 "${SCRIPT_DIR}/ca.crt" /var/lib/kubernetes/ca.crt
install -m 0600 "${SCRIPT_DIR}/ca.key" /var/lib/kubernetes/ca.key
install -m 0644 "${SCRIPT_DIR}/front-proxy-ca.crt" /var/lib/kubernetes/front-proxy-ca.crt
install -m 0644 "${SCRIPT_DIR}/front-proxy-client.crt" /var/lib/kubernetes/front-proxy-client.crt
install -m 0600 "${SCRIPT_DIR}/front-proxy-client.key" /var/lib/kubernetes/front-proxy-client.key
install -m 0644 "${SCRIPT_DIR}/kube-api-server.crt" /var/lib/kubernetes/kube-api-server.crt
install -m 0600 "${SCRIPT_DIR}/kube-api-server.key" /var/lib/kubernetes/kube-api-server.key
install -m 0644 "${SCRIPT_DIR}/service-accounts.crt" /var/lib/kubernetes/service-accounts.crt
install -m 0600 "${SCRIPT_DIR}/service-accounts.key" /var/lib/kubernetes/service-accounts.key
install -m 0600 "${SCRIPT_DIR}/encryption-config.yaml" /var/lib/kubernetes/encryption-config.yaml
install -m 0600 "${SCRIPT_DIR}/kube-controller-manager.kubeconfig" /var/lib/kubernetes/kube-controller-manager.kubeconfig
install -m 0600 "${SCRIPT_DIR}/kube-scheduler.kubeconfig" /var/lib/kubernetes/kube-scheduler.kubeconfig
install -m 0644 "${SCRIPT_DIR}/kube-scheduler.yaml" /etc/kubernetes/config/kube-scheduler.yaml

ADVERTISE_ADDRESS="$(tailscale ip -4 | tr -d '\n\r')"
sed "s|ADVERTISE_ADDRESS|${ADVERTISE_ADDRESS}|g" "${SCRIPT_DIR}/kube-apiserver.service" > /etc/systemd/system/kube-apiserver.service
install -m 0644 "${SCRIPT_DIR}/kube-controller-manager.service" /etc/systemd/system/kube-controller-manager.service
install -m 0644 "${SCRIPT_DIR}/kube-scheduler.service" /etc/systemd/system/kube-scheduler.service

systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl restart kube-apiserver kube-controller-manager kube-scheduler
