#!/usr/bin/env bash
set -euo pipefail

echo "[bookinfo] deploying Bookinfo application"
kubectl apply -f ~/deployments/bookinfo.yaml

echo "[bookinfo] waiting for deployments to be ready"
for deploy in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  kubectl -n demo rollout status "deployment/${deploy}" --timeout=180s
done

echo "[bookinfo] deploying traffic generator"
kubectl apply -f ~/deployments/bookinfo-traffic-generator.yaml
kubectl -n demo wait --for=condition=Ready pod/traffic-generator --timeout=90s

NODE_PORT=$(kubectl -n demo get svc productpage -o jsonpath='{.spec.ports[0].nodePort}')
echo "[bookinfo] productpage available on NodePort ${NODE_PORT}"

echo "[bookinfo] verifying productpage is accessible"
PRODUCT_NODE=$(kubectl -n demo get pod -l app=productpage -o jsonpath='{.items[0].spec.nodeName}')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${PRODUCT_NODE}:${NODE_PORT}/productpage")
if [ "${HTTP_CODE}" = "200" ]; then
  echo "[bookinfo] productpage returned HTTP 200 - success"
else
  echo "[bookinfo] productpage returned HTTP ${HTTP_CODE} - unexpected" >&2
  exit 1
fi
