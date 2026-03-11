#!/usr/bin/env bash
set -euo pipefail

retry_cmd() {
  local max_attempts="$1"
  shift

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    echo "command failed; retrying (${attempt}/${max_attempts})..." >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
if [ -z "${JUMPBOX_PLAYGROUND_ID}" ] || [ "${JUMPBOX_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find jumpbox playground id" >&2
  exit 1
fi

retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "rm -rf ~/deployments"
retry_cmd 5 labctl cp -r ./deployments "${JUMPBOX_PLAYGROUND_ID}":~/deployments
retry_cmd 5 labctl cp ./ca.conf "${JUMPBOX_PLAYGROUND_ID}":~/ca.conf
retry_cmd 5 labctl cp ./units/kube-apiserver.service "${JUMPBOX_PLAYGROUND_ID}":~/kube-apiserver.service
retry_cmd 5 labctl cp ./scripts/enable_aggregation_layer_on_jumpbox.sh "${JUMPBOX_PLAYGROUND_ID}":~/enable_aggregation_layer_on_jumpbox.sh
retry_cmd 5 labctl cp ./scripts/install_keda_on_jumpbox.sh "${JUMPBOX_PLAYGROUND_ID}":~/install_keda_on_jumpbox.sh
retry_cmd 5 labctl cp ./scripts/deploy_bookinfo_on_jumpbox.sh "${JUMPBOX_PLAYGROUND_ID}":~/deploy_bookinfo_on_jumpbox.sh
retry_cmd 5 labctl cp ./scripts/smoke_test_on_jumpbox.sh "${JUMPBOX_PLAYGROUND_ID}":~/smoke_test_on_jumpbox.sh

retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/enable_aggregation_layer_on_jumpbox.sh"
retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/install_keda_on_jumpbox.sh"
retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/deploy_bookinfo_on_jumpbox.sh"
retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "bash ~/smoke_test_on_jumpbox.sh"
