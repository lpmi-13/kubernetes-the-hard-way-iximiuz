#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f ~/deployments/core-dns.yaml
kubectl -n kube-system rollout status deployment/coredns
kubectl get pods -l k8s-app=kube-dns -n kube-system

COREDNS_NODE="$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.nodeName}')"
kubectl delete pod busybox --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
kubectl run busybox --image=busybox:1.28.4 --restart=Never \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${COREDNS_NODE}\"}}" -- sleep 3600
kubectl wait --for=condition=Ready pod/busybox --timeout=90s
kubectl get pod busybox -o wide

# Cilium needs a moment to finish wiring eBPF programs to the new pod's network
# before kubectl exec will work reliably.
for attempt in {1..10}; do
  if kubectl exec busybox -- nslookup kubernetes.default.svc.cluster.local; then
    break
  fi
  if [ "$attempt" -eq 10 ]; then
    echo "nslookup failed after 10 attempts" >&2
    exit 1
  fi
  echo "exec attempt ${attempt} failed; retrying in $((attempt * 2))s..."
  sleep $((attempt * 2))
done

# Confirm Hubble Relay is now healthy (it needs CoreDNS for DNS resolution)
echo ""
echo "=== Verifying Hubble Relay ==="
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=120s
echo ""
echo "=== Full Cilium + Hubble Status ==="
cilium status --wait=false
echo ""
echo "All components are healthy: Cilium, Hubble, and CoreDNS."
