# Optional: Hubble Gazer Visualizer

In this optional lab you will deploy [hubble-gazer](https://github.com/lpmi-13/hubble-gazer) `0.6.2`, a web UI that consumes Hubble Relay flow data and renders a live service traffic graph in your browser.

This guide assumes `HUBBLE_RELAY_ADDR=hubble-relay-grpc.kube-system.svc.cluster.local:4245`.
The provided manifest deploys `ghcr.io/lpmi-13/hubble-gazer:0.6.2`.
Because this self-hosted Cilium cluster exposes the Kubernetes API through the special `default/kubernetes` service, the manifest also installs a scoped `CiliumNetworkPolicy` that allows egress to the `kube-apiserver` entity so the pod metadata informer can resolve `pod.spec.nodeName` for `Pods by Node`.
The Hubble Gazer manifest uses two replicas behind a `ClusterIP` Service for the existing jumpbox `kubectl port-forward` workflow, and also creates a dedicated `NodePort` Service on port `30080` for direct worker-node access.
Step 13 also installs a scoped `CiliumNetworkPolicy` for the Bookinfo request path so the `Application (L7)` tab can show HTTP traffic instead of only L4 flows.

Step 13 now keeps the demo namespace intentionally compact, with a 9-pod static baseline and an 18-pod ceiling during worker scale-out, so the graph is easier to read.

## Prerequisites

- Step 11 (Cilium + Hubble) completed
- Step 12 (CoreDNS) completed
- Step 13 (smoke tests) completed

## 1) Identify the jumpbox playground (local machine)

Run from this repository root:

```sh
JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
echo "${JUMPBOX_PLAYGROUND_ID}"
```

## 2) Copy deployment manifest to the jumpbox (local machine)

```sh
labctl cp -r ./deployments "${JUMPBOX_PLAYGROUND_ID}":~/deployments
```

## 3) Deploy hubble-gazer and wait for rollout (via jumpbox)

```sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kubectl -n kube-system rollout status deployment/hubble-relay --timeout=180s"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kubectl apply -f ~/deployments/hubble-gazer.yaml"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kubectl -n kube-system rollout status deployment/hubble-gazer --timeout=180s"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kubectl -n kube-system get pods -l app=hubble-gazer -o wide"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kubectl -n kube-system get svc hubble-gazer"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kubectl -n kube-system get svc hubble-gazer-nodeport"
```

The direct worker-node entrypoint is:

```txt
http://<worker-node-host-or-ip>:30080
```

Important: `3000` is the container and Service port, not a port bound on the worker itself.
If you want to expose a worker VM directly, expose `30080`, not `3000`.
Because this is a `NodePort`, any worker node can serve it, even if the selected Hubble Gazer pod is running on a different worker.

You can verify the direct path from the jumpbox with:

```sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" '
set -euo pipefail
NODE_PORT=$(kubectl -n kube-system get svc hubble-gazer-nodeport -o jsonpath="{.spec.ports[0].nodePort}")
for node in $(kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{\"\n\"}{end}"); do
  echo "checking http://${node}:${NODE_PORT}/readyz"
  curl -fsS "http://${node}:${NODE_PORT}/readyz"
  echo
done
'
```

## 4) Start jumpbox port-forward to the Hubble Gazer Service

```sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" '
set -euo pipefail
pid_file=/tmp/hubble-gazer-portforward.pid
log_file=/tmp/hubble-gazer-portforward.log

if [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
  kill "$(cat "${pid_file}")" 2>/dev/null || true
  sleep 1
fi

rm -f "${pid_file}" "${log_file}"
nohup kubectl -n kube-system port-forward --address 0.0.0.0 svc/hubble-gazer 3000:3000 >"${log_file}" 2>&1 < /dev/null &
echo $! > "${pid_file}"
sleep 1
tail -n 5 "${log_file}" || true
'
```

If your browser runs on another VM that can reach the jumpbox directly, open:

```txt
http://<jumpbox-host-or-ip>:3000
```

## 5) Start local labctl port-forward to the jumpbox listener

```sh
LOCAL_PID_FILE="${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-8888.pid"
LOCAL_LOG_FILE="${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-8888.log"

for stale_pid_file in "${TMPDIR:-/tmp}"/kthw-hubble-gazer-*-labctl-portforward-8888.pid; do
  [ -e "${stale_pid_file}" ] || continue
  stale_pid="$(cat "${stale_pid_file}" 2>/dev/null || true)"
  if [ -z "${stale_pid}" ] || ! kill -0 "${stale_pid}" 2>/dev/null; then
    rm -f "${stale_pid_file}" "${stale_pid_file%.pid}.log"
  fi
done

if [ -f "${LOCAL_PID_FILE}" ] && kill -0 "$(cat "${LOCAL_PID_FILE}")" 2>/dev/null; then
  echo "local labctl port-forward already running (pid $(cat "${LOCAL_PID_FILE}"))"
else
  nohup labctl port-forward "${JUMPBOX_PLAYGROUND_ID}" -L 8888:3000 >"${LOCAL_LOG_FILE}" 2>&1 < /dev/null &
  echo $! > "${LOCAL_PID_FILE}"
  echo "started local labctl port-forward (pid $(cat "${LOCAL_PID_FILE}"))"
fi
```

## 6) Verify localhost is ready

```sh
for _ in $(seq 1 40); do
  if [ "$(curl -fsS http://127.0.0.1:8888/readyz 2>/dev/null || true)" = "ok" ]; then
    echo "hubble-gazer is reachable at http://localhost:8888"
    break
  fi
  sleep 1
done
```

## Open the UI

Open:

```txt
http://localhost:8888
```

## Trigger Live Scaling From Your Local Machine

With Hubble-gazer open, you can scale the Bookinfo traffic generator without
opening an interactive shell on the jumpbox:

```sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" '
set -euo pipefail
kubectl -n demo scale deployment/traffic-generator --replicas=3
kubectl -n demo rollout status deployment/traffic-generator --timeout=300s
kubectl -n demo get deployment/traffic-generator
kubectl -n demo get pods -l app=traffic-generator -o wide
'
```

Scale it back down later:

```sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" '
set -euo pipefail
kubectl -n demo scale deployment/traffic-generator --replicas=1
kubectl -n demo rollout status deployment/traffic-generator --timeout=300s
kubectl -n demo get deployment/traffic-generator
kubectl -n demo get pods -l app=traffic-generator -o wide
'
```

## Stop background forwards later

```sh
kill "$(cat "${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-8888.pid")"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kill \$(cat /tmp/hubble-gazer-portforward.pid)"
```

Next: [Cleanup](15-cleanup.md)
