#!/usr/bin/env bash
set -euo pipefail

count_unique_nodes_for_selector() {
  local namespace="$1"
  local selector="$2"

  kubectl -n "${namespace}" get pods -l "${selector}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | awk 'NF' \
    | sort -u \
    | wc -l \
    | tr -d ' '
}

get_demo_node_count() {
  kubectl get pods -n demo -o wide --no-headers \
    | awk '$3 != "Completed" && $7 != "" {print $7}' \
    | sort -u \
    | wc -l \
    | tr -d ' '
}

get_worker_node_count() {
  kubectl get nodes -o name \
    | cut -d/ -f2 \
    | awk '$0 !~ /^controller-/ {count++} END {print count + 0}'
}

wait_for_scaledobject_ready() {
  for attempt in {1..30}; do
    if kubectl -n demo get scaledobject demo-worker -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null | grep -q '^Ready=True$'; then
      return 0
    fi
    echo "ScaledObject demo-worker not Ready yet (${attempt}/30)"
    sleep 10
  done

  return 1
}

assert_demo_deployments_available() {
  local deployment
  local replicas
  local available

  for deployment in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 redis traffic-generator; do
    replicas="$(kubectl -n demo get deployment "${deployment}" -o jsonpath='{.spec.replicas}')"
    available="$(kubectl -n demo get deployment "${deployment}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
    available="${available:-0}"
    echo "deployment=${deployment} available=${available}/${replicas}"
    if [ "${available}" -lt "${replicas}" ]; then
      return 1
    fi
  done
}

assert_demo_spread() {
  local nodes
  nodes="$(get_demo_node_count)"
  echo "demo pods observed on ${nodes} worker nodes"
  [ "${nodes}" -ge 3 ]
}

assert_static_bookinfo_not_on_every_worker() {
  local total_workers
  local deployment
  local app
  local version
  local nodes

  total_workers="$(get_worker_node_count)"
  echo "worker nodes in cluster: ${total_workers}"
  [ "${total_workers}" -gt 0 ]

  for deployment in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
    app="${deployment%-*}"
    version="${deployment##*-}"
    nodes="$(count_unique_nodes_for_selector demo "app=${app},version=${version}")"
    echo "deployment=${deployment} nodes=${nodes}/${total_workers}"
    if [ "${nodes}" -ge "${total_workers}" ]; then
      return 1
    fi
  done
}

kubectl create secret generic kubernetes-the-hard-way \
  --from-literal="mykey=mydata" \
  --dry-run=client -o yaml | kubectl apply -f -

ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 "etcdctl --endpoints=http://127.0.0.1:2379 get /registry/secrets/default/kubernetes-the-hard-way | hexdump -C"

kubectl create deployment nginx --image=ghcr.io/lpmi-13/nginx:1.29.6 --dry-run=client -o yaml | kubectl apply -f -
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
if [ "${pf_ok}" = false ]; then
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
if [ "${BUSYBOX_PHASE}" != "Running" ]; then
  kubectl delete pod busybox --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
  COREDNS_NODE="$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.nodeName}')"
  kubectl run busybox --image=ghcr.io/lpmi-13/busybox:1.28.4 --restart=Never \
    --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${COREDNS_NODE}\"}}" -- sleep 3600
  kubectl wait --for=condition=Ready pod/busybox --timeout=90s
fi

for attempt in {1..55}; do
  if kubectl exec busybox -- nslookup kubernetes.default.svc.cluster.local; then
    break
  fi
  if [ "${attempt}" -eq 55 ]; then
    echo "nslookup failed after 55 attempts" >&2
    exit 1
  fi
  echo "exec attempt ${attempt} failed; retrying in 2s..."
  sleep 2
done

echo "=== Cilium Status ==="
cilium status || echo "cilium CLI not available, checking pods directly"
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide

echo "=== Hubble Flow Check ==="
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec -i "${CILIUM_POD}" -- hubble observe --last 5 || echo "hubble observe not available yet"

echo "=== Demo Namespace Status ==="
kubectl -n demo get deploy
kubectl -n demo get hpa || true
kubectl -n demo get scaledobject

if ! assert_demo_deployments_available; then
  echo "demo deployments were not fully available before final verification" >&2
  kubectl -n demo get deploy
  kubectl -n demo get pods -o wide
  exit 1
fi

echo "=== Waiting For KEDA Readiness ==="
if ! wait_for_scaledobject_ready; then
  echo "ScaledObject demo-worker did not become Ready" >&2
  kubectl -n demo get deploy
  kubectl -n demo get hpa || true
  kubectl -n demo get scaledobject
  kubectl -n demo describe scaledobject demo-worker || true
  exit 1
fi

if ! assert_demo_deployments_available; then
  echo "demo deployments were not fully available after KEDA readiness" >&2
  kubectl -n demo get deploy
  kubectl -n demo get pods -o wide
  exit 1
fi

echo "=== Pod Distribution ==="
kubectl -n demo get pods -o wide
if ! assert_demo_spread; then
  echo "demo pods were not spread across at least 3 worker nodes" >&2
  exit 1
fi

if ! assert_static_bookinfo_not_on_every_worker; then
  echo "at least one static Bookinfo deployment landed on every worker node" >&2
  exit 1
fi
