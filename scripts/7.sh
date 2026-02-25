#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp -r ./units $JUMPBOX_PLAYGROUND_ID:~/units
labctl cp ./scripts/copy_etcd_config_to_controllers.sh $JUMPBOX_PLAYGROUND_ID:~/copy_etcd_config_to_controllers.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/copy_etcd_config_to_controllers.sh"

CONTROLLER_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | .[0].name == "controller-1") | .id')

configure_failures=0
for machine_name in $(labctl playground machines $CONTROLLER_PLAYGROUND_ID | sed '1d'); do
  if [[ $machine_name == "load-balancer" ]]; then
    echo "skipping etcd configuration on load-balancer"
  else
    labctl cp ./scripts/configure_etcd_on_controllers.sh $CONTROLLER_PLAYGROUND_ID:~/configure_etcd_on_controllers.sh --machine $machine_name
    if ! labctl ssh $CONTROLLER_PLAYGROUND_ID --machine $machine_name "bash ~/configure_etcd_on_controllers.sh"; then
      echo "failed configuring etcd on ${machine_name}" >&2
      configure_failures=$((configure_failures + 1))
    fi
  fi
done

if [ "$configure_failures" -gt 0 ]; then
  echo "etcd configuration failed on ${configure_failures} controller node(s)" >&2
  exit 1
fi

echo "verifying etcd cluster membership from controller-1..."
for _ in {1..90}; do
  if labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-1 \
    "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list"; then
    exit 0
  fi
  sleep 2
done

echo "timed out waiting for etcd cluster membership to stabilize" >&2
for controller in controller-1 controller-2 controller-3; do
  echo "==== ${controller}: systemctl status etcd ====" >&2
  labctl ssh $CONTROLLER_PLAYGROUND_ID --machine "$controller" "systemctl status etcd --no-pager -l || true" || true
  echo "==== ${controller}: journalctl -u etcd (last 80 lines) ====" >&2
  labctl ssh $CONTROLLER_PLAYGROUND_ID --machine "$controller" "journalctl -u etcd --no-pager -n 80 || true" || true
done
exit 1
