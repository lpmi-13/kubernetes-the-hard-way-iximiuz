#!/usr/bin/env bash
set -euo pipefail

echo "[hubble-gazer] verifying Hubble Relay is ready"
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=180s

echo "[hubble-gazer] deploying manifest"
kubectl apply -f ~/deployments/hubble-gazer.yaml

echo "[hubble-gazer] waiting for rollout"
kubectl -n kube-system rollout status deployment/hubble-gazer --timeout=180s

kubectl -n kube-system get pods -l app=hubble-gazer -o wide
kubectl -n kube-system get svc hubble-gazer

echo "[hubble-gazer] deployment complete"
