#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
CONTROL_PLANE_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(any(.machines[]; .name == "load-balancer")) | .id')
LOAD_BALANCER_IP=$(labctl ssh "$CONTROL_PLANE_PLAYGROUND_ID" --machine load-balancer "tailscale ip -4" | tr -d '\n\r')

labctl cp ./scripts/update_hosts_for_api.sh "$JUMPBOX_PLAYGROUND_ID":~/update_hosts_for_api.sh
labctl cp ./scripts/install_cilium_tools_on_jumpbox.sh "$JUMPBOX_PLAYGROUND_ID":~/install_cilium_tools_on_jumpbox.sh
labctl cp ./scripts/deploy_cilium_on_jumpbox.sh "$JUMPBOX_PLAYGROUND_ID":~/deploy_cilium_on_jumpbox.sh

labctl ssh "$JUMPBOX_PLAYGROUND_ID" "API_SERVER_IP=${LOAD_BALANCER_IP} API_SERVER_HOST=server.kubernetes.local bash ~/update_hosts_for_api.sh"
if ! labctl ssh "$JUMPBOX_PLAYGROUND_ID" "curl -skf --connect-timeout 5 --cacert ~/ca.crt https://server.kubernetes.local:6443/version >/dev/null"; then
  echo "API server endpoint is not reachable from the jumpbox; rerun the control-plane/bootstrap steps before step 11" >&2
  exit 1
fi
labctl ssh "$JUMPBOX_PLAYGROUND_ID" "bash ~/install_cilium_tools_on_jumpbox.sh"
labctl ssh "$JUMPBOX_PLAYGROUND_ID" "bash ~/deploy_cilium_on_jumpbox.sh"
