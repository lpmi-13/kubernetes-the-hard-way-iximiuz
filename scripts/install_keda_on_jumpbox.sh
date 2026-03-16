#!/usr/bin/env bash
set -euo pipefail

KEDA_VERSION="2.19.0"
KEDA_MANIFEST_URL="https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"

wait_for_secret_data_key() {
  local namespace="$1"
  local secret_name="$2"
  local jsonpath="$3"
  local attempts="${4:-60}"
  local value=""
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    value="$(kubectl -n "${namespace}" get secret "${secret_name}" -o "jsonpath=${jsonpath}" 2>/dev/null || true)"
    if [ -n "${value}" ]; then
      return 0
    fi

    echo "[keda] waiting for Secret/${secret_name} to contain ${jsonpath} (${attempt}/${attempts})"
    sleep 5
  done

  echo "[keda] Secret/${secret_name} did not populate ${jsonpath} in time" >&2
  return 1
}

echo "[keda] applying upstream manifest ${KEDA_VERSION}"
echo "[keda] waiting for CoreDNS to be available before restarting KEDA"
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl apply --server-side --force-conflicts -f "${KEDA_MANIFEST_URL}"

echo "[keda] restarting KEDA deployments after CoreDNS availability is confirmed"
kubectl -n keda rollout restart deployment/keda-operator deployment/keda-metrics-apiserver deployment/keda-admission >/dev/null

echo "[keda] waiting for operator rollout so cert rotation can generate serving certs"
kubectl -n keda rollout status deployment/keda-operator --timeout=300s

echo "[keda] waiting for generated TLS secret"
wait_for_secret_data_key keda kedaorg-certs '{.data.tls\.crt}'

echo "[keda] patching metrics apiserver for host networking and front-proxy trust"
FRONT_PROXY_CA_B64="$(base64 -w0 < ~/front-proxy-ca.crt)"
kubectl -n keda get secret kedaorg-certs -o json \
  | jq --arg client_ca "${FRONT_PROXY_CA_B64}" '.data["client-ca.crt"] = $client_ca' \
  | kubectl apply -f -

kubectl -n keda patch deployment keda-metrics-apiserver --type=json -p='[
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
    "path": "/spec/template/spec/containers/0/args/2",
    "value": "--client-ca-file=/certs/client-ca.crt"
  }
]'

echo "[keda] waiting for CRDs"
kubectl wait --for=condition=Established crd/scaledobjects.keda.sh --timeout=300s
kubectl wait --for=condition=Established crd/triggerauthentications.keda.sh --timeout=300s

echo "[keda] waiting for deployments"
kubectl -n keda rollout status deployment/keda-metrics-apiserver --timeout=300s
kubectl -n keda rollout status deployment/keda-admission --timeout=300s

echo "[keda] waiting for aggregated external metrics API"
kubectl wait --for=condition=Available apiservice/v1beta1.external.metrics.k8s.io --timeout=300s

echo "[keda] installed successfully"
kubectl -n keda get pods
