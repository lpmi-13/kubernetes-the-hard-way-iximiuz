#!/usr/bin/env bash
set -euo pipefail

CILIUM_VERSION="1.16.5"

require_worker_nodes() {
  local expected="${1:-9}"
  local node_output worker_count

  node_output="$(kubectl get nodes 2>/dev/null || true)"
  worker_count="$(printf '%s\n' "${node_output}" | awk '$1 ~ /^worker-/ {count++} END {print count+0}')"
  if [ "${worker_count}" -lt "${expected}" ]; then
    echo "[cilium] expected ${expected} registered worker nodes before install, found ${worker_count}" >&2
    printf '%s\n' "${node_output}" >&2
    echo "[cilium] rerun the worker bootstrap and kubectl configuration steps before step 11" >&2
    exit 1
  fi
}

require_worker_nodes 9

echo "[cilium] adding Cilium Helm repository"
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium

echo "[cilium] rendering Cilium ${CILIUM_VERSION} manifests"
helm template cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set k8sServiceHost=server.kubernetes.local \
  --set k8sServicePort=6443 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.relay.extraEnv[0].name=GOPS_CONFIG_DIR \
  --set hubble.relay.extraEnv[0].value=/tmp \
  --set hubble.ui.enabled=true \
  --set 'hubble.metrics.enabled={dns,drop,tcp,flow,httpV2:exemplars=true;labelsContext=source_namespace\,destination_namespace\,source_pod\,destination_pod}' \
  --set operator.replicas=1 \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.200.0.0/16}' \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  > /tmp/cilium-manifests.yaml

echo "[cilium] applying Cilium manifests"
kubectl apply -f /tmp/cilium-manifests.yaml

echo "[cilium] waiting for Cilium to be ready"
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s

echo "[cilium] Cilium and operator are ready"
echo "[cilium] Hubble Relay requires CoreDNS for DNS — it will become ready after step 12"
cilium status --wait=false || true

echo "[cilium] deployment complete"
