#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTENV_FILE="${DOTENV_FILE:-${REPO_ROOT}/.env}"

# Tailscale cleanup: remove devices that match current lab machine names and tag.
if [ -f "$DOTENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DOTENV_FILE"
  set +a
fi

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

delete_tailscale_devices_matching_hosts() {
  local context_label="$1"
  shift
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
  local tag device_tag

  if [ "${#machine_names[@]}" -eq 0 ]; then
    return 0
  fi

  oauth_resp_file="$(mktemp)"
  oauth_http_code="$(
    curl -sS -o "${oauth_resp_file}" -w '%{http_code}' \
      -u "${TS_API_CLIENT_ID}:${TS_API_CLIENT_SECRET}" \
      -d grant_type=client_credentials \
      https://api.tailscale.com/api/v2/oauth/token
  )"
  if [ "${oauth_http_code}" -ne 200 ]; then
    api_message="$(jq -r '.message // empty' "${oauth_resp_file}" 2>/dev/null || true)"
    echo "tailscale cleanup failed (${context_label}): unable to mint OAuth token (HTTP ${oauth_http_code})." >&2
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
    echo "tailscale cleanup failed (${context_label}): unable to list devices (HTTP ${devices_http_code})." >&2
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
  echo "tailscale cleanup summary (${context_label}): ${cleanup_candidates} candidates, ${cleanup_deleted} deleted, ${cleanup_failed} failed."

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

if [ -n "${TS_API_CLIENT_ID:-}" ] && [ -n "${TS_API_CLIENT_SECRET:-}" ]; then
  if ! command -v labctl >/dev/null 2>&1; then
    echo "labctl not found; skipping tailscale cleanup" >&2
  elif ! command -v jq >/dev/null 2>&1; then
    echo "jq not found; skipping tailscale cleanup" >&2
  elif ! command -v curl >/dev/null 2>&1; then
    echo "curl not found; skipping tailscale cleanup" >&2
  else
    echo "cleaning up tailscale devices..."
    mapfile -t existing_machine_names < <(labctl playground list -o json | jq -r '(. // [])[]? | (.machines // [])[].name // empty')
    if ! delete_tailscale_devices_matching_hosts "initial cleanup" "${existing_machine_names[@]}"; then
      echo "tailscale cleanup failed; aborting before playground rebuild." >&2
      exit 1
    fi
  fi
else
  echo "tailscale cleanup skipped (TS_API_CLIENT_ID/TS_API_CLIENT_SECRET not set)"
fi

# just to keep this tidy, clean up any existing playgrounds first
echo "checking for existing playgrounds to clean up..."
existing_playgrounds=$(labctl playground list -q || true)
if [ -n "${existing_playgrounds}" ]; then
  for playground_id in ${existing_playgrounds}; do
    labctl playground destroy "${playground_id}"
  done

  echo "waiting for playgrounds to be destroyed..."
  for _ in {1..60}; do
    if [ -z "$(labctl playground list -q || true)" ]; then
      break
    fi
    sleep 2
  done
fi

# Set up 1 worker cluster with 5 worker nodes
for i in 1; do
  start_worker_playground "${i}"
done

# set up the cluster with 3 controller nodes
echo "starting controller cluster..."
labctl playground start flexbox -f -<<EOF
  kind: playground
  name: controller-cluster
  title: Controller Cluster
  description: controller node cluster for the iximiuz kubernetes cluster of clusters
  categories:
      - linux
      - kubernetes
  playground:
      networks:
          - name: local
            subnet: 172.16.4.0/24
      machines:
          - name: controller-1
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
              ramSize: 4GiB
          - name: controller-2
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
              ramSize: 4GiB

          - name: controller-3
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
              ramSize: 4GiB

          - name: load-balancer
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
              ramSize: 4GiB
      tabs:
          - id: terminal-controller-1
            kind: terminal
            name: controller-1
            machine: controller-1
          - id: terminal-controller-2
            kind: terminal
            name: controller-2
            machine: controller-2
          - id: terminal-controller-3
            kind: terminal
            name: controller-3
            machine: controller-3
          - id: terminal-load-balancer
            kind: terminal
            name: load-balancer
            machine: load-balancer
      accessControl:
          canList:
              - anyone
          canRead:
              - anyone
          canStart:
              - anyone
EOF

# and now we configure the jumpbox where we install all the tooling (so we don't clutter your local workstation)
echo "starting jumpbox..."
labctl playground start flexbox -f -<<EOF
  kind: playground
  name: jumpbox
  title: Jumpbox
  description: jumpbox for running all the commands into the cluster of clusters
  categories:
      - linux
      - kubernetes
  playground:
      networks:
          - name: local
            subnet: 172.16.5.0/24
      machines:
          - name: jumpbox
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
              ramSize: 4GiB
      tabs:
          - id: terminal-jumpbox
            kind: terminal
            name: jumpbox
            machine: jumpbox
      accessControl:
          canList:
              - anyone
          canRead:
              - anyone
          canStart:
              - anyone
EOF

echo "waiting for all playgrounds to reach RUNNING before tailscale enrollment..."
required_machines=(
  controller-1 controller-2 controller-3 load-balancer jumpbox
  worker-1 worker-2 worker-3 worker-4 worker-5
)

if ! wait_for_running_machines 60 "${required_machines[@]}"; then
  echo "timed out waiting for all machines to be RUNNING; current status:" >&2
  labctl playground list -o json | jq -r '.[] | "\(.id)\t\(.status.stateEvents[-1].state)\t\([.machines[].name] | join(","))"' >&2
  exit 1
fi

if [ ! -f "$DOTENV_FILE" ]; then
  echo "missing .env; create it from .env.example before provisioning tailscale" >&2
  exit 1
fi

. "$DOTENV_FILE"

bash "${REPO_ROOT}/scripts/provision_tailscale_oauth_oneoff.sh"
