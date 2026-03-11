#!/usr/bin/env bash
set -euo pipefail

HUBBLE_GAZER_VERSION="0.3.0"
HUBBLE_LOCAL_UI_PORT=8888
HUBBLE_JUMPBOX_FORWARD_PORT=3000
BOOKINFO_LOCAL_UI_PORT=5000
BOOKINFO_JUMPBOX_FORWARD_PORT=5000

retry_cmd() {
  local max_attempts="$1"
  shift

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    echo "command failed; retrying (${attempt}/${max_attempts})..." >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

ensure_local_port_forward() {
  local jumpbox_id="$1"
  local name="$2"
  local local_port="$3"
  local jumpbox_port="$4"
  local pid_file="${TMPDIR:-/tmp}/kthw-${name}-${jumpbox_id}-labctl-portforward-${local_port}.pid"
  local log_file="${TMPDIR:-/tmp}/kthw-${name}-${jumpbox_id}-labctl-portforward-${local_port}.log"

  if [ -f "${pid_file}" ]; then
    local existing_pid
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
      echo "${existing_pid}"
      return 0
    fi
  fi

  nohup labctl port-forward "${jumpbox_id}" -L "${local_port}:${jumpbox_port}" >"${log_file}" 2>&1 < /dev/null &
  local pf_pid=$!
  echo "${pf_pid}" > "${pid_file}"
  sleep 1
  if ! kill -0 "${pf_pid}" 2>/dev/null; then
    echo "local labctl port-forward failed to start; recent log output:" >&2
    tail -n 30 "${log_file}" >&2 || true
    return 1
  fi

  echo "${pf_pid}"
}

ensure_jumpbox_service_port_forward() {
  local jumpbox_id="$1"
  local name="$2"
  local namespace="$3"
  local service="$4"
  local local_port="$5"
  local target_port="$6"

  local remote_cmd
  remote_cmd="$(cat <<EOF
set -euo pipefail
pid_file=/tmp/${name}-portforward.pid
log_file=/tmp/${name}-portforward.log

if [ -f "\${pid_file}" ]; then
  existing_pid="\$(cat "\${pid_file}" 2>/dev/null || true)"
  if [ -n "\${existing_pid}" ] && kill -0 "\${existing_pid}" 2>/dev/null; then
    echo "\${existing_pid}"
    exit 0
  fi
fi

nohup kubectl -n ${namespace} port-forward --address 0.0.0.0 svc/${service} ${local_port}:${target_port} >"\${log_file}" 2>&1 < /dev/null &
new_pid=\$!
echo "\${new_pid}" > "\${pid_file}"
sleep 1

if ! kill -0 "\${new_pid}" 2>/dev/null; then
  tail -n 30 "\${log_file}" >&2 || true
  exit 1
fi

echo "\${new_pid}"
EOF
)"

  retry_cmd 5 labctl ssh "${jumpbox_id}" "bash -lc '${remote_cmd}'" | tail -n 1
}

wait_for_local_healthz() {
  local url="$1"
  local expected_body="$2"
  local attempts="${3:-40}"

  for _ in $(seq 1 "${attempts}"); do
    if [ "$(curl -fsS "${url}" 2>/dev/null || true)" = "${expected_body}" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_local_http_ok() {
  local url="$1"
  local attempts="${2:-40}"

  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS -o /dev/null "${url}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
if [ -z "${JUMPBOX_PLAYGROUND_ID}" ] || [ "${JUMPBOX_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find jumpbox playground id" >&2
  exit 1
fi

retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "rm -rf ~/deployments"
retry_cmd 5 labctl cp -r ./deployments "${JUMPBOX_PLAYGROUND_ID}":~/deployments
retry_cmd 5 labctl cp ./scripts/deploy_hubble_gazer_on_jumpbox.sh "${JUMPBOX_PLAYGROUND_ID}":~/deploy_hubble_gazer_on_jumpbox.sh

retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/deploy_hubble_gazer_on_jumpbox.sh"

echo "starting jumpbox port-forward for hubble-gazer service"
HUBBLE_JUMPBOX_PF_PID="$(
  ensure_jumpbox_service_port_forward \
    "${JUMPBOX_PLAYGROUND_ID}" \
    "hubble-gazer" \
    "kube-system" \
    "hubble-gazer" \
    "${HUBBLE_JUMPBOX_FORWARD_PORT}" \
    "3000"
)"

echo "starting local labctl port-forward for hubble-gazer"
HUBBLE_LOCAL_PF_PID="$(
  ensure_local_port_forward \
    "${JUMPBOX_PLAYGROUND_ID}" \
    "hubble-gazer" \
    "${HUBBLE_LOCAL_UI_PORT}" \
    "${HUBBLE_JUMPBOX_FORWARD_PORT}"
)"

if ! wait_for_local_healthz "http://127.0.0.1:${HUBBLE_LOCAL_UI_PORT}/healthz" "ok"; then
  echo "hubble-gazer did not become reachable at http://localhost:${HUBBLE_LOCAL_UI_PORT}/healthz" >&2
  echo "local port-forward log: ${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-${HUBBLE_LOCAL_UI_PORT}.log" >&2
  labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "tail -n 30 /tmp/hubble-gazer-portforward.log" >&2 || true
  exit 1
fi

echo "starting jumpbox port-forward for Bookinfo productpage"
BOOKINFO_JUMPBOX_PF_PID="$(
  ensure_jumpbox_service_port_forward \
    "${JUMPBOX_PLAYGROUND_ID}" \
    "bookinfo-productpage" \
    "demo" \
    "productpage" \
    "${BOOKINFO_JUMPBOX_FORWARD_PORT}" \
    "9080"
)"

echo "starting local labctl port-forward for Bookinfo productpage"
BOOKINFO_LOCAL_PF_PID="$(
  ensure_local_port_forward \
    "${JUMPBOX_PLAYGROUND_ID}" \
    "bookinfo-productpage" \
    "${BOOKINFO_LOCAL_UI_PORT}" \
    "${BOOKINFO_JUMPBOX_FORWARD_PORT}"
)"

if ! wait_for_local_http_ok "http://127.0.0.1:${BOOKINFO_LOCAL_UI_PORT}/productpage"; then
  echo "Bookinfo productpage did not become reachable at http://localhost:${BOOKINFO_LOCAL_UI_PORT}/productpage" >&2
  echo "local port-forward log: ${TMPDIR:-/tmp}/kthw-bookinfo-productpage-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-${BOOKINFO_LOCAL_UI_PORT}.log" >&2
  labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "tail -n 30 /tmp/bookinfo-productpage-portforward.log" >&2 || true
  exit 1
fi

cat <<EOF

Visualizer is deployed.
Release: hubble-gazer ${HUBBLE_GAZER_VERSION}
Port-forwarding is active and verified.
Open Hubble Gazer: http://localhost:${HUBBLE_LOCAL_UI_PORT}
Open Bookinfo: http://localhost:${BOOKINFO_LOCAL_UI_PORT}/productpage

Port-forward processes:
  - hubble-gazer jumpbox kubectl port-forward pid: ${HUBBLE_JUMPBOX_PF_PID}
  - hubble-gazer local labctl port-forward pid: ${HUBBLE_LOCAL_PF_PID}
  - bookinfo jumpbox kubectl port-forward pid: ${BOOKINFO_JUMPBOX_PF_PID}
  - bookinfo local labctl port-forward pid: ${BOOKINFO_LOCAL_PF_PID}

To stop forwarding later:
  - hubble-gazer local: kill \$(cat ${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-${HUBBLE_LOCAL_UI_PORT}.pid)
  - hubble-gazer jumpbox: labctl ssh ${JUMPBOX_PLAYGROUND_ID} "kill \$(cat /tmp/hubble-gazer-portforward.pid)"
  - bookinfo local: kill \$(cat ${TMPDIR:-/tmp}/kthw-bookinfo-productpage-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-${BOOKINFO_LOCAL_UI_PORT}.pid)
  - bookinfo jumpbox: labctl ssh ${JUMPBOX_PLAYGROUND_ID} "kill \$(cat /tmp/bookinfo-productpage-portforward.pid)"
EOF
