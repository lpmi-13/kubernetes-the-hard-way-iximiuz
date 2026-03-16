#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTENV_FILE="${DOTENV_FILE:-${REPO_ROOT}/.env}"
JUMPBOX_PUBLIC_KEY_FILE="${JUMPBOX_PUBLIC_KEY_FILE:-${REPO_ROOT}/kubernetes.ed25519.pub}"

if [ "$#" -lt 1 ]; then
  echo "Usage: scripts/rebuild_worker_playgrounds.sh <cluster-index> [<cluster-index> ...]" >&2
  exit 1
fi

if [ -f "${DOTENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${DOTENV_FILE}"
  set +a
fi

: "${TS_API_CLIENT_ID:?TS_API_CLIENT_ID must be set}"
: "${TS_API_CLIENT_SECRET:?TS_API_CLIENT_SECRET must be set}"

TS_TAGS="${TS_TAGS:-tag:kthw}"

worker_names_for_cluster() {
  local cluster_index="$1"

  if [ "${cluster_index}" -ne 1 ]; then
    echo "unsupported worker cluster index: ${cluster_index}" >&2
    return 1
  fi

  printf 'worker-%d\n' 1 2 3 4 5
}

wait_for_running_machines() {
  local max_attempts="$1"
  shift
  local -a machine_names=("$@")
  local list_json running_names missing name

  for _ in $(seq 1 "${max_attempts}"); do
    list_json="$(labctl playground list -o json)"
    running_names="$(echo "${list_json}" | jq -r '.[] | select(.status.stateEvents[-1].state == "RUNNING") | .machines[].name')"

    missing=0
    for name in "${machine_names[@]}"; do
      if ! grep -qx "${name}" <<<"${running_names}"; then
        missing=$((missing + 1))
      fi
    done

    if [ "${missing}" -eq 0 ]; then
      return 0
    fi

    sleep 2
  done

  return 1
}

wait_for_playgrounds_absent() {
  local max_attempts="$1"
  shift
  local -a playground_ids=("$@")
  local existing_ids playground_id

  for _ in $(seq 1 "${max_attempts}"); do
    existing_ids="$(labctl playground list -q || true)"

    for playground_id in "${playground_ids[@]}"; do
      if grep -qx "${playground_id}" <<<"${existing_ids}"; then
        sleep 2
        continue 2
      fi
    done

    return 0
  done

  return 1
}

delete_tailscale_devices_matching_hosts() {
  local -a machine_names=("$@")
  local oauth_resp_file oauth_http_code access_token
  local devices_resp_file devices_http_code api_message
  local cleanup_candidates cleanup_deleted cleanup_failed
  local device_id device_name online tags_csv short_name match_host tag_match
  local delete_resp_file delete_http_code
  local -A target_hosts=()
  local -A required_tags=()
  local -a ts_tags_array=()
  local -a device_tags=()
  local name tag device_tag

  oauth_resp_file="$(mktemp)"
  oauth_http_code="$(
    curl -sS -o "${oauth_resp_file}" -w '%{http_code}' \
      -u "${TS_API_CLIENT_ID}:${TS_API_CLIENT_SECRET}" \
      -d grant_type=client_credentials \
      https://api.tailscale.com/api/v2/oauth/token
  )"
  if [ "${oauth_http_code}" -ne 200 ]; then
    api_message="$(jq -r '.message // empty' "${oauth_resp_file}" 2>/dev/null || true)"
    echo "tailscale cleanup failed: unable to mint OAuth token (HTTP ${oauth_http_code})." >&2
    [ -n "${api_message}" ] && echo "tailscale API message: ${api_message}" >&2
    rm -f "${oauth_resp_file}"
    return 1
  fi
  access_token="$(jq -er '.access_token' "${oauth_resp_file}")"
  rm -f "${oauth_resp_file}"

  devices_resp_file="$(mktemp)"
  devices_http_code="$(
    curl -sS -o "${devices_resp_file}" -w '%{http_code}' \
      -H "Authorization: Bearer ${access_token}" \
      https://api.tailscale.com/api/v2/tailnet/-/devices
  )"
  if [ "${devices_http_code}" -ne 200 ]; then
    api_message="$(jq -r '.message // empty' "${devices_resp_file}" 2>/dev/null || true)"
    echo "tailscale cleanup failed: unable to list devices (HTTP ${devices_http_code})." >&2
    [ -n "${api_message}" ] && echo "tailscale API message: ${api_message}" >&2
    rm -f "${devices_resp_file}"
    return 1
  fi

  for name in "${machine_names[@]}"; do
    [ -n "${name}" ] || continue
    target_hosts["${name}"]=1
  done

  IFS=',' read -r -a ts_tags_array <<<"${TS_TAGS}"
  for tag in "${ts_tags_array[@]}"; do
    tag="$(echo "${tag}" | xargs)"
    [ -n "${tag}" ] || continue
    required_tags["${tag}"]=1
  done

  cleanup_candidates=0
  cleanup_deleted=0
  cleanup_failed=0
  while IFS=$'\t' read -r device_id device_name online tags_csv; do
    [ -n "${device_id}" ] || continue
    [ -n "${device_name}" ] || continue

    short_name="${device_name%%.*}"
    match_host=false
    if [ -n "${target_hosts[$short_name]:-}" ]; then
      match_host=true
    else
      for name in "${!target_hosts[@]}"; do
        if [[ "${short_name}" == "${name}"-* ]]; then
          match_host=true
          break
        fi
      done
    fi
    if [ "${match_host}" = false ]; then
      continue
    fi

    device_tags=()
    IFS=',' read -r -a device_tags <<<"${tags_csv}"
    tag_match=false
    for device_tag in "${device_tags[@]}"; do
      device_tag="$(echo "${device_tag}" | xargs)"
      if [ -n "${device_tag}" ] && [ -n "${required_tags[$device_tag]:-}" ]; then
        tag_match=true
        break
      fi
    done
    if [ "${tag_match}" = false ]; then
      continue
    fi

    cleanup_candidates=$((cleanup_candidates + 1))
    echo "deleting tailscale device ${device_name} (${device_id})"
    delete_resp_file="$(mktemp)"
    delete_http_code="$(
      curl -sS -o "${delete_resp_file}" -w '%{http_code}' \
        -X DELETE \
        -H "Authorization: Bearer ${access_token}" \
        "https://api.tailscale.com/api/v2/device/${device_id}"
    )"
    if [ "${delete_http_code}" -ge 200 ] && [ "${delete_http_code}" -lt 300 ]; then
      cleanup_deleted=$((cleanup_deleted + 1))
    else
      cleanup_failed=$((cleanup_failed + 1))
      api_message="$(jq -r '.message // empty' "${delete_resp_file}" 2>/dev/null || true)"
      echo "failed to delete tailscale device ${device_name} (${device_id}): HTTP ${delete_http_code}" >&2
      [ -n "${api_message}" ] && echo "tailscale API message: ${api_message}" >&2
    fi
    rm -f "${delete_resp_file}"
  done < <(jq -r '(.devices // [])[] | [(.id // ""), (.name // .hostname // ""), ((.online // false)|tostring), ((.tags // [])|join(","))] | @tsv' "${devices_resp_file}")

  rm -f "${devices_resp_file}"
  echo "tailscale cleanup summary (worker-cluster rebuild): ${cleanup_candidates} candidates, ${cleanup_deleted} deleted, ${cleanup_failed} failed."

  [ "${cleanup_failed}" -eq 0 ]
}

start_worker_playground() {
  local cluster_index="$1"

  if [ "${cluster_index}" -ne 1 ]; then
    echo "unsupported worker cluster index: ${cluster_index}" >&2
    return 1
  fi

  echo "starting worker cluster ${cluster_index}..."
  labctl playground start flexbox -f -<<EOF
    kind: playground
    name: worker-cluster-"${cluster_index}"
    title: Worker Cluster "${cluster_index}"
    description: Worker cluster "${cluster_index}" (workers 1-5) for the k8s the hard way cluster of clusters
    categories:
        - linux
        - kubernetes
    playground:
        networks:
            - name: local
              subnet: "172.16.1.0/24"
        machines:
            - name: worker-1
              users:
                - name: root
                  default: true
              drives:
                - source: ubuntu-24-04
                  mount: /
                  size: 30GiB
              network:
                interfaces:
                    - network: local
              resources:
                cpuCount: 2
                ramSize: 2GiB
            - name: worker-2
              users:
                - name: root
                  default: true
              drives:
                - source: ubuntu-24-04
                  mount: /
                  size: 30GiB
              network:
                interfaces:
                    - network: local
              resources:
                cpuCount: 2
                ramSize: 2GiB
            - name: worker-3
              users:
                - name: root
                  default: true
              drives:
                - source: ubuntu-24-04
                  mount: /
                  size: 30GiB
              network:
                interfaces:
                    - network: local
              resources:
                cpuCount: 2
                ramSize: 2GiB
            - name: worker-4
              users:
                - name: root
                  default: true
              drives:
                - source: ubuntu-24-04
                  mount: /
                  size: 30GiB
              network:
                interfaces:
                    - network: local
              resources:
                cpuCount: 2
                ramSize: 2GiB
            - name: worker-5
              users:
                - name: root
                  default: true
              drives:
                - source: ubuntu-24-04
                  mount: /
                  size: 30GiB
              network:
                interfaces:
                    - network: local
              resources:
                cpuCount: 2
                ramSize: 2GiB
        tabs:
            - id: terminal-worker-1
              kind: terminal
              name: worker-1
              machine: worker-1
            - id: terminal-worker-2
              kind: terminal
              name: worker-2
              machine: worker-2
            - id: terminal-worker-3
              kind: terminal
              name: worker-3
              machine: worker-3
            - id: terminal-worker-4
              kind: terminal
              name: worker-4
              machine: worker-4
            - id: terminal-worker-5
              kind: terminal
              name: worker-5
              machine: worker-5
        accessControl:
            canList:
                - anyone
            canRead:
                - anyone
            canStart:
                - anyone
EOF
  echo "sleeping for 10 seconds..."
  sleep 10
}

worker_cluster_id() {
  local cluster_index="$1"
  local anchor_worker

  anchor_worker="$(worker_names_for_cluster "${cluster_index}" | head -n 1)"
  labctl playground list -o json \
    | jq -r --arg machine "${anchor_worker}" '.[] | select(.status.stateEvents[-1].state == "RUNNING") | select(any(.machines[]; .name == $machine)) | .id'
}

log_worker_cluster_network_fingerprint() {
  local cluster_index="$1"
  local playground_id worker

  playground_id="$(worker_cluster_id "${cluster_index}")"
  if [ -z "${playground_id}" ]; then
    echo "unable to find worker-cluster-${cluster_index} for network fingerprint logging" >&2
    return 1
  fi

  echo "worker-cluster-${cluster_index} network fingerprint before rebuild (${playground_id}):"
  while IFS= read -r worker; do
    [ -n "${worker}" ] || continue
    if ! labctl ssh "${playground_id}" --machine "${worker}" <<EOF
set -eu
public_ipv4="\$(tailscale netcheck 2>/dev/null | awk '/IPv4:/ {split(\$4, parts, ":"); print parts[1]; exit}')"
eth0_cidrs="\$(ip -4 -o addr show dev eth0 | awk '{print \$4}' | paste -sd, -)"
default_gw="\$(ip route show default | awk '/default/ {print \$3; exit}')"
tailscale_ip="\$(tailscale ip -4 2>/dev/null | tr -d '\r')"
printf '%s public_ipv4=%s eth0=%s default_gw=%s tailscale_ip=%s\n' "${worker}" "\${public_ipv4:-unknown}" "\${eth0_cidrs:-unknown}" "\${default_gw:-unknown}" "\${tailscale_ip:-unknown}"
EOF
    then
      echo "${worker} public_ipv4=unknown eth0=unknown default_gw=unknown tailscale_ip=unknown" >&2
    fi
  done < <(worker_names_for_cluster "${cluster_index}")
}

enroll_workers_with_tailscale() {
  local worker

  for worker in "$@"; do
    echo "re-enrolling ${worker} in tailscale..."
    bash "${REPO_ROOT}/scripts/provision_tailscale_oauth_oneoff.sh" --only "${worker}"
  done
}

restore_jumpbox_ssh_access() {
  local -a worker_names=("$@")
  local public_key_value worker playground_id update_script

  if [ ! -f "${JUMPBOX_PUBLIC_KEY_FILE}" ]; then
    return 0
  fi

  public_key_value="$(tr -d '\n' < "${JUMPBOX_PUBLIC_KEY_FILE}")"
  update_script="$(sed "s|PUBLIC_KEY_VALUE|$(printf '%s' "${public_key_value}" | sed 's/[&/\]/\\&/g')|" "${REPO_ROOT}/scripts/update_authorized_keys.sh")"

  for worker in "${worker_names[@]}"; do
    playground_id="$(labctl playground list -o json | jq -r --arg machine "${worker}" '.[] | select(.status.stateEvents[-1].state == "RUNNING") | select(any(.machines[]; .name == $machine)) | .id')"
    if [ -z "${playground_id}" ]; then
      echo "unable to find ${worker} to restore jumpbox ssh access" >&2
      return 1
    fi
    echo "restoring jumpbox ssh access on ${worker}..."
    echo "${update_script}" | labctl ssh "${playground_id}" --machine "${worker}"
  done
}

cluster_indexes=("$@")
playground_ids=()
worker_names=()

for cluster_index in "${cluster_indexes[@]}"; do
  log_worker_cluster_network_fingerprint "${cluster_index}"
  playground_id="$(worker_cluster_id "${cluster_index}")"
  if [ -z "${playground_id}" ]; then
    echo "unable to find worker-cluster-${cluster_index} for rebuild" >&2
    exit 1
  fi
  playground_ids+=("${playground_id}")
  while IFS= read -r worker; do
    [ -n "${worker}" ] || continue
    worker_names+=("${worker}")
  done < <(worker_names_for_cluster "${cluster_index}")
done

for playground_id in "${playground_ids[@]}"; do
  echo "destroying worker playground ${playground_id}..."
  labctl playground destroy "${playground_id}"
done

echo "waiting for worker playground replacements to clear..."
if ! wait_for_playgrounds_absent 60 "${playground_ids[@]}"; then
  echo "timed out waiting for worker playground(s) to be destroyed." >&2
  exit 1
fi

if ! delete_tailscale_devices_matching_hosts "${worker_names[@]}"; then
  echo "failed to remove stale tailscale devices for rebuilt workers." >&2
  exit 1
fi

for cluster_index in "${cluster_indexes[@]}"; do
  start_worker_playground "${cluster_index}"
done

echo "waiting for rebuilt worker nodes to reach RUNNING..."
if ! wait_for_running_machines 60 "${worker_names[@]}"; then
  echo "timed out waiting for rebuilt worker nodes to reach RUNNING." >&2
  labctl playground list -o json | jq -r '.[] | "\(.id)\t\(.status.stateEvents[-1].state)\t\([.machines[].name] | join(","))"' >&2
  exit 1
fi

enroll_workers_with_tailscale "${worker_names[@]}"
restore_jumpbox_ssh_access "${worker_names[@]}"
