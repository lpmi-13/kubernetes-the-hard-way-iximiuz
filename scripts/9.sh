#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wait_for_worker_nodes_registered() {
  local node_output worker_count

  for _ in {1..90}; do
    node_output="$(labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'" 2>/dev/null || true)"
    worker_count="$(printf '%s\n' "${node_output}" | awk '$1 ~ /^worker-/ {count++} END {print count+0}')"
    if [ "${worker_count}" -ge 9 ]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

JUMPBOX_PLAYGROUND_ID="$(labctl playground list -o json | jq -r '.[] | select((.machines | length == 1) and (.machines[0].name == "jumpbox")) | .id')"
if [ -z "${JUMPBOX_PLAYGROUND_ID}" ] || [ "${JUMPBOX_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find jumpbox playground id" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/check_control_plane.sh"

labctl cp "${REPO_ROOT}/scripts/bootstrap_workers.sh" "${JUMPBOX_PLAYGROUND_ID}":~/bootstrap_workers.sh
labctl cp "${REPO_ROOT}/scripts/bootstrap_workers_on_jumpbox.sh" "${JUMPBOX_PLAYGROUND_ID}":~/bootstrap_workers_on_jumpbox.sh
labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "rm -rf ~/configs ~/units"
labctl cp -r "${REPO_ROOT}/configs" "${JUMPBOX_PLAYGROUND_ID}":~/configs
labctl cp -r "${REPO_ROOT}/units" "${JUMPBOX_PLAYGROUND_ID}":~/units

labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/bootstrap_workers_on_jumpbox.sh"

if ! wait_for_worker_nodes_registered; then
  echo "timed out waiting for all worker nodes to appear" >&2
  exit 1
fi

labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'"
