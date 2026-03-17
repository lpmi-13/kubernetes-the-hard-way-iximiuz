#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="$(mktemp -d)"
trap 'rm -rf "${ARTIFACT_DIR}"' EXIT
WORKER_BUNDLE_DIR="${ARTIFACT_DIR}/worker-bootstrap"
JUMPBOX_WORKER_EXPORT_DIR="~/worker-bootstrap-export"

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

labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "
  rm -rf ${JUMPBOX_WORKER_EXPORT_DIR}
  mkdir -p ${JUMPBOX_WORKER_EXPORT_DIR}/worker
  cp \
    ~/downloads/worker/containerd \
    ~/downloads/worker/containerd-shim-runc-v2 \
    ~/downloads/worker/runc \
    ~/downloads/worker/kubelet \
    ${JUMPBOX_WORKER_EXPORT_DIR}/worker/
  cp ~/ca.crt ${JUMPBOX_WORKER_EXPORT_DIR}/
  for worker_name in worker-{1..5}; do
    cp \
      ~/\${worker_name}.crt \
      ~/\${worker_name}.key \
      ~/\${worker_name}.kubeconfig \
      ${JUMPBOX_WORKER_EXPORT_DIR}/
  done
"

labctl cp -r "${JUMPBOX_PLAYGROUND_ID}:${JUMPBOX_WORKER_EXPORT_DIR}" "${ARTIFACT_DIR}"
mv "${ARTIFACT_DIR}/worker-bootstrap-export" "${WORKER_BUNDLE_DIR}"

cp -r "${REPO_ROOT}/configs" "${WORKER_BUNDLE_DIR}/configs"
cp -r "${REPO_ROOT}/units" "${WORKER_BUNDLE_DIR}/units"
cp "${REPO_ROOT}/scripts/bootstrap_workers.sh" "${WORKER_BUNDLE_DIR}/bootstrap_workers.sh"

for worker_playground_id in "${WORKER_PLAYGROUNDS[@]}"; do
  for machine_name in $(labctl playground machines "${worker_playground_id}" | sed '1d'); do
    labctl ssh "${worker_playground_id}" --machine "${machine_name}" "mkdir -p /var/lib/kubelet"
    labctl cp -r "${WORKER_BUNDLE_DIR}" "${worker_playground_id}:~/worker-bootstrap" --machine "${machine_name}"
    labctl cp "${WORKER_BUNDLE_DIR}/ca.crt" "${worker_playground_id}:/var/lib/kubelet/ca.crt" --machine "${machine_name}"
    labctl cp "${WORKER_BUNDLE_DIR}/${machine_name}.crt" "${worker_playground_id}:/var/lib/kubelet/kubelet.crt" --machine "${machine_name}"
    labctl cp "${WORKER_BUNDLE_DIR}/${machine_name}.key" "${worker_playground_id}:/var/lib/kubelet/kubelet.key" --machine "${machine_name}"
    labctl cp "${WORKER_BUNDLE_DIR}/${machine_name}.kubeconfig" "${worker_playground_id}:/var/lib/kubelet/kubeconfig" --machine "${machine_name}"
    labctl ssh "${worker_playground_id}" --machine "${machine_name}" "bash ~/worker-bootstrap/bootstrap_workers.sh"
  done
done

if ! wait_for_worker_nodes_registered; then
  echo "timed out waiting for all worker nodes to appear" >&2
  exit 1
fi

labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'"
