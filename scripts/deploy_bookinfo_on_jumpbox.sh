#!/usr/bin/env bash
set -euo pipefail

wait_for_scaledobject_ready() {
  local namespace="$1"
  local name="$2"

  for attempt in {1..30}; do
    if kubectl -n "${namespace}" get scaledobject "${name}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null | grep -q '^Ready=True$'; then
      return 0
    fi
    echo "[bookinfo] waiting for ScaledObject/${name} to become Ready (${attempt}/30)"
    sleep 10
  done

  echo "[bookinfo] ScaledObject/${name} did not become Ready in time" >&2
  kubectl -n "${namespace}" describe scaledobject "${name}" >&2 || true
  kubectl -n keda get pods -o wide >&2 || true
  return 1
}

echo "[bookinfo] deploying Bookinfo application"
if kubectl get namespace demo >/dev/null 2>&1; then
  echo "[bookinfo] resetting existing demo namespace"
  kubectl delete namespace demo --wait=true --timeout=300s
fi

kubectl apply -f ~/deployments/bookinfo.yaml

echo "[bookinfo] deploying Redis queue and worker"
kubectl apply -f ~/deployments/async-queue-stack.yaml

echo "[bookinfo] deploying KEDA ScaledObject"
kubectl apply -f ~/deployments/async-keda.yaml

echo "[bookinfo] waiting for base deployments to be ready"
for deploy in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 redis; do
  kubectl -n demo rollout status "deployment/${deploy}" --timeout=300s
done

echo "[bookinfo] verifying KEDA ScaledObject readiness"
wait_for_scaledobject_ready demo demo-worker

NODE_PORT=$(kubectl -n demo get svc productpage -o jsonpath='{.spec.ports[0].nodePort}')
echo "[bookinfo] productpage available on NodePort ${NODE_PORT}"

echo "[bookinfo] verifying productpage is accessible"
PRODUCT_NODE=$(kubectl -n demo get pod -l app=productpage -o jsonpath='{.items[0].spec.nodeName}')
for attempt in {1..12}; do
  HTTP_CODE="$(
    curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "http://${PRODUCT_NODE}:${NODE_PORT}/productpage" || true
  )"
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "[bookinfo] productpage returned HTTP 200 - success"
    break
  fi

  echo "[bookinfo] productpage not ready yet (${attempt}/12), HTTP ${HTTP_CODE:-curl-failed}"
  sleep 5
done

if [ "${HTTP_CODE}" != "200" ]; then
  echo "[bookinfo] productpage returned HTTP ${HTTP_CODE:-curl-failed} - unexpected" >&2
  exit 1
fi

echo "[bookinfo] deploying traffic generators"
kubectl apply -f ~/deployments/bookinfo-traffic-generator.yaml
kubectl -n demo rollout status deployment/traffic-generator --timeout=300s

echo "[bookinfo] current autoscaler state"
kubectl -n demo get hpa || true
kubectl -n demo get scaledobject
