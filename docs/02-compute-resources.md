# Provisioning Compute Resources

Since everything is going to be on the remote system, we can just use `labctl` to iterate through setting up different configurations of the `Flexbox` playground.

> NB: You might have noticed that this step usually comes after setting up the client tools, but since we're setting up all the tools on the remote jumpbox, we need that server to be alive first.

## Setting up the worker and controller nodes

We're going to have 3 different clusters of worker nodes, each with 3 worker node machines. So in total, we'll have 9 worker nodes spread across 3 different subnets.

```sh
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
            - name: worker-$((start_worker+1))
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
            - name: worker-${end_worker}
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
2. Create an OAuth client for this tailnet with `auth_keys` write access.
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

This runs locally, generates one-off keys via OAuth, and joins each VM to the tailnet.

```sh
bash scripts/provision_tailscale_oauth_oneoff.sh
```

Useful options:

```sh
# Show what would be enrolled without making changes
bash scripts/provision_tailscale_oauth_oneoff.sh --dry-run

# Enroll only a subset of machines
bash scripts/provision_tailscale_oauth_oneoff.sh --only 'worker-*'
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
