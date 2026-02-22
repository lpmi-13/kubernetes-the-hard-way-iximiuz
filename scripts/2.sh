#!/usr/bin/env bash
set -euo pipefail

# Tailscale cleanup: remove devices that match current lab machine names and tag.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1090
  . ./.env
  set +a
fi

if [ -n "${TS_API_CLIENT_ID:-}" ] && [ -n "${TS_API_CLIENT_SECRET:-}" ]; then
  TS_TAGS="${TS_TAGS:-tag:kthw}"

  if ! command -v labctl >/dev/null 2>&1; then
    echo "labctl not found; skipping tailscale cleanup" >&2
  elif ! command -v jq >/dev/null 2>&1; then
    echo "jq not found; skipping tailscale cleanup" >&2
  elif ! command -v curl >/dev/null 2>&1; then
    echo "curl not found; skipping tailscale cleanup" >&2
  else
    echo "cleaning up tailscale devices..."

    oauth_resp="$(curl -sS -u "${TS_API_CLIENT_ID}:${TS_API_CLIENT_SECRET}" -d grant_type=client_credentials https://api.tailscale.com/api/v2/oauth/token)"
    access_token="$(echo "$oauth_resp" | jq -er '.access_token')"

    devices_json="$(curl -sS -H "Authorization: Bearer ${access_token}" https://api.tailscale.com/api/v2/tailnet/-/devices)"

    machine_names="$(labctl playground list -o json | jq -r '(. // [])[]? | (.machines // [])[].name // empty')"

    declare -A target_hosts=()
    if [ -n "${machine_names}" ]; then
      while IFS= read -r name; do
        [ -z "$name" ] && continue
        target_hosts["$name"]=1
      done <<< "${machine_names}"
    fi

    declare -A required_tags=()
    IFS=',' read -r -a ts_tags_array <<<"${TS_TAGS}"
    for tag in "${ts_tags_array[@]}"; do
      tag="$(echo "$tag" | xargs)"
      [ -z "$tag" ] && continue
      required_tags["$tag"]=1
    done

    while IFS=$'\t' read -r device_id device_name online tags_csv; do
      [ -z "$device_id" ] && continue
      [ -z "$device_name" ] && continue

      if [ "${#target_hosts[@]}" -gt 0 ]; then
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

      echo "deleting tailscale device ${device_name} (${device_id})"
      curl -sS -X DELETE -H "Authorization: Bearer ${access_token}" \
        "https://api.tailscale.com/api/v2/device/${device_id}" >/dev/null
    done < <(echo "$devices_json" | jq -r '(.devices // [])[] | [(.id // ""), (.name // .hostname // ""), ((.online // false)|tostring), ((.tags // [])|join(","))] | @tsv')
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

# Set up 3 worker clusters with sequential worker numbering (1-9)
for i in {1..3}; do
  # Calculate worker number range for this cluster
  start_worker=$(( ($i - 1) * 3 + 1 ))
  end_worker=$(( $start_worker + 2 ))

  labctl playground start flexbox -f -<<EOF
    kind: playground
    name: worker-cluster-"${i}"
    title: Worker Cluster "$i"
    description: Worker cluster "$i" (workers ${start_worker}-${end_worker}) for the k8s the hard way cluster of clusters
    categories:
        - linux
        - kubernetes
    playground:
        networks:
            - name: local
              subnet: "172.16.$i.0/24"
        machines:
            - name: worker-${start_worker}
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
            - name: worker-$((start_worker+1))
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
            - name: worker-${end_worker}
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
            - id: terminal-worker-${start_worker}
              kind: terminal
              name: worker-${start_worker}
              machine: worker-${start_worker}
            - id: terminal-worker-$((start_worker+1))
              kind: terminal
              name: worker-$((start_worker+1))
              machine: worker-$((start_worker+1))
            - id: terminal-worker-${end_worker}
              kind: terminal
              name: worker-${end_worker}
              machine: worker-${end_worker}
        accessControl:
            canList:
                - anyone
            canRead:
                - anyone
            canStart:
                - anyone
EOF
echo sleeping for 10 seconds...
sleep 10
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
  worker-1 worker-2 worker-3 worker-4 worker-5 worker-6 worker-7 worker-8 worker-9
)

wait_ok=false
for _ in {1..60}; do
  list_json="$(labctl playground list -o json)"
  running_playgrounds="$(echo "$list_json" | jq -r '[.[] | select(.status.stateEvents[-1].state == "RUNNING")] | length')"

  if [ "$running_playgrounds" -lt 5 ]; then
    sleep 2
    continue
  fi

  running_names="$(echo "$list_json" | jq -r '.[] | select(.status.stateEvents[-1].state == "RUNNING") | .machines[].name')"
  missing=0
  for name in "${required_machines[@]}"; do
    if ! grep -qx "$name" <<<"$running_names"; then
      missing=$((missing + 1))
    fi
  done

  if [ "$missing" -eq 0 ]; then
    wait_ok=true
    break
  fi

  sleep 2
done

if [ "$wait_ok" = false ]; then
  echo "timed out waiting for all machines to be RUNNING; current status:" >&2
  labctl playground list -o json | jq -r '.[] | "\(.id)\t\(.status.stateEvents[-1].state)\t\([.machines[].name] | join(","))"' >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "missing .env; create it from .env.example before provisioning tailscale" >&2
  exit 1
fi

source .env

bash scripts/provision_tailscale_oauth_oneoff.sh
