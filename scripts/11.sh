#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/route_worker.sh $JUMPBOX_PLAYGROUND_ID:~/route_worker.sh
labctl cp ./scripts/configure_pod_routes.sh $JUMPBOX_PLAYGROUND_ID:~/configure_pod_routes.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/configure_pod_routes.sh"
