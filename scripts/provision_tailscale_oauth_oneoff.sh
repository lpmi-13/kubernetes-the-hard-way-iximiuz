#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/install_tailscale.sh"
DOTENV_FILE="${DOTENV_FILE:-${REPO_ROOT}/.env}"

DRY_RUN=false
ONLY_PATTERN=""

usage() {
  cat <<'EOF'
Usage: scripts/provision_tailscale_oauth_oneoff.sh [--dry-run] [--only <glob>]

Required environment variables:
  TS_API_CLIENT_ID
  TS_API_CLIENT_SECRET

Optional environment variables:
  TS_TAGS=tag:kthw
  TS_GO_CACHE_ROOT=/tmp/kthw-go
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --only)
      if [ "${2:-}" = "" ]; then
        echo "--only requires a glob pattern" >&2
        exit 1
      fi
      ONLY_PATTERN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "Missing install script: $INSTALL_SCRIPT" >&2
  exit 1
fi

if { [ -z "${TS_API_CLIENT_ID:-}" ] || [ -z "${TS_API_CLIENT_SECRET:-}" ]; } && [ -f "$DOTENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DOTENV_FILE"
  set +a
fi

require_cmd labctl
require_cmd go
require_cmd sed

: "${TS_API_CLIENT_ID:?TS_API_CLIENT_ID must be set}"
: "${TS_API_CLIENT_SECRET:?TS_API_CLIENT_SECRET must be set}"

TS_TAGS="${TS_TAGS:-tag:kthw}"
TS_GO_CACHE_ROOT="${TS_GO_CACHE_ROOT:-/tmp/kthw-go}"
mkdir -p "$TS_GO_CACHE_ROOT/gopath/pkg/mod" "$TS_GO_CACHE_ROOT/gocache"

generate_auth_key() {
  local key
  key="$(
    GOPATH="$TS_GO_CACHE_ROOT/gopath" \
    GOMODCACHE="$TS_GO_CACHE_ROOT/gopath/pkg/mod" \
    GOCACHE="$TS_GO_CACHE_ROOT/gocache" \
    go run tailscale.com/cmd/get-authkey@latest -ephemeral -preauth -tags "$TS_TAGS"
  )"
  key="$(echo "$key" | tr -d '[:space:]')"
  if [ -z "$key" ]; then
    return 1
  fi
  printf '%s' "$key"
}

declare -a TARGET_PLAYGROUNDS=()
declare -a TARGET_MACHINES=()

while IFS= read -r playground_id; do
  [ -z "$playground_id" ] && continue
  while IFS= read -r machine_name; do
    [ -z "$machine_name" ] && continue
    if [ -n "$ONLY_PATTERN" ] && [[ ! "$machine_name" == $ONLY_PATTERN ]]; then
      continue
    fi
    TARGET_PLAYGROUNDS+=("$playground_id")
    TARGET_MACHINES+=("$machine_name")
  done < <(labctl playground machines "$playground_id" | sed '1d')
done < <(labctl playground list -q)

if [ "${#TARGET_MACHINES[@]}" -eq 0 ]; then
  echo "No machines matched."
  exit 1
fi

TOTAL="${#TARGET_MACHINES[@]}"
SUCCESS=0
FAILURES=0

for i in "${!TARGET_MACHINES[@]}"; do
  playground_id="${TARGET_PLAYGROUNDS[$i]}"
  machine_name="${TARGET_MACHINES[$i]}"
  index=$((i + 1))

  echo "[$index/$TOTAL] $playground_id :: $machine_name"

  if [ "$DRY_RUN" = true ]; then
    echo "  dry-run: would generate one-off key and enroll machine"
    continue
  fi

  if ! auth_key="$(generate_auth_key)"; then
    echo "  error: failed to generate OAuth one-off key"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  auth_key_escaped="$(printf '%q' "$auth_key")"
  machine_name_escaped="$(printf '%q' "$machine_name")"
  ts_tags_escaped="$(printf '%q' "$TS_TAGS")"

  if {
    printf 'export TAILSCALE_AUTH_KEY=%s\n' "$auth_key_escaped"
    printf 'export TAILSCALE_HOSTNAME=%s\n' "$machine_name_escaped"
    printf 'export TAILSCALE_TAGS=%s\n' "$ts_tags_escaped"
    cat "$INSTALL_SCRIPT"
  } | labctl ssh "$playground_id" --machine "$machine_name"; then
    SUCCESS=$((SUCCESS + 1))
  else
    echo "  error: tailscale install/enroll failed"
    FAILURES=$((FAILURES + 1))
  fi
done

echo
echo "Tailscale enrollment summary: $SUCCESS succeeded, $FAILURES failed"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
