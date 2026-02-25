#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/configure_kubectl_on_jumpbox.sh $JUMPBOX_PLAYGROUND_ID:~/configure_kubectl_on_jumpbox.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/configure_kubectl_on_jumpbox.sh"
