#!/usr/bin/env bash
set -euo pipefail

HUBBLE_GAZER_VERSION="0.6.2"

echo "[hubble-gazer] verifying Hubble Relay is ready"
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=180s

echo "[hubble-gazer] deploying hubble-gazer ${HUBBLE_GAZER_VERSION}"
kubectl apply -f ~/deployments/hubble-gazer.yaml

echo "[hubble-gazer] waiting for rollout"
kubectl -n kube-system rollout status deployment/hubble-gazer --timeout=180s

kubectl -n kube-system get pods -l app=hubble-gazer -o wide
kubectl -n kube-system get svc hubble-gazer
kubectl -n kube-system get svc hubble-gazer-nodeport

NODE_PORT="$(kubectl -n kube-system get svc hubble-gazer-nodeport -o jsonpath='{.spec.ports[0].nodePort}')"
echo "[hubble-gazer] direct worker-node access is available on NodePort ${NODE_PORT}"

echo "[hubble-gazer] deployment complete"
