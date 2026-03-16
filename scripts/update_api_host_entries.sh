#!/usr/bin/env bash
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519
API_SERVER_HOST="server.kubernetes.local"

LOAD_BALANCER_IP=$(ssh -i "${SSH_KEY}" root@load-balancer "tailscale ip -4" | tr -d '\n\r')
if [ -z "${LOAD_BALANCER_IP}" ]; then
  echo "failed to resolve load-balancer Tailscale IP" >&2
  exit 1
fi

echo "Using ${API_SERVER_HOST} -> ${LOAD_BALANCER_IP}"

# Update jumpbox itself
API_SERVER_IP="${LOAD_BALANCER_IP}" API_SERVER_HOST="${API_SERVER_HOST}" bash ~/update_hosts_for_api.sh

# Update all cluster nodes, including the load balancer
for host in controller-{1..3} worker-{1..5} load-balancer; do
  ssh -i "${SSH_KEY}" root@${host} "API_SERVER_IP=${LOAD_BALANCER_IP} API_SERVER_HOST=${API_SERVER_HOST} bash -s" < ~/update_hosts_for_api.sh
done
