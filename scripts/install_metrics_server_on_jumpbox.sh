#!/usr/bin/env bash
set -euo pipefail

METRICS_SERVER_VERSION="v0.8.1"
METRICS_SERVER_MANIFEST_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

echo "[metrics-server] resetting deployment to upstream base"
kubectl -n kube-system delete deployment metrics-server --ignore-not-found --wait=true

echo "[metrics-server] applying upstream manifest ${METRICS_SERVER_VERSION}"
kubectl apply -f "${METRICS_SERVER_MANIFEST_URL}"

echo "[metrics-server] patching deployment for host networking and Tailscale node IPs"
kubectl -n kube-system patch deployment metrics-server --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/hostNetwork",
    "value": true
  },
  {
    "op": "add",
    "path": "/spec/template/spec/dnsPolicy",
    "value": "ClusterFirstWithHostNet"
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args",
    "value": [
      "--cert-dir=/tmp",
      "--secure-port=4443",
      "--kubelet-preferred-address-types=InternalIP",
      "--kubelet-use-node-status-port",
      "--metric-resolution=15s",
      "--kubelet-insecure-tls"
    ]
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/ports",
    "value": [
      {
        "containerPort": 4443,
        "name": "https",
        "protocol": "TCP"
      }
    ]
  }
]'

echo "[metrics-server] waiting for rollout"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s

echo "[metrics-server] waiting for aggregated API"
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=300s

echo "[metrics-server] waiting for node metrics"
for attempt in {1..30}; do
  if kubectl top nodes >/dev/null 2>&1; then
    kubectl top nodes
    echo "[metrics-server] metrics are available"
    exit 0
  fi
  echo "[metrics-server] metrics not ready yet (${attempt}/30)"
  sleep 10
done

echo "[metrics-server] node metrics never became available" >&2
exit 1
