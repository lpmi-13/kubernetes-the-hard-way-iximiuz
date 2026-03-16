#!/usr/bin/env bash
set -euo pipefail

wait_for_worker_nodes() {
  local expected="${1:-9}"
  local node_output worker_count

  for _ in {1..90}; do
    node_output="$(kubectl get nodes 2>/dev/null || true)"
    worker_count="$(printf '%s\n' "${node_output}" | awk '$1 ~ /^worker-/ {count++} END {print count+0}')"
    if [ "${worker_count}" -ge "${expected}" ]; then
      printf '%s\n' "${node_output}"
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for ${expected} worker nodes to register" >&2
  kubectl get nodes -o wide 2>/dev/null || true
  return 1
}

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server=https://server.kubernetes.local:6443 \
  --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=admin.crt \
  --client-key=admin.key \
  --embed-certs=true \
  --kubeconfig=admin.kubeconfig

kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin \
  --kubeconfig=admin.kubeconfig

kubectl config use-context kubernetes-the-hard-way --kubeconfig=admin.kubeconfig

mkdir -p ~/.kube
cp admin.kubeconfig ~/.kube/config

wait_for_worker_nodes 5
