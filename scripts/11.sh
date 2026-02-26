#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/install_cilium_tools_on_jumpbox.sh "$JUMPBOX_PLAYGROUND_ID":~/install_cilium_tools_on_jumpbox.sh
labctl cp ./scripts/deploy_cilium_on_jumpbox.sh "$JUMPBOX_PLAYGROUND_ID":~/deploy_cilium_on_jumpbox.sh

labctl ssh "$JUMPBOX_PLAYGROUND_ID" "bash ~/install_cilium_tools_on_jumpbox.sh"
labctl ssh "$JUMPBOX_PLAYGROUND_ID" "bash ~/deploy_cilium_on_jumpbox.sh"
