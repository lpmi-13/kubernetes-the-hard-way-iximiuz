#!/usr/bin/env bash
set -euo pipefail

CONTROL_PLANE_PLAYGROUND_ID="$(labctl playground list -o json | jq -r '.[] | select(any(.machines[]; .name == "load-balancer")) | .id')"
JUMPBOX_PLAYGROUND_ID="$(labctl playground list -o json | jq -r '.[] | select((.machines | length == 1) and (.machines[0].name == "jumpbox")) | .id')"
failures=0

if [ -z "${CONTROL_PLANE_PLAYGROUND_ID}" ] || [ "${CONTROL_PLANE_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find control-plane playground id" >&2
  exit 1
fi

if [ -z "${JUMPBOX_PLAYGROUND_ID}" ] || [ "${JUMPBOX_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find jumpbox playground id" >&2
  exit 1
fi

check_service() {
  local machine="$1"
  local service="$2"

  if labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine "${machine}" "systemctl is-active --quiet ${service}"; then
    return 0
  fi

  echo "${machine}: ${service} is not active" >&2
  labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine "${machine}" "systemctl status ${service} --no-pager -l || true" >&2 || true
  labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine "${machine}" "journalctl -u ${service} --no-pager -n 80 || true" >&2 || true
  failures=$((failures + 1))
}

for controller in controller-1 controller-2 controller-3; do
  check_service "${controller}" kube-apiserver
  check_service "${controller}" kube-controller-manager
  check_service "${controller}" kube-scheduler
done

check_service load-balancer haproxy

if ! labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine load-balancer "ss -ltn | grep -q ':6443'"; then
  echo "load-balancer: nothing is listening on :6443" >&2
  labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine load-balancer "ss -ltn || true" >&2 || true
  failures=$((failures + 1))
fi

if ! labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine controller-1 "kubectl get --raw='/readyz' --kubeconfig /root/admin.kubeconfig >/dev/null"; then
  echo "controller-1: API server is not ready via admin.kubeconfig" >&2
  labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine controller-1 "kubectl get --raw='/readyz?verbose' --kubeconfig /root/admin.kubeconfig || true" >&2 || true
  failures=$((failures + 1))
fi

if ! labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "curl -skf --connect-timeout 5 --cacert ~/ca.crt https://server.kubernetes.local:6443/version >/dev/null"; then
  echo "jumpbox: API endpoint server.kubernetes.local:6443 is not reachable" >&2
  labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "getent hosts server.kubernetes.local || true; curl -sk --connect-timeout 5 --cacert ~/ca.crt https://server.kubernetes.local:6443/version || true" >&2 || true
  failures=$((failures + 1))
fi

if [ "${failures}" -gt 0 ]; then
  echo "control-plane validation failed with ${failures} issue(s)" >&2
  exit 1
fi

echo "control-plane validation passed."
