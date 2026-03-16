#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="$(mktemp -d)"
trap 'rm -rf "${ARTIFACT_DIR}"' EXIT
WORKER_BUNDLE_DIR="${ARTIFACT_DIR}/worker-bootstrap"

wait_for_worker_nodes_registered() {
  local node_output worker_count

  for _ in {1..90}; do
    node_output="$(labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'" 2>/dev/null || true)"
    worker_count="$(printf '%s\n' "${node_output}" | awk '$1 ~ /^worker-/ {count++} END {print count+0}')"
    if [ "${worker_count}" -ge 5 ]; then
      return 0
    fi
    sleep 2
  done

  return 1
}

JUMPBOX_PLAYGROUND_ID="$(labctl playground list -o json | jq -r '.[] | select((.machines | length == 1) and (.machines[0].name == "jumpbox")) | .id')"
WORKER_PLAYGROUNDS=($(labctl playground list -o json | jq -r '.[] | select(any(.machines[]; .name | test("^worker-"))) | .id'))
if [ -z "${JUMPBOX_PLAYGROUND_ID}" ] || [ "${JUMPBOX_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find jumpbox playground id" >&2
  exit 1
fi

bash "${REPO_ROOT}/scripts/check_control_plane.sh"

mkdir -p "${WORKER_BUNDLE_DIR}/worker"
for binary in containerd containerd-shim-runc-v2 runc kubelet; do
  labctl cp "${JUMPBOX_PLAYGROUND_ID}:~/downloads/worker/${binary}" "${WORKER_BUNDLE_DIR}/worker/${binary}"
done
labctl cp "${JUMPBOX_PLAYGROUND_ID}:~/ca.crt" "${ARTIFACT_DIR}/ca.crt"
for worker_name in worker-{1..5}; do
  labctl cp "${JUMPBOX_PLAYGROUND_ID}:~/${worker_name}.crt" "${ARTIFACT_DIR}/${worker_name}.crt"
  labctl cp "${JUMPBOX_PLAYGROUND_ID}:~/${worker_name}.key" "${ARTIFACT_DIR}/${worker_name}.key"
  labctl cp "${JUMPBOX_PLAYGROUND_ID}:~/${worker_name}.kubeconfig" "${ARTIFACT_DIR}/${worker_name}.kubeconfig"
done
cp -r "${REPO_ROOT}/configs" "${WORKER_BUNDLE_DIR}/configs"
cp -r "${REPO_ROOT}/units" "${WORKER_BUNDLE_DIR}/units"
cp "${REPO_ROOT}/scripts/bootstrap_workers.sh" "${WORKER_BUNDLE_DIR}/bootstrap_workers.sh"

for worker_playground_id in "${WORKER_PLAYGROUNDS[@]}"; do
  for machine_name in $(labctl playground machines "${worker_playground_id}" | sed '1d'); do
    labctl ssh "${worker_playground_id}" --machine "${machine_name}" "mkdir -p /var/lib/kubelet"
    labctl cp -r "${WORKER_BUNDLE_DIR}" "${worker_playground_id}:~/worker-bootstrap" --machine "${machine_name}"
    labctl cp "${ARTIFACT_DIR}/ca.crt" "${worker_playground_id}:/var/lib/kubelet/ca.crt" --machine "${machine_name}"
    labctl cp "${ARTIFACT_DIR}/${machine_name}.crt" "${worker_playground_id}:/var/lib/kubelet/kubelet.crt" --machine "${machine_name}"
    labctl cp "${ARTIFACT_DIR}/${machine_name}.key" "${worker_playground_id}:/var/lib/kubelet/kubelet.key" --machine "${machine_name}"
    labctl cp "${ARTIFACT_DIR}/${machine_name}.kubeconfig" "${worker_playground_id}:/var/lib/kubelet/kubeconfig" --machine "${machine_name}"
    labctl ssh "${worker_playground_id}" --machine "${machine_name}" "bash ~/worker-bootstrap/bootstrap_workers.sh"
  done
done

if ! wait_for_worker_nodes_registered; then
  echo "timed out waiting for all worker nodes to appear" >&2
  exit 1
fi

labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'"
