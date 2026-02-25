#!/usr/bin/env bash
set -euo pipefail

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl ssh $JUMPBOX_PLAYGROUND_ID "rm -rf ~/deployments"
labctl cp -r ./deployments $JUMPBOX_PLAYGROUND_ID:~/deployments
labctl cp ./scripts/deploy_dns_on_jumpbox.sh $JUMPBOX_PLAYGROUND_ID:~/deploy_dns_on_jumpbox.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/deploy_dns_on_jumpbox.sh"
