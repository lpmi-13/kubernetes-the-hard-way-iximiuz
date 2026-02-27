#!/usr/bin/env bash
set -euo pipefail

kubectl create secret generic kubernetes-the-hard-way \
  --from-literal="mykey=mydata" \
  --dry-run=client -o yaml | kubectl apply -f -

ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 "etcdctl --endpoints=http://127.0.0.1:2379 get /registry/secrets/default/kubernetes-the-hard-way | hexdump -C"

kubectl create deployment nginx --image=nginx --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout status deployment/nginx --timeout=180s
kubectl get pods -l app=nginx

POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")

kubectl port-forward "${POD_NAME}" 8080:80 >/tmp/kthw-portforward.log 2>&1 &
PF_PID=$!

pf_ok=false
for _ in {1..30}; do
  if curl --head --silent --fail http://127.0.0.1:8080 >/dev/null; then
    pf_ok=true
    break
  fi
  sleep 1
done
if [ "$pf_ok" = false ]; then
  echo "port-forward to nginx did not become ready" >&2
  cat /tmp/kthw-portforward.log >&2 || true
  kill "${PF_PID}" || true
  wait "${PF_PID}" || true
  exit 1
fi
curl --head http://127.0.0.1:8080
kill "${PF_PID}"
wait "${PF_PID}" || true

kubectl logs "${POD_NAME}"
kubectl exec -i "${POD_NAME}" -- nginx -v

if ! kubectl get svc nginx >/dev/null 2>&1; then
  kubectl expose deployment nginx --port 80 --type NodePort
fi
NODE_PORT=$(kubectl get svc nginx --output=jsonpath='{range .spec.ports[0]}{.nodePort}')
NODE_NAME=$(kubectl get pod "${POD_NAME}" --output=jsonpath='{.spec.nodeName}')

curl -I "http://${NODE_NAME}:${NODE_PORT}"

BUSYBOX_PHASE="$(kubectl get pod busybox -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "$BUSYBOX_PHASE" != "Running" ]; then
  kubectl delete pod busybox --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
  COREDNS_NODE="$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.nodeName}')"
  kubectl run busybox --image=busybox:1.28.4 --restart=Never \
    --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${COREDNS_NODE}\"}}" -- sleep 3600
  kubectl wait --for=condition=Ready pod/busybox --timeout=90s
fi

kubectl exec busybox -- nslookup kubernetes.default.svc.cluster.local

# Verify Cilium + Hubble
echo "=== Cilium Status ==="
cilium status || echo "cilium CLI not available, checking pods directly"
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide

echo "=== Hubble Flow Check ==="
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec -i "${CILIUM_POD}" -- hubble observe --last 5 || echo "hubble observe not available yet"

echo "=== Bookinfo Verification ==="
kubectl -n demo get pods
kubectl -n demo get svc productpage

