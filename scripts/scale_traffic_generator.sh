#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/scale_traffic_generator.sh --replicas <count>

Scale the demo namespace traffic-generator Deployment by running kubectl on the
jumpbox through labctl.

Examples:
  bash scripts/scale_traffic_generator.sh --replicas 3
  bash scripts/scale_traffic_generator.sh -r 0
EOF
}

retry_cmd() {
  local max_attempts="$1"
  shift

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      return 1
    fi
    echo "command failed; retrying (${attempt}/${max_attempts})..." >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

require_integer() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

REPLICAS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -r|--replicas)
      if [ "$#" -lt 2 ]; then
        echo "--replicas requires a value" >&2
        usage
        exit 1
      fi
      REPLICAS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! require_integer "${REPLICAS}"; then
  echo "--replicas must be a non-negative integer" >&2
  usage
  exit 1
fi

JUMPBOX_PLAYGROUND_ID="$(labctl playground list -o json | jq -r '.[] | select((.machines | length == 1) and (.machines[0].name == "jumpbox")) | .id')"
if [ -z "${JUMPBOX_PLAYGROUND_ID}" ] || [ "${JUMPBOX_PLAYGROUND_ID}" = "null" ]; then
  echo "failed to find jumpbox playground id" >&2
  exit 1
fi

echo "scaling demo/traffic-generator to ${REPLICAS} replicas via jumpbox ${JUMPBOX_PLAYGROUND_ID}"

REMOTE_CMD="$(cat <<'EOF'
set -euo pipefail

target_replicas="${TARGET_REPLICAS:?TARGET_REPLICAS must be set}"
scaled=false

kubectl -n demo scale deployment/traffic-generator --replicas="${target_replicas}"

for attempt in $(seq 1 60); do
  spec_replicas="$(kubectl -n demo get deployment traffic-generator -o jsonpath='{.spec.replicas}')"
  ready_replicas="$(kubectl -n demo get deployment traffic-generator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  available_replicas="$(kubectl -n demo get deployment traffic-generator -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  ready_replicas="${ready_replicas:-0}"
  available_replicas="${available_replicas:-0}"

  echo "attempt=${attempt} spec=${spec_replicas} ready=${ready_replicas} available=${available_replicas}"

  if [ "${target_replicas}" -eq 0 ] && [ "${ready_replicas}" -eq 0 ]; then
    scaled=true
    break
  fi

  if [ "${target_replicas}" -gt 0 ] && [ "${available_replicas}" -ge "${target_replicas}" ]; then
    scaled=true
    break
  fi

  sleep 2
done

if [ "${scaled}" != true ]; then
  echo "traffic-generator did not reach the requested replica state in time" >&2
  kubectl -n demo get deployment traffic-generator -o wide >&2 || true
  kubectl -n demo get pods -l app=traffic-generator -o wide >&2 || true
  exit 1
fi

echo "=== traffic-generator deployment ==="
kubectl -n demo get deployment traffic-generator

echo "=== traffic-generator pods ==="
kubectl -n demo get pods -l app=traffic-generator -o wide
EOF
)"

REMOTE_CMD_ESCAPED="$(printf '%q' "${REMOTE_CMD}")"

retry_cmd 5 labctl ssh "${JUMPBOX_PLAYGROUND_ID}" "TARGET_REPLICAS=${REPLICAS} bash -lc ${REMOTE_CMD_ESCAPED}"
