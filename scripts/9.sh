#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/bootstrap_workers.sh $JUMPBOX_PLAYGROUND_ID:~/bootstrap_workers.sh
labctl cp ./scripts/bootstrap_workers_on_jumpbox.sh $JUMPBOX_PLAYGROUND_ID:~/bootstrap_workers_on_jumpbox.sh
labctl ssh $JUMPBOX_PLAYGROUND_ID "rm -rf ~/configs ~/units"
labctl cp -r ./configs $JUMPBOX_PLAYGROUND_ID:~/configs
labctl cp -r ./units $JUMPBOX_PLAYGROUND_ID:~/units

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/bootstrap_workers_on_jumpbox.sh"

for i in {1..90}; do
  if labctl ssh $JUMPBOX_PLAYGROUND_ID "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'" 2>/dev/null | grep -q worker; then
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "timed out waiting for worker nodes to appear" >&2
    exit 1
  fi
  sleep 2
done

labctl ssh $JUMPBOX_PLAYGROUND_ID "ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 'kubectl get nodes --kubeconfig /root/admin.kubeconfig'"
