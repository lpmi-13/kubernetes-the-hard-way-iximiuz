#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
CONTROL_PLANE_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(any(.machines[]; .name == "load-balancer")) | .id')
ARTIFACT_DIR="$(mktemp -d)"
trap 'rm -rf "${ARTIFACT_DIR}"' EXIT
CONTROLLER_BUNDLE_DIR="${ARTIFACT_DIR}/control-plane"
JUMPBOX_CONTROLLER_EXPORT_DIR="~/control-plane-export"

labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "
  rm -rf ${JUMPBOX_CONTROLLER_EXPORT_DIR}
  mkdir -p ${JUMPBOX_CONTROLLER_EXPORT_DIR}
  cp \
    ~/downloads/controller/kube-apiserver \
    ~/downloads/controller/kube-controller-manager \
    ~/downloads/controller/kube-scheduler \
    ~/downloads/client/kubectl \
    ~/ca.crt \
    ~/ca.key \
    ~/front-proxy-ca.crt \
    ~/front-proxy-client.crt \
    ~/front-proxy-client.key \
    ~/kube-api-server.crt \
    ~/kube-api-server.key \
    ~/service-accounts.crt \
    ~/service-accounts.key \
    ~/encryption-config.yaml \
    ~/kube-controller-manager.kubeconfig \
    ~/kube-scheduler.kubeconfig \
    ${JUMPBOX_CONTROLLER_EXPORT_DIR}/
"

labctl cp -r "${JUMPBOX_PLAYGROUND_ID}:${JUMPBOX_CONTROLLER_EXPORT_DIR}" "${ARTIFACT_DIR}"
mv "${ARTIFACT_DIR}/control-plane-export" "${CONTROLLER_BUNDLE_DIR}"

cp "${REPO_ROOT}/units/kube-apiserver.service" "${CONTROLLER_BUNDLE_DIR}/kube-apiserver.service"
cp "${REPO_ROOT}/units/kube-controller-manager.service" "${CONTROLLER_BUNDLE_DIR}/kube-controller-manager.service"
cp "${REPO_ROOT}/units/kube-scheduler.service" "${CONTROLLER_BUNDLE_DIR}/kube-scheduler.service"
cp "${REPO_ROOT}/configs/kube-scheduler.yaml" "${CONTROLLER_BUNDLE_DIR}/kube-scheduler.yaml"
cp "${REPO_ROOT}/scripts/install_control_plane_on_controller.sh" "${CONTROLLER_BUNDLE_DIR}/install_control_plane_on_controller.sh"

labctl cp ./scripts/install_haproxy.sh $CONTROL_PLANE_PLAYGROUND_ID:~/install_haproxy.sh --machine load-balancer
labctl cp ./scripts/update_hosts_for_api.sh $JUMPBOX_PLAYGROUND_ID:~/update_hosts_for_api.sh
labctl cp ./scripts/update_api_host_entries.sh $JUMPBOX_PLAYGROUND_ID:~/update_api_host_entries.sh
labctl ssh $JUMPBOX_PLAYGROUND_ID "rm -rf ~/configs ~/units"
labctl cp -r ./configs $JUMPBOX_PLAYGROUND_ID:~/configs
labctl cp -r ./units $JUMPBOX_PLAYGROUND_ID:~/units

labctl ssh $CONTROL_PLANE_PLAYGROUND_ID --machine load-balancer "bash ~/install_haproxy.sh"
labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/update_api_host_entries.sh"

for controller in controller-{1..3}; do
  labctl cp -r "${CONTROLLER_BUNDLE_DIR}" "${CONTROL_PLANE_PLAYGROUND_ID}:~/control-plane" --machine "${controller}"
  labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine "${controller}" "bash ~/control-plane/install_control_plane_on_controller.sh"
done

for i in {1..60}; do
  if labctl ssh $JUMPBOX_PLAYGROUND_ID "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 \"kubectl get --raw='/readyz' --kubeconfig /root/admin.kubeconfig\"" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "timed out waiting for API server to respond" >&2
    exit 1
  fi
  sleep 2
done

labctl cp "${REPO_ROOT}/configs/kube-api-server-to-kubelet.yaml" "${CONTROL_PLANE_PLAYGROUND_ID}:~/kube-api-server-to-kubelet.yaml" --machine controller-1
labctl cp "${REPO_ROOT}/scripts/set_up_rbac.sh" "${CONTROL_PLANE_PLAYGROUND_ID}:~/set_up_rbac.sh" --machine controller-1
labctl ssh "${CONTROL_PLANE_PLAYGROUND_ID}" --machine controller-1 "bash ~/set_up_rbac.sh"

bash "${REPO_ROOT}/scripts/check_control_plane.sh"
