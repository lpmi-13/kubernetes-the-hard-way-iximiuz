# Optional: Hubble Gazer Visualizer

In this optional lab you will deploy [hubble-gazer](https://github.com/lpmi-13/hubble-gazer) `0.3.0`, a web UI that consumes Hubble Relay flow data and renders a live service traffic graph in your browser.

This guide assumes `HUBBLE_RELAY_ADDR=hubble-relay.kube-system.svc.cluster.local:80` (the relay Service port in this cluster).
The provided manifest deploys `ghcr.io/lpmi-13/hubble-gazer:0.3.0`.

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
```

## 4) Start jumpbox service port-forward in background

```sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" '
set -euo pipefail
PID_FILE=/tmp/hubble-gazer-portforward.pid
LOG_FILE=/tmp/hubble-gazer-portforward.log

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "jumpbox port-forward already running (pid $(cat "${PID_FILE}"))"
  exit 0
fi

nohup kubectl -n kube-system port-forward --address 0.0.0.0 svc/hubble-gazer 3000:3000 >"${LOG_FILE}" 2>&1 < /dev/null &
echo $! > "${PID_FILE}"
echo "started jumpbox port-forward (pid $(cat "${PID_FILE}"))"
'
```

## 5) Start local labctl port-forward in background

```sh
LOCAL_PID_FILE="${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-8888.pid"
LOCAL_LOG_FILE="${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-8888.log"

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
  if [ "$(curl -fsS http://127.0.0.1:8888/healthz 2>/dev/null || true)" = "ok" ]; then
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

## Stop background forwards later

```sh
kill "$(cat "${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-8888.pid")"
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "kill \$(cat /tmp/hubble-gazer-portforward.pid)"
```

Next: [Cleanup](15-cleanup.md)
