#!/usr/bin/env bash
set -euo pipefail

get_replicas() {
  local namespace="$1"
  local deployment="$2"

  kubectl -n "${namespace}" get deployment "${deployment}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
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

get_queue_depth() {
  local redis_pod

  redis_pod="$(kubectl -n demo get pod -l app=redis -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n demo exec "${redis_pod}" -- redis-cli LLEN demo-jobs 2>/dev/null || echo 0
}

observe_keda_dynamics() {
  local worker_peak=0
  local worker_scaled_up=false
  local worker_scaled_down=false

  for sample in $(seq 1 36); do
    local worker
    local queue_depth

    worker="$(get_replicas demo demo-worker)"
    queue_depth="$(get_queue_depth)"

    echo "sample=${sample} worker=${worker} queue_depth=${queue_depth}"

    if [ "${worker}" -gt 0 ]; then
      worker_scaled_up=true
    fi

    if [ "${worker_peak}" -gt 0 ] && [ "${worker}" -eq 0 ]; then
      worker_scaled_down=true
    fi

    if [ "${worker}" -gt "${worker_peak}" ]; then
      worker_peak="${worker}"
    fi

    if [ "${worker_scaled_up}" = true ] && [ "${worker_scaled_down}" = true ]; then
      echo "KEDA-driven worker scale-out and scale-in observed successfully"
      return 0
    fi

    sleep 20
  done

  echo "worker_peak=${worker_peak} worker_scaled_up=${worker_scaled_up} worker_scaled_down=${worker_scaled_down}" >&2
  return 1
}

assert_demo_spread() {
  local nodes
  nodes="$(kubectl get pods -n demo -o wide --no-headers | awk '$3 != "Completed" && $7 != "" {print $7}' | sort -u | wc -l | tr -d ' ')"
  echo "demo pods observed on ${nodes} worker nodes"
  [ "${nodes}" -ge 6 ]
}

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
  kubectl run busybox --image=busybox:1.28.4 --restart=Never \
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
  echo "demo deployments were not fully available before autoscaling observation" >&2
  kubectl -n demo get deploy
  kubectl -n demo get pods -o wide
  exit 1
fi

echo "=== Waiting For KEDA Readiness ==="
wait_for_scaledobject_ready

echo "=== Observing KEDA Dynamics ==="
if ! observe_keda_dynamics; then
  echo "failed to observe KEDA-driven worker scale-out and scale-in" >&2
  kubectl -n demo get deploy
  kubectl -n demo get hpa || true
  kubectl -n demo get scaledobject
  exit 1
fi

if ! assert_demo_deployments_available; then
  echo "demo deployments were not fully available after autoscaling observation" >&2
  kubectl -n demo get deploy
  kubectl -n demo get pods -o wide
  exit 1
fi

echo "=== Pod Distribution ==="
kubectl -n demo get pods -o wide
if ! assert_demo_spread; then
  echo "demo pods were not spread across at least 6 worker nodes" >&2
  exit 1
fi
