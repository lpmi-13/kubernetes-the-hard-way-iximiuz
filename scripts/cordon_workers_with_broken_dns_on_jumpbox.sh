#!/usr/bin/env bash
set -euo pipefail

MIN_HEALTHY_WORKERS="${MIN_HEALTHY_WORKERS:-3}"
DNS_CHECK_NAMESPACE="${DNS_CHECK_NAMESPACE:-default}"
DNS_CHECK_IMAGE="${DNS_CHECK_IMAGE:-ghcr.io/lpmi-13/busybox:1.28.4}"
DNS_CHECK_HOSTNAME="${DNS_CHECK_HOSTNAME:-kubernetes.default.svc.cluster.local}"
DNS_CHECK_TIMEOUT_SECONDS="${DNS_CHECK_TIMEOUT_SECONDS:-15}"
DEFAULT_HOME="${HOME:-/root}"
export HOME="${DEFAULT_HOME}"
SSH_KEY="${SSH_KEY:-${DEFAULT_HOME}/.ssh/kubernetes.ed25519}"
KUBECONFIG="${KUBECONFIG:-${DEFAULT_HOME}/.kube/config}"
export KUBECONFIG
WORKER_SSH_USER="${WORKER_SSH_USER:-root}"
WORKER_SSH_TIMEOUT_SECONDS="${WORKER_SSH_TIMEOUT_SECONDS:-10}"
WORKER_REPAIR_RETRY_ATTEMPTS="${WORKER_REPAIR_RETRY_ATTEMPTS:-12}"
WORKER_REPAIR_RETRY_DELAY_SECONDS="${WORKER_REPAIR_RETRY_DELAY_SECONDS:-5}"
AUTO_UNCORDON_HEALTHY_CHECKS="${AUTO_UNCORDON_HEALTHY_CHECKS:-3}"
HEALER_LOCK_FILE="${HEALER_LOCK_FILE:-/tmp/worker-dns-healer.lock}"
HEALER_MANAGED_ANNOTATION="${HEALER_MANAGED_ANNOTATION:-kthw.iximiuz.com/worker-dns-healer-managed}"
HEALER_HEALTHY_PASSES_ANNOTATION="${HEALER_HEALTHY_PASSES_ANNOTATION:-kthw.iximiuz.com/worker-dns-healer-healthy-passes}"
HEALER_LAST_ACTION_ANNOTATION="${HEALER_LAST_ACTION_ANNOTATION:-kthw.iximiuz.com/worker-dns-healer-last-action}"

exec 9>"${HEALER_LOCK_FILE}"
if ! flock -n 9; then
  echo "[preflight] another worker DNS healer run is already in progress"
  exit 0
fi

get_node_annotation() {
  local node_name="$1"
  local annotation_key="$2"
  local escaped_key

  escaped_key="${annotation_key//./\\.}"
  escaped_key="${escaped_key//\//\\/}"
  kubectl get node "${node_name}" -o "jsonpath={.metadata.annotations.${escaped_key}}" 2>/dev/null || true
}

node_is_unschedulable() {
  local node_name="$1"
  kubectl get node "${node_name}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true
}

set_healer_annotations() {
  local node_name="$1"
  local healthy_passes="$2"
  local last_action="$3"

  kubectl annotate node "${node_name}" \
    "${HEALER_MANAGED_ANNOTATION}=true" \
    "${HEALER_HEALTHY_PASSES_ANNOTATION}=${healthy_passes}" \
    "${HEALER_LAST_ACTION_ANNOTATION}=${last_action}" \
    --overwrite >/dev/null
}

clear_healer_annotations() {
  local node_name="$1"

  kubectl annotate node "${node_name}" \
    "${HEALER_MANAGED_ANNOTATION}-" \
    "${HEALER_HEALTHY_PASSES_ANNOTATION}-" \
    "${HEALER_LAST_ACTION_ANNOTATION}-" \
    >/dev/null 2>&1 || true
}

handle_healthy_node() {
  local node_name="$1"
  local managed_by_healer
  local unschedulable
  local healthy_passes

  managed_by_healer="$(get_node_annotation "${node_name}" "${HEALER_MANAGED_ANNOTATION}")"
  unschedulable="$(node_is_unschedulable "${node_name}")"

  if [ "${managed_by_healer}" != "true" ]; then
    return 0
  fi

  if [ "${unschedulable}" != "true" ]; then
    clear_healer_annotations "${node_name}"
    echo "[preflight] ${node_name}: healthy and already schedulable; cleared healer annotations"
    return 0
  fi

  healthy_passes="$(get_node_annotation "${node_name}" "${HEALER_HEALTHY_PASSES_ANNOTATION}")"
  if ! [[ "${healthy_passes}" =~ ^[0-9]+$ ]]; then
    healthy_passes=0
  fi
  healthy_passes=$((healthy_passes + 1))

  if [ "${healthy_passes}" -lt "${AUTO_UNCORDON_HEALTHY_CHECKS}" ]; then
    set_healer_annotations "${node_name}" "${healthy_passes}" "healthy-but-cordoned"
    echo "[preflight] ${node_name}: healthy check ${healthy_passes}/${AUTO_UNCORDON_HEALTHY_CHECKS} before auto-uncordon"
    return 1
  fi

  echo "[preflight] ${node_name}: auto-uncordoning after ${healthy_passes} consecutive healthy checks"
  kubectl uncordon "${node_name}" >/dev/null
  clear_healer_annotations "${node_name}"
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

  echo "[preflight] ${node_name}: scheduling tailscaled restart"
  if ! ssh_to_worker "${node_name}" "nohup sh -c 'sleep 1; systemctl restart tailscaled' >/tmp/tailscaled-restart.log 2>&1 </dev/null &"; then
    echo "[preflight] ${node_name}: failed to schedule tailscaled restart" >&2
    return 1
  fi

  if ! wait_for_worker_ssh "${node_name}"; then
    echo "[preflight] ${node_name}: SSH did not recover after tailscaled restart" >&2
    return 1
  fi

  if ! ssh_to_worker "${node_name}" "systemctl is-active --quiet tailscaled"; then
    echo "[preflight] ${node_name}: tailscaled is not active after restart" >&2
    return 1
  fi

  echo "[preflight] ${node_name}: tailscaled restart completed"
  return 0
}

restart_cilium_on_worker() {
  local node_name="$1"
  local cilium_pod=""
  local ready_pod=""
  local attempt

  cilium_pod="$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${node_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${cilium_pod}" ]; then
    echo "[preflight] ${node_name}: no Cilium pod found to restart" >&2
    return 1
  fi

  echo "[preflight] ${node_name}: restarting Cilium pod ${cilium_pod}"
  kubectl -n kube-system delete pod "${cilium_pod}" --wait=false >/dev/null
  kubectl -n kube-system wait --for=delete "pod/${cilium_pod}" --timeout=180s >/dev/null 2>&1 || true

  for attempt in $(seq 1 36); do
    ready_pod="$(
      kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${node_name}" \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
        | awk -v old_pod="${cilium_pod}" '$1 != old_pod && $2 == "Running" && $3 == "true" {print $1; exit}'
    )"
    if [ -n "${ready_pod}" ]; then
      echo "[preflight] ${node_name}: Cilium pod ${ready_pod} is Ready"
      return 0
    fi
    sleep 5
  done

  echo "[preflight] ${node_name}: Cilium pod did not become Ready after restart" >&2
  kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=${node_name}" -o wide >&2 || true
  return 1
}

repair_node_dns() {
  local node_name="$1"

  if restart_tailscaled_on_worker "${node_name}" && check_node_dns "${node_name}"; then
    echo "[preflight] ${node_name}: DNS recovered after tailscaled restart"
    return 0
  fi

  if restart_cilium_on_worker "${node_name}" && check_node_dns "${node_name}"; then
    echo "[preflight] ${node_name}: DNS recovered after Cilium restart"
    return 0
  fi

  return 1
}

mark_node_still_unhealthy() {
  local node_name="$1"
  local managed_by_healer
  local unschedulable

  managed_by_healer="$(get_node_annotation "${node_name}" "${HEALER_MANAGED_ANNOTATION}")"
  unschedulable="$(node_is_unschedulable "${node_name}")"

  if [ "${unschedulable}" = "true" ] && [ "${managed_by_healer}" != "true" ]; then
    echo "[preflight] ${node_name}: unhealthy but already cordoned outside the healer; leaving it unchanged"
    return 0
  fi

  if [ "${unschedulable}" != "true" ]; then
    echo "[preflight] ${node_name}: cordoning node after failed pod DNS check"
    kubectl cordon "${node_name}" >/dev/null
  else
    echo "[preflight] ${node_name}: keeping node cordoned after failed repair attempts"
  fi

  set_healer_annotations "${node_name}" "0" "cordoned-for-broken-dns"
  return 0
}

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
    echo "[preflight] ${node_name}: probe pod did not become Ready" >&2
    cleanup_probe_pod "${pod_name}"
    return 1
  fi

  if ! timeout "${DNS_CHECK_TIMEOUT_SECONDS}" \
    kubectl -n "${DNS_CHECK_NAMESPACE}" exec "${pod_name}" -- nslookup "${DNS_CHECK_HOSTNAME}" >/dev/null 2>&1; then
    echo "[preflight] ${node_name}: pod DNS lookup failed for ${DNS_CHECK_HOSTNAME}" >&2
    cleanup_probe_pod "${pod_name}"
    return 1
  fi

  cleanup_probe_pod "${pod_name}"
  return 0
}

mapfile -t worker_nodes < <(kubectl get nodes --no-headers | awk '$1 ~ /^worker-/ && $2 ~ /^Ready/ {print $1}')

if [ "${#worker_nodes[@]}" -eq 0 ]; then
  echo "[preflight] no Ready worker nodes found" >&2
  exit 1
fi

healthy_workers=0
cordoned_workers=()

for node_name in "${worker_nodes[@]}"; do
  echo "[preflight] checking pod DNS on ${node_name}"

  if check_node_dns "${node_name}"; then
    echo "[preflight] ${node_name}: pod DNS OK"
    if handle_healthy_node "${node_name}"; then
      healthy_workers=$((healthy_workers + 1))
    fi
    continue
  fi

  echo "[preflight] ${node_name}: attempting repair after failed pod DNS check"
  if repair_node_dns "${node_name}"; then
    if handle_healthy_node "${node_name}"; then
      healthy_workers=$((healthy_workers + 1))
    fi
    continue
  fi

  mark_node_still_unhealthy "${node_name}"
  cordoned_workers+=("${node_name}")
done

echo "[preflight] healthy worker nodes after DNS checks: ${healthy_workers}"
if [ "${#cordoned_workers[@]}" -gt 0 ]; then
  echo "[preflight] cordoned worker nodes: ${cordoned_workers[*]}"
fi

if [ "${healthy_workers}" -lt "${MIN_HEALTHY_WORKERS}" ]; then
  echo "[preflight] fewer than ${MIN_HEALTHY_WORKERS} healthy worker nodes remain after DNS checks" >&2
  kubectl get nodes
  exit 1
fi

kubectl get nodes
