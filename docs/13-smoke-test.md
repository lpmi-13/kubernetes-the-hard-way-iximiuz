# Smoke Test And KEDA Demo

In this lab you deploy the Bookinfo sample application, install the autoscaling add-on needed for the demo, and run an expanded smoke test suite against the cluster.

Step 13 now verifies three things together:

1. Core Kubernetes workflows still work: secrets, deployments, logs, exec, port-forwarding, NodePort, and DNS.
2. Bookinfo remains reachable under wave-based traffic.
3. Backend queue workers scale with KEDA based on Redis queue depth.

## Autoscaling Components

The demo installs and verifies:

1. `keda` in the `keda` namespace for queue-depth autoscaling.
2. Bookinfo Deployments in the `demo` namespace with:
   - explicit CPU and memory requests
   - topology spread constraints
   - a deliberately lean static footprint so Hubble-gazer stays readable
3. Redis plus `demo-worker` in the `demo` namespace.
4. A traffic-generator Deployment that:
   - sends wave-based HTTP traffic to `productpage`
   - pushes randomized burst/cooldown waves of work items directly into Redis

The async demo intentionally avoids custom application images. Queue publishing is handled by the traffic generator, and the workers use a stock image with inline script logic to consume Redis jobs and spend bounded CPU on each message. The scale signal comes from queue depth, not kubelet CPU metrics.

The default replica mix is intentionally small: `productpage` starts with `2` pods, the other Bookinfo Deployments start with `1` pod each, and KEDA caps `demo-worker` at `9` replicas. That keeps the namespace near an 18-pod ceiling, which is roughly double the 9-pod baseline, while still making scale-out and scale-in easy to spot in Hubble-gazer.

## Run The Demo

From your local machine, identify the jumpbox and copy the required manifests and templates:

```sh
JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .machines[0].name == "jumpbox") | .id')
echo "${JUMPBOX_PLAYGROUND_ID}"

labctl cp -r ./deployments "${JUMPBOX_PLAYGROUND_ID}":~/deployments
labctl cp ./ca.conf "${JUMPBOX_PLAYGROUND_ID}":~/ca.conf
labctl cp ./units/kube-apiserver.service "${JUMPBOX_PLAYGROUND_ID}":~/kube-apiserver.service

labctl ssh "${JUMPBOX_PLAYGROUND_ID}"
```

On the jumpbox, refresh the API aggregation layer:

```sh
bash <<'EOF'
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519
KUBE_APISERVER_UNIT_TEMPLATE="${HOME}/kube-apiserver.service"
CA_CONFIG="${HOME}/ca.conf"

ensure_front_proxy_ca() {
  if [ -s "${HOME}/front-proxy-ca.key" ] && [ -s "${HOME}/front-proxy-ca.crt" ]; then
    return 0
  fi

  openssl genrsa -out "${HOME}/front-proxy-ca.key" 4096
  openssl req -x509 -new -sha512 -noenc \
    -key "${HOME}/front-proxy-ca.key" \
    -days 3653 \
    -subj "/C=US/ST=Washington/L=Seattle/CN=front-proxy-ca" \
    -out "${HOME}/front-proxy-ca.crt"
}

front_proxy_client_is_valid() {
  if [ ! -s "${HOME}/front-proxy-client.key" ] || [ ! -s "${HOME}/front-proxy-client.crt" ]; then
    return 1
  fi

  openssl verify -CAfile "${HOME}/front-proxy-ca.crt" "${HOME}/front-proxy-client.crt" >/dev/null 2>&1 &&
    openssl x509 -in "${HOME}/front-proxy-client.crt" -noout -subject | grep -q 'CN = front-proxy-client'
}

ensure_front_proxy_client() {
  if front_proxy_client_is_valid; then
    return 0
  fi

  [ -s "${HOME}/front-proxy-ca.key" ] && [ -s "${HOME}/front-proxy-ca.crt" ]
  [ -s "${CA_CONFIG}" ]

  rm -f "${HOME}/front-proxy-client.key" "${HOME}/front-proxy-client.crt" "${HOME}/front-proxy-client.csr"
  openssl genrsa -out "${HOME}/front-proxy-client.key" 4096
  openssl req -new -key "${HOME}/front-proxy-client.key" -sha256 \
    -config "${CA_CONFIG}" -section front-proxy-client \
    -out "${HOME}/front-proxy-client.csr"
  openssl x509 -req -days 3653 \
    -in "${HOME}/front-proxy-client.csr" \
    -sha256 \
    -CA "${HOME}/front-proxy-ca.crt" \
    -CAkey "${HOME}/front-proxy-ca.key" \
    -CAcreateserial \
    -copy_extensions copyall \
    -out "${HOME}/front-proxy-client.crt"
  rm -f "${HOME}/front-proxy-client.csr"
}

controller_is_configured() {
  local host="$1"

  ssh -i "${SSH_KEY}" root@"${host}" '
    set -euo pipefail
    grep -q -- "--enable-aggregator-routing=true" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--proxy-client-cert-file=/var/lib/kubernetes/front-proxy-client.crt" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--proxy-client-key-file=/var/lib/kubernetes/front-proxy-client.key" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--requestheader-client-ca-file=/var/lib/kubernetes/front-proxy-ca.crt" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--requestheader-allowed-names=front-proxy-client" /etc/systemd/system/kube-apiserver.service &&
    [ -s /var/lib/kubernetes/front-proxy-ca.crt ] &&
    [ -s /var/lib/kubernetes/front-proxy-client.crt ] &&
    [ -s /var/lib/kubernetes/front-proxy-client.key ] &&
    openssl verify -CAfile /var/lib/kubernetes/front-proxy-ca.crt /var/lib/kubernetes/front-proxy-client.crt >/dev/null 2>&1 &&
    openssl x509 -in /var/lib/kubernetes/front-proxy-client.crt -noout -subject | grep -q "CN = front-proxy-client"
  ' >/dev/null 2>&1
}

configure_controller() {
  local host="$1"
  local advertise_address rendered_unit

  if controller_is_configured "${host}"; then
    return 0
  fi

  advertise_address="$(ssh -i "${SSH_KEY}" root@"${host}" "tailscale ip -4" | tr -d '\n\r')"
  rendered_unit="$(mktemp)"
  sed "s|ADVERTISE_ADDRESS|${advertise_address}|g" "${KUBE_APISERVER_UNIT_TEMPLATE}" > "${rendered_unit}"

  scp -i "${SSH_KEY}" "${rendered_unit}" root@"${host}":/tmp/kube-apiserver.service
  scp -i "${SSH_KEY}" \
    "${HOME}/front-proxy-ca.crt" \
    "${HOME}/front-proxy-client.crt" \
    "${HOME}/front-proxy-client.key" \
    root@"${host}":~/
  rm -f "${rendered_unit}"

  ssh -i "${SSH_KEY}" root@"${host}" 'bash -s' <<'REMOTE'
set -euo pipefail
cp front-proxy-ca.crt front-proxy-client.crt front-proxy-client.key /var/lib/kubernetes/
mv /tmp/kube-apiserver.service /etc/systemd/system/kube-apiserver.service
systemctl daemon-reload
systemctl restart kube-apiserver
until systemctl is-active --quiet kube-apiserver; do
  sleep 2
done
REMOTE
}

wait_for_cluster_api() {
  for _ in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  exit 1
}

ensure_front_proxy_ca
ensure_front_proxy_client

for host in controller-{1..3}; do
  configure_controller "${host}"
done

wait_for_cluster_api
EOF
```

Run a worker DNS preflight before KEDA. This checks whether pods on each worker
can resolve cluster DNS, tries `tailscaled` and Cilium recovery when they
cannot, and cordons the worker if it still fails:

```sh
bash <<'EOF'
set -euo pipefail

MIN_HEALTHY_WORKERS="${MIN_HEALTHY_WORKERS:-3}"
DNS_CHECK_NAMESPACE="${DNS_CHECK_NAMESPACE:-default}"
DNS_CHECK_IMAGE="${DNS_CHECK_IMAGE:-ghcr.io/lpmi-13/busybox:1.28.4}"
DNS_CHECK_HOSTNAME="${DNS_CHECK_HOSTNAME:-kubernetes.default.svc.cluster.local}"
DNS_CHECK_TIMEOUT_SECONDS="${DNS_CHECK_TIMEOUT_SECONDS:-15}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/kubernetes.ed25519}"
WORKER_SSH_USER="${WORKER_SSH_USER:-root}"
WORKER_SSH_TIMEOUT_SECONDS="${WORKER_SSH_TIMEOUT_SECONDS:-10}"
WORKER_REPAIR_RETRY_ATTEMPTS="${WORKER_REPAIR_RETRY_ATTEMPTS:-12}"
WORKER_REPAIR_RETRY_DELAY_SECONDS="${WORKER_REPAIR_RETRY_DELAY_SECONDS:-5}"

cleanup_probe_pod() {
  local pod_name="$1"
  kubectl -n "${DNS_CHECK_NAMESPACE}" delete pod "${pod_name}" \
    --ignore-not-found=true \
    --wait=true \
    --timeout=60s >/dev/null 2>&1 || true
}

check_node_dns() {
  local node_name="$1"
  local pod_name="dns-preflight-${node_name}"

  cleanup_probe_pod "${pod_name}"
  kubectl -n "${DNS_CHECK_NAMESPACE}" run "${pod_name}" \
    --image="${DNS_CHECK_IMAGE}" \
    --restart=Never \
    --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${node_name}\"}}" \
    --command -- sleep 300 >/dev/null

  if ! kubectl -n "${DNS_CHECK_NAMESPACE}" wait --for=condition=Ready "pod/${pod_name}" --timeout=90s >/dev/null 2>&1; then
    cleanup_probe_pod "${pod_name}"
    return 1
  fi

  if ! timeout "${DNS_CHECK_TIMEOUT_SECONDS}" \
    kubectl -n "${DNS_CHECK_NAMESPACE}" exec "${pod_name}" -- nslookup "${DNS_CHECK_HOSTNAME}" >/dev/null 2>&1; then
    cleanup_probe_pod "${pod_name}"
    return 1
  fi

  cleanup_probe_pod "${pod_name}"
  return 0
}

ssh_to_worker() {
  local node_name="$1"
  shift

  ssh \
    -i "${SSH_KEY}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout="${WORKER_SSH_TIMEOUT_SECONDS}" \
    "${WORKER_SSH_USER}@${node_name}" \
    "$@"
}

wait_for_worker_ssh() {
  local node_name="$1"
  local attempt

  for attempt in $(seq 1 "${WORKER_REPAIR_RETRY_ATTEMPTS}"); do
    if ssh_to_worker "${node_name}" true >/dev/null 2>&1; then
      return 0
    fi
    sleep "${WORKER_REPAIR_RETRY_DELAY_SECONDS}"
  done

  return 1
}

restart_tailscaled_on_worker() {
  local node_name="$1"

  if ! ssh_to_worker "${node_name}" "nohup sh -c 'sleep 1; systemctl restart tailscaled' >/tmp/tailscaled-restart.log 2>&1 </dev/null &"; then
    return 1
  fi

  wait_for_worker_ssh "${node_name}" &&
    ssh_to_worker "${node_name}" "systemctl is-active --quiet tailscaled"
}

restart_cilium_on_worker() {
  local node_name="$1"
  local cilium_pod ready_pod attempt

  cilium_pod="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${node_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${cilium_pod}" ]

  kubectl -n kube-system delete pod "${cilium_pod}" --wait=false >/dev/null
  kubectl -n kube-system wait --for=delete "pod/${cilium_pod}" --timeout=180s >/dev/null 2>&1 || true

  for attempt in $(seq 1 36); do
    ready_pod="$(
      kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${node_name}" \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
        | awk -v old_pod="${cilium_pod}" '$1 != old_pod && $2 == "Running" && $3 == "true" {print $1; exit}'
    )"
    if [ -n "${ready_pod}" ]; then
      return 0
    fi
    sleep 5
  done

  return 1
}

mapfile -t worker_nodes < <(kubectl get nodes --no-headers | awk '$1 ~ /^worker-/ && $2 ~ /^Ready/ {print $1}')

healthy_workers=0
cordoned_workers=()

for node_name in "${worker_nodes[@]}"; do
  echo "checking pod DNS on ${node_name}"

  if check_node_dns "${node_name}"; then
    healthy_workers=$((healthy_workers + 1))
    continue
  fi

  if restart_tailscaled_on_worker "${node_name}" && check_node_dns "${node_name}"; then
    healthy_workers=$((healthy_workers + 1))
    continue
  fi

  if restart_cilium_on_worker "${node_name}" && check_node_dns "${node_name}"; then
    healthy_workers=$((healthy_workers + 1))
    continue
  fi

  kubectl cordon "${node_name}" >/dev/null
  cordoned_workers+=("${node_name}")
done

echo "healthy worker nodes after DNS checks: ${healthy_workers}"
if [ "${#cordoned_workers[@]}" -gt 0 ]; then
  echo "cordoned worker nodes: ${cordoned_workers[*]}"
fi

if [ "${healthy_workers}" -lt "${MIN_HEALTHY_WORKERS}" ]; then
  kubectl get nodes
  exit 1
fi

kubectl get nodes
EOF
```

Install KEDA:

```sh
bash <<'EOF'
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
    sleep 5
  done

  return 1
}

kubectl apply --server-side --force-conflicts -f "${KEDA_MANIFEST_URL}"
kubectl -n keda rollout restart deployment/keda-operator deployment/keda-metrics-apiserver deployment/keda-admission >/dev/null
kubectl -n keda rollout status deployment/keda-operator --timeout=300s
wait_for_secret_data_key keda kedaorg-certs '{.data.tls\.crt}'

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

kubectl wait --for=condition=Established crd/scaledobjects.keda.sh --timeout=300s
kubectl wait --for=condition=Established crd/triggerauthentications.keda.sh --timeout=300s
kubectl -n keda rollout status deployment/keda-metrics-apiserver --timeout=300s
kubectl -n keda rollout status deployment/keda-admission --timeout=300s
kubectl wait --for=condition=Available apiservice/v1beta1.external.metrics.k8s.io --timeout=300s
kubectl -n keda get pods
EOF
```

Deploy Bookinfo, Redis, the ScaledObject, and the traffic generator:

```sh
bash <<'EOF'
set -euo pipefail

wait_for_scaledobject_ready() {
  local namespace="$1"
  local name="$2"

  for attempt in {1..30}; do
    if kubectl -n "${namespace}" get scaledobject "${name}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null | grep -q '^Ready=True$'; then
      return 0
    fi
    sleep 10
  done

  kubectl -n "${namespace}" describe scaledobject "${name}" >&2 || true
  kubectl -n keda get pods -o wide >&2 || true
  return 1
}

if kubectl get namespace demo >/dev/null 2>&1; then
  kubectl delete namespace demo --wait=true --timeout=300s
fi

kubectl apply -f ~/deployments/bookinfo.yaml
kubectl apply -f ~/deployments/async-queue-stack.yaml
kubectl apply -f ~/deployments/async-keda.yaml

for deploy in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 redis; do
  kubectl -n demo rollout status "deployment/${deploy}" --timeout=300s
done

wait_for_scaledobject_ready demo demo-worker

NODE_PORT=$(kubectl -n demo get svc productpage -o jsonpath='{.spec.ports[0].nodePort}')
PRODUCT_NODE=$(kubectl -n demo get pod -l app=productpage -o jsonpath='{.items[0].spec.nodeName}')

for attempt in {1..12}; do
  HTTP_CODE="$(
    curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "http://${PRODUCT_NODE}:${NODE_PORT}/productpage" || true
  )"
  if [ "${HTTP_CODE}" = "200" ]; then
    break
  fi
  sleep 5
done

[ "${HTTP_CODE}" = "200" ]

kubectl apply -f ~/deployments/bookinfo-traffic-generator.yaml
kubectl -n demo rollout status deployment/traffic-generator --timeout=300s
kubectl -n demo get hpa || true
kubectl -n demo get scaledobject
EOF
```

Run the smoke test suite:

```sh
bash <<'EOF'
set -euo pipefail

get_replicas() {
  local namespace="$1"
  local deployment="$2"
  kubectl -n "${namespace}" get deployment "${deployment}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
}

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
    sleep 10
  done
  return 1
}

assert_demo_deployments_available() {
  local deployment replicas available

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
    local worker queue_depth

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
      return 0
    fi
    sleep 20
  done

  return 1
}

assert_demo_spread() {
  local nodes
  nodes="$(get_demo_node_count)"
  echo "demo pods observed on ${nodes} worker nodes"
  [ "${nodes}" -ge 3 ]
}

assert_static_bookinfo_not_on_every_worker() {
  local total_workers deployment app version nodes

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
    exit 1
  fi
  sleep 2
done

cilium status || echo "cilium CLI not available, checking pods directly"
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide

CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec -i "${CILIUM_POD}" -- hubble observe --last 5 || echo "hubble observe not available yet"

kubectl -n demo get deploy
kubectl -n demo get hpa || true
kubectl -n demo get scaledobject

assert_demo_deployments_available
wait_for_scaledobject_ready
observe_keda_dynamics
assert_demo_deployments_available
kubectl -n demo get pods -o wide
assert_demo_spread
assert_static_bookinfo_not_on_every_worker
EOF
```

## What The Smoke Test Checks

The smoke test still covers the classic cluster checks:

1. data encryption at rest
2. a basic nginx deployment
3. port-forwarding
4. logs and `kubectl exec`
5. NodePort access
6. DNS resolution from a pod
7. Cilium and Hubble health

It then adds autoscaling verification:

1. `kubectl get scaledobject -n demo` shows `demo-worker` as `Ready`.
2. `demo-worker` scales above zero as queue bursts build up.
3. `demo-worker` later scales back down during idle cooldown windows.
4. Demo pods spread across several worker nodes, and no static Bookinfo service lands on every worker.

## Useful Manual Commands

If you want to watch the demo live from the jumpbox:

```sh
kubectl -n demo get deploy demo-worker -w
```

```sh
kubectl -n demo get scaledobject -w
```

```sh
kubectl -n demo get hpa
```

```sh
kubectl -n demo exec deploy/redis -- redis-cli LLEN demo-jobs
```

```sh
kubectl -n demo get pods -o wide
```

If you also deployed the visualizer in step 14, Hubble-gazer should show the Bookinfo traffic waves and the Redis/worker activity changing as KEDA reacts to queue bursts and cooldowns.

Next: [Optional: Hubble Gazer Visualizer](14-hubble-gazer-visualizer.md)
