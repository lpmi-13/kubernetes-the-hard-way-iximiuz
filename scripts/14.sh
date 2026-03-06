#!/usr/bin/env bash
set -euo pipefail

LOCAL_UI_PORT=8888
JUMPBOX_FORWARD_PORT=3000

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
  local pid_file="${TMPDIR:-/tmp}/kthw-hubble-gazer-${jumpbox_id}-labctl-portforward-${LOCAL_UI_PORT}.pid"
  local log_file="${TMPDIR:-/tmp}/kthw-hubble-gazer-${jumpbox_id}-labctl-portforward-${LOCAL_UI_PORT}.log"

  if [ -f "${pid_file}" ]; then
    local existing_pid
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
      echo "${existing_pid}"
      return 0
    fi
  fi

  nohup labctl port-forward "${jumpbox_id}" -L "${LOCAL_UI_PORT}:${JUMPBOX_FORWARD_PORT}" >"${log_file}" 2>&1 < /dev/null &
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

ensure_jumpbox_port_forward() {
  local jumpbox_id="$1"

  local remote_cmd='
set -euo pipefail
pid_file=/tmp/hubble-gazer-portforward.pid
log_file=/tmp/hubble-gazer-portforward.log

if [ -f "${pid_file}" ]; then
  existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
  if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
    echo "${existing_pid}"
    exit 0
  fi
fi

nohup kubectl -n kube-system port-forward --address 0.0.0.0 svc/hubble-gazer 3000:3000 >"${log_file}" 2>&1 < /dev/null &
new_pid=$!
echo "${new_pid}" > "${pid_file}"
sleep 1

if ! kill -0 "${new_pid}" 2>/dev/null; then
  tail -n 30 "${log_file}" >&2 || true
  exit 1
fi

echo "${new_pid}"
'

  retry_cmd 5 labctl ssh "${jumpbox_id}" "bash -lc '${remote_cmd}'" | tail -n 1
}

wait_for_local_visualizer() {
  local attempts=40
  for _ in $(seq 1 "${attempts}"); do
    if [ "$(curl -fsS "http://127.0.0.1:${LOCAL_UI_PORT}/healthz" 2>/dev/null || true)" = "ok" ]; then
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

retry_cmd 5 labctl cp -r ./deployments "${JUMPBOX_PLAYGROUND_ID}":~/deployments
retry_cmd 5 labctl cp ./scripts/deploy_hubble_gazer_on_jumpbox.sh "${JUMPBOX_PLAYGROUND_ID}":~/deploy_hubble_gazer_on_jumpbox.sh

retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/deploy_hubble_gazer_on_jumpbox.sh"

echo "starting jumpbox port-forward for hubble-gazer service"
JUMPBOX_PF_PID="$(ensure_jumpbox_port_forward "${JUMPBOX_PLAYGROUND_ID}")"

echo "starting local labctl port-forward"
LOCAL_PF_PID="$(ensure_local_port_forward "${JUMPBOX_PLAYGROUND_ID}")"

if ! wait_for_local_visualizer; then
  echo "hubble-gazer did not become reachable at http://localhost:${LOCAL_UI_PORT}/healthz" >&2
  echo "local port-forward log: ${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-${LOCAL_UI_PORT}.log" >&2
  labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "tail -n 30 /tmp/hubble-gazer-portforward.log" >&2 || true
  exit 1
fi

cat <<EOF

Visualizer is deployed.
Port-forwarding is active and verified.
Open: http://localhost:${LOCAL_UI_PORT}

Port-forward processes:
  - jumpbox kubectl port-forward pid: ${JUMPBOX_PF_PID}
  - local labctl port-forward pid: ${LOCAL_PF_PID}

To stop forwarding later:
  - local: kill \$(cat ${TMPDIR:-/tmp}/kthw-hubble-gazer-${JUMPBOX_PLAYGROUND_ID}-labctl-portforward-${LOCAL_UI_PORT}.pid)
  - jumpbox: labctl ssh ${JUMPBOX_PLAYGROUND_ID} "kill \$(cat /tmp/hubble-gazer-portforward.pid)"
EOF
