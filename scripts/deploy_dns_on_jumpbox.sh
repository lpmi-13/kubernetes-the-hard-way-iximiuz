#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f ~/deployments/core-dns.yaml
kubectl -n kube-system rollout status deployment/coredns
kubectl get pods -l k8s-app=kube-dns -n kube-system

COREDNS_NODE="$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.nodeName}')"
kubectl delete pod busybox --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl run busybox --image=busybox:1.28.4 --restart=Never \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${COREDNS_NODE}\"}}" -- sleep 3600
kubectl wait --for=condition=Ready pod/busybox --timeout=90s
kubectl get pod busybox -o wide
kubectl exec -i busybox -- nslookup kubernetes.default.svc.cluster.local
