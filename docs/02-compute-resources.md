# Provisioning Compute Resources

Since everything is going to be on the remote system, we can just use `labctl` to iterate through setting up different configurations of the `Flexbox` playground.

> NB: You might have noticed that this step usually comes after setting up the client tools, but since we're setting up all the tools on the remote jumpbox, we need that server to be alive first.

## Setting up the worker and controller nodes

We're going to have 1 worker playground with 5 worker node machines. So in total, we'll have 5 worker nodes sharing a single worker subnet.

```sh
for i in 1; do
  labctl playground start flexbox -f -<<EOF
    kind: playground
    name: worker-cluster-"${i}"
    title: Worker Cluster "$i"
    description: Worker cluster "$i" (workers 1-5) for the k8s the hard way cluster of clusters
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
                - name: laborant
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
                - name: laborant
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
                - name: laborant
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
                - name: laborant
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
                - name: laborant
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
```

And after that, we're ready to set up the controller node cluster

```sh
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
              - name: laborant
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
              - name: laborant
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
              - name: laborant
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
      accessControl:
          canList:
              - anyone
          canRead:
              - anyone
          canStart:
              - anyone
EOF
```

and lastly, we can set up the jumpbox, which is where all the tooling will be, and where we actually run the majority of the commands.

```sh
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
              - name: laborant
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
```

## Installing tailscale

The way the nodes are going to actually communicate with each other is through the magic of tailscale DNS. Even though they _look_ like they're in the same larger subnet (172.16.0.0/16), since they're all on separate iximiuz Labs "clusters", they won't be able to contact each other by default (which is good, and by design). But though the awesome overlay network, we'll get them chatting!

We're going to use OAuth to mint a fresh one-off auth key for each machine at provisioning time. That keeps keys single-use and avoids storing a reusable auth key in `.env`.

### One-time Tailscale OAuth bootstrap

1. In the Tailscale admin console, create the tag you'll use for lab machines (for example, `tag:kthw`).
2. Create an OAuth client for this tailnet with `auth_keys` and `devices:core` access.
3. Allow that OAuth client to create auth keys with your chosen tag (for example, `tag:kthw`).
4. Save the OAuth client ID and secret.

See the official reference for OAuth clients: <https://tailscale.com/docs/features/oauth-clients>.

### Configure local environment

```sh
cp .env.example .env
```

Set the values in `.env`:

- `TS_API_CLIENT_ID`
- `TS_API_CLIENT_SECRET`
- `TS_TAGS` (defaults to `tag:kthw`)

Load the env vars:

```sh
source .env
```

### Install and enroll all machines

This runs locally, generates one-off keys via OAuth, and joins each VM to the
tailnet.

```sh
bash <<'EOF'
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_cmd labctl
require_cmd go
require_cmd jq

: "${TS_API_CLIENT_ID:?TS_API_CLIENT_ID must be set}"
: "${TS_API_CLIENT_SECRET:?TS_API_CLIENT_SECRET must be set}"

TS_TAGS="${TS_TAGS:-tag:kthw}"
TS_GO_CACHE_ROOT="${TS_GO_CACHE_ROOT:-/tmp/kthw-go}"
mkdir -p "${TS_GO_CACHE_ROOT}/gopath/pkg/mod" "${TS_GO_CACHE_ROOT}/gocache"

generate_auth_key() {
  GOPATH="${TS_GO_CACHE_ROOT}/gopath" \
  GOMODCACHE="${TS_GO_CACHE_ROOT}/gopath/pkg/mod" \
  GOCACHE="${TS_GO_CACHE_ROOT}/gocache" \
  go run tailscale.com/cmd/get-authkey@latest -ephemeral -preauth -tags "${TS_TAGS}" | tr -d '[:space:]'
}

while IFS=$'\t' read -r playground_id machine_name; do
  [ -n "${playground_id}" ] || continue
  [ -n "${machine_name}" ] || continue

  auth_key="$(generate_auth_key)"

  labctl ssh "${playground_id}" --machine "${machine_name}" \
    "TAILSCALE_AUTH_KEY='${auth_key}' TAILSCALE_HOSTNAME='${machine_name}' TAILSCALE_TAGS='${TS_TAGS}' sh -s" <<'REMOTE'
set -eu

if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  echo "TAILSCALE_AUTH_KEY must be set" >&2
  exit 1
fi

if [ -z "${TAILSCALE_HOSTNAME:-}" ]; then
  TAILSCALE_HOSTNAME="$(hostname)"
fi

if [ -z "${TAILSCALE_TAGS:-}" ]; then
  TAILSCALE_TAGS="tag:kthw"
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

$SUDO systemctl enable --now tailscaled
$SUDO tailscale up \
  --auth-key="${TAILSCALE_AUTH_KEY}" \
  --hostname="${TAILSCALE_HOSTNAME}" \
  --advertise-tags="${TAILSCALE_TAGS}"
$SUDO tailscale status >/dev/null
REMOTE
done < <(
  labctl playground list -o json \
    | jq -r '.[] | select(.status.stateEvents[-1].state == "RUNNING") | .id as $id | .machines[].name | [$id, .] | @tsv'
)
EOF
```

### Verify

Check that Tailscale is up on every node:

```sh
for playground_id in $(labctl playground list -q); do
  for machine_name in $(labctl playground machines "$playground_id" | sed '1d'); do
    echo "=== $machine_name ==="
    labctl ssh "$playground_id" --machine "$machine_name" tailscale status --json >/dev/null && echo ok
  done
done
```

At this stage it is worth confirming that workers in different playgrounds can reach each other cleanly over Tailscale. Early worker-to-worker reachability problems often show up later as kubelet, metrics, or cross-node networking failures.

### Cleanup

To tear down lab resources, remove matching Tailscale devices, destroy the
playgrounds, and delete the local SSH keys:

```sh
bash <<'EOF'
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_cmd labctl
require_cmd jq
require_cmd curl

: "${TS_API_CLIENT_ID:?TS_API_CLIENT_ID must be set}"
: "${TS_API_CLIENT_SECRET:?TS_API_CLIENT_SECRET must be set}"

TS_TAGS="${TS_TAGS:-tag:kthw}"
REPO_ROOT="$(pwd)"
playgrounds_json="$(labctl playground list -o json)"

mapfile -t PLAYGROUND_IDS < <(echo "${playgrounds_json}" | jq -r '(. // [])[]? | .id // empty')
mapfile -t MACHINE_NAMES < <(echo "${playgrounds_json}" | jq -r '(. // [])[]? | (.machines // [])[].name // empty')

oauth_resp="$(curl -sS -u "${TS_API_CLIENT_ID}:${TS_API_CLIENT_SECRET}" -d grant_type=client_credentials https://api.tailscale.com/api/v2/oauth/token)"
access_token="$(echo "${oauth_resp}" | jq -er '.access_token')"

devices_resp_file="$(mktemp)"
curl -sS -o "${devices_resp_file}" \
  -H "Authorization: Bearer ${access_token}" \
  https://api.tailscale.com/api/v2/tailnet/-/devices >/dev/null

declare -A target_hosts=()
for machine_name in "${MACHINE_NAMES[@]}"; do
  target_hosts["${machine_name}"]=1
done

declare -A required_tags=()
IFS=',' read -r -a ts_tags_array <<<"${TS_TAGS}"
for tag in "${ts_tags_array[@]}"; do
  tag="$(echo "${tag}" | xargs)"
  [ -n "${tag}" ] && required_tags["${tag}"]=1
done

while IFS=$'\t' read -r device_id device_name online tags_csv; do
  [ -n "${device_id}" ] || continue
  short_name="${device_name%%.*}"

  match_host=false
  if [ -n "${target_hosts[${short_name}]:-}" ]; then
    match_host=true
  else
    for host in "${!target_hosts[@]}"; do
      if [[ "${short_name}" == "${host}"-* ]]; then
        match_host=true
        break
      fi
    done
  fi
  [ "${match_host}" = true ] || continue

  tag_match=false
  IFS=',' read -r -a device_tags <<<"${tags_csv}"
  for device_tag in "${device_tags[@]}"; do
    device_tag="$(echo "${device_tag}" | xargs)"
    if [ -n "${device_tag}" ] && [ -n "${required_tags[${device_tag}]:-}" ]; then
      tag_match=true
      break
    fi
  done
  [ "${tag_match}" = true ] || continue

  curl -sS -X DELETE \
    -H "Authorization: Bearer ${access_token}" \
    "https://api.tailscale.com/api/v2/device/${device_id}" >/dev/null
done < <(jq -r '(.devices // [])[] | [(.id // ""), (.name // .hostname // ""), ((.online // false)|tostring), ((.tags // [])|join(","))] | @tsv' "${devices_resp_file}")

rm -f "${devices_resp_file}"

declare -A seen_playgrounds=()
for playground_id in "${PLAYGROUND_IDS[@]}"; do
  [ -n "${seen_playgrounds[${playground_id}]:-}" ] && continue
  seen_playgrounds["${playground_id}"]=1
  labctl playground destroy "${playground_id}"
done

rm -f "${REPO_ROOT}"/kubernetes.ed25519*
EOF
```
