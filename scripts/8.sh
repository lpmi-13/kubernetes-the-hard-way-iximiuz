#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/bootstrap_control_plane_on_controllers.sh $JUMPBOX_PLAYGROUND_ID:~/bootstrap_control_plane_on_controllers.sh
labctl cp ./scripts/install_haproxy.sh $JUMPBOX_PLAYGROUND_ID:~/install_haproxy.sh
labctl cp ./scripts/install_haproxy_on_load_balancer.sh $JUMPBOX_PLAYGROUND_ID:~/install_haproxy_on_load_balancer.sh
labctl cp ./scripts/update_hosts_for_api.sh $JUMPBOX_PLAYGROUND_ID:~/update_hosts_for_api.sh
labctl cp ./scripts/update_api_host_entries.sh $JUMPBOX_PLAYGROUND_ID:~/update_api_host_entries.sh
labctl cp ./scripts/set_up_rbac.sh $JUMPBOX_PLAYGROUND_ID:~/set_up_rbac.sh
labctl ssh $JUMPBOX_PLAYGROUND_ID "rm -rf ~/configs ~/units"
labctl cp -r ./configs $JUMPBOX_PLAYGROUND_ID:~/configs
labctl cp -r ./units $JUMPBOX_PLAYGROUND_ID:~/units

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/install_haproxy_on_load_balancer.sh"
labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/update_api_host_entries.sh"
labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/bootstrap_control_plane_on_controllers.sh"

for i in {1..60}; do
  if labctl ssh $JUMPBOX_PLAYGROUND_ID "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get componentstatuses --kubeconfig /root/admin.kubeconfig'" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "timed out waiting for API server to respond" >&2
    exit 1
  fi
  sleep 2
done

labctl ssh $JUMPBOX_PLAYGROUND_ID "scp -i ~/.ssh/kubernetes.ed25519 ~/configs/kube-api-server-to-kubelet.yaml root@controller-1:/root/kube-api-server-to-kubelet.yaml"
labctl ssh $JUMPBOX_PLAYGROUND_ID "scp -i ~/.ssh/kubernetes.ed25519 ~/set_up_rbac.sh root@controller-1:/root/set_up_rbac.sh"
labctl ssh $JUMPBOX_PLAYGROUND_ID "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'bash /root/set_up_rbac.sh'"

labctl ssh $JUMPBOX_PLAYGROUND_ID "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get componentstatuses --kubeconfig /root/admin.kubeconfig'"
labctl ssh $JUMPBOX_PLAYGROUND_ID "curl -k --cacert ~/ca.crt https://server.kubernetes.local:6443/version"
