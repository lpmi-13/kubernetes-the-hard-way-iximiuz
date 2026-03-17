#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTENV_FILE="${DOTENV_FILE:-${REPO_ROOT}/.env}"

DRY_RUN=false
SKIP_TAILSCALE=false
TS_TAGS="${TS_TAGS:-tag:kthw}"

usage() {
  cat <<'EOF'
Usage: ./clean-up.sh [--dry-run] [--no-tailscale]

Options:
  --dry-run        Print actions without deleting devices/playgrounds/files.
  --no-tailscale   Skip Tailscale device cleanup.
  -h, --help       Show this help text.

Environment:
  TS_API_CLIENT_ID
  TS_API_CLIENT_SECRET
  TS_TAGS (default: tag:kthw)
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

cleanup_local_labctl_port_forwards() {
  local tmp_root="${TMPDIR:-/tmp}"
  local matched_files=()
  local labctl_pids=""
  local pid=""

  if command -v pgrep >/dev/null 2>&1; then
    labctl_pids="$(pgrep -f '(^|[[:space:]])labctl port-forward([[:space:]]|$)' || true)"
  else
    labctl_pids="$(ps -eo pid=,args= | awk '/[l]abctl port-forward/ {print $1}' || true)"
  fi
  labctl_pids="$(printf '%s\n' "${labctl_pids}" | awk 'NF {print}' | sort -u || true)"

  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    if [ "${DRY_RUN}" = true ]; then
      echo "dry-run: would kill local labctl port-forward pid ${pid}"
    else
      kill "${pid}" 2>/dev/null || true
    fi
  done <<< "${labctl_pids}"

  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    matched_files+=("${path}")
  done < <(find "${tmp_root}" -maxdepth 1 -type f \
    \( -name 'kthw-*-labctl-portforward-*.pid' -o -name 'kthw-*-labctl-portforward-*.log' \) \
    -print 2>/dev/null)

  if [ "${#matched_files[@]}" -eq 0 ]; then
    echo "Local labctl port-forward cleanup: no kthw port-forward PID/log files found."
    return 0
  fi

  for path in "${matched_files[@]}"; do
    if [ "${DRY_RUN}" = true ]; then
      echo "dry-run: would remove ${path}"
    else
      rm -f "${path}"
    fi
  done
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-tailscale)
      SKIP_TAILSCALE=true
      shift
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

require_cmd labctl
require_cmd jq

if [ -f "$DOTENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DOTENV_FILE"
  set +a
fi

TS_TAGS="${TS_TAGS:-tag:kthw}"

declare -a PLAYGROUND_IDS=()
declare -a MACHINE_NAMES=()

playgrounds_json="$(labctl playground list -o json)"

while IFS= read -r playground_id; do
  [ -z "$playground_id" ] && continue
  PLAYGROUND_IDS+=("$playground_id")
done < <(echo "$playgrounds_json" | jq -r '(. // [])[]? | .id // empty')

while IFS= read -r machine_name; do
  [ -z "$machine_name" ] && continue
  MACHINE_NAMES+=("$machine_name")
done < <(echo "$playgrounds_json" | jq -r '(. // [])[]? | (.machines // [])[].name // empty')

cleanup_local_labctl_port_forwards

if [ "$SKIP_TAILSCALE" = false ]; then
  require_cmd curl
  : "${TS_API_CLIENT_ID:?TS_API_CLIENT_ID must be set for tailscale cleanup}"
  : "${TS_API_CLIENT_SECRET:?TS_API_CLIENT_SECRET must be set for tailscale cleanup}"

  echo "Tailscale cleanup: discovering matching devices..."

  oauth_resp="$(curl -sS -u "${TS_API_CLIENT_ID}:${TS_API_CLIENT_SECRET}" -d grant_type=client_credentials https://api.tailscale.com/api/v2/oauth/token)"
  access_token="$(echo "$oauth_resp" | jq -er '.access_token')"

  devices_resp_file="$(mktemp)"
  devices_http_code="$(
    curl -sS -o "$devices_resp_file" -w '%{http_code}' \
      -H "Authorization: Bearer $access_token" \
      https://api.tailscale.com/api/v2/tailnet/-/devices
  )"
  if [ "$devices_http_code" -ne 200 ]; then
    api_message="$(jq -r '.message // empty' "$devices_resp_file" 2>/dev/null || true)"
    if [ "$devices_http_code" -eq 403 ]; then
      echo "Tailscale cleanup failed: OAuth client lacks required permissions (need devices:core)." >&2
    else
      echo "Tailscale cleanup failed: unable to list devices (HTTP $devices_http_code)." >&2
    fi
    [ -n "$api_message" ] && echo "Tailscale API message: $api_message" >&2
    rm -f "$devices_resp_file"
    exit 1
  fi

  restrict_to_target_hosts=false
  declare -A target_hosts=()
  if [ "${#MACHINE_NAMES[@]}" -gt 0 ]; then
    restrict_to_target_hosts=true
    for machine_name in "${MACHINE_NAMES[@]}"; do
      target_hosts["$machine_name"]=1
    done
  else
    echo "No lab machines found; falling back to tag-based cleanup."
  fi

  declare -A required_tags=()
  IFS=',' read -r -a ts_tags_array <<<"$TS_TAGS"
  for tag in "${ts_tags_array[@]}"; do
    tag="$(echo "$tag" | xargs)"
    [ -z "$tag" ] && continue
    required_tags["$tag"]=1
  done

  declare -a stale_device_ids=()
  declare -a stale_device_names=()
  while IFS=$'\t' read -r device_id device_name online tags_csv; do
    [ -z "$device_id" ] && continue
    [ -z "$device_name" ] && continue

    if [ "$restrict_to_target_hosts" = true ]; then
      short_name="${device_name%%.*}"
      match_host=false
      if [ -n "${target_hosts[$short_name]:-}" ]; then
        match_host=true
      else
        for host in "${!target_hosts[@]}"; do
          if [[ "$short_name" == "${host}"-* ]]; then
            match_host=true
            break
          fi
        done
      fi
      if [ "$match_host" = false ]; then
        continue
      fi
    fi

    tag_match=false
    IFS=',' read -r -a device_tags <<<"$tags_csv"
    for device_tag in "${device_tags[@]}"; do
      device_tag="$(echo "$device_tag" | xargs)"
      if [ -n "$device_tag" ] && [ -n "${required_tags[$device_tag]:-}" ]; then
        tag_match=true
        break
      fi
    done
    [ "$tag_match" = false ] && continue

    stale_device_ids+=("$device_id")
    stale_device_names+=("$device_name")
  done < <(jq -r '(.devices // [])[] | [(.id // ""), (.name // .hostname // ""), ((.online // false)|tostring), ((.tags // [])|join(","))] | @tsv' "$devices_resp_file")
  rm -f "$devices_resp_file"

  stale_total="${#stale_device_ids[@]}"
  if [ "$stale_total" -eq 0 ]; then
    echo "Tailscale cleanup summary: 0 devices matched."
  else
    echo "Tailscale cleanup candidates: $stale_total"
  fi

  cleanup_deleted=0
  cleanup_failed=0
  for i in "${!stale_device_ids[@]}"; do
    device_id="${stale_device_ids[$i]}"
    device_name="${stale_device_names[$i]}"

    if [ "$DRY_RUN" = true ]; then
      echo "  dry-run: would delete tailscale device $device_name ($device_id)"
      continue
    fi

    delete_resp_file="$(mktemp)"
    delete_http_code="$(
      curl -sS -o "$delete_resp_file" -w '%{http_code}' \
        -X DELETE \
        -H "Authorization: Bearer $access_token" \
        "https://api.tailscale.com/api/v2/device/${device_id}"
    )"
    if [ "$delete_http_code" -ge 200 ] && [ "$delete_http_code" -lt 300 ]; then
      cleanup_deleted=$((cleanup_deleted + 1))
      echo "  deleted tailscale device $device_name ($device_id)"
    else
      cleanup_failed=$((cleanup_failed + 1))
      api_message="$(jq -r '.message // empty' "$delete_resp_file" 2>/dev/null || true)"
      echo "  failed to delete tailscale device $device_name ($device_id): HTTP $delete_http_code" >&2
      [ -n "$api_message" ] && echo "  tailscale API message: $api_message" >&2
    fi
    rm -f "$delete_resp_file"
  done

  if [ "$DRY_RUN" = true ]; then
    echo "Tailscale cleanup summary: $stale_total candidates, 0 deleted, 0 failed (dry-run)."
  else
    echo "Tailscale cleanup summary: $stale_total candidates, $cleanup_deleted deleted, $cleanup_failed failed."
  fi

  if [ "$cleanup_failed" -gt 0 ]; then
    echo "Tailscale cleanup failed; aborting before playground destruction." >&2
    exit 1
  fi
elif [ "$SKIP_TAILSCALE" = true ]; then
  echo "Skipping tailscale cleanup due to --no-tailscale."
fi

if [ "${#PLAYGROUND_IDS[@]}" -eq 0 ]; then
  echo "No playgrounds found to destroy."
else
  declare -A seen_playgrounds=()
  for playground_id in "${PLAYGROUND_IDS[@]}"; do
    [ -n "${seen_playgrounds[$playground_id]:-}" ] && continue
    seen_playgrounds["$playground_id"]=1
    if [ "$DRY_RUN" = true ]; then
      echo "dry-run: would destroy playground $playground_id"
    else
      labctl playground destroy "$playground_id"
    fi
  done
fi

if [ "$DRY_RUN" = true ]; then
  echo "dry-run: would remove local key files matching kubernetes.ed25519*"
else
  rm -f "${REPO_ROOT}"/kubernetes.ed25519*
  echo "Removed local key files matching kubernetes.ed25519*"
fi
