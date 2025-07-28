# just to keep this tidy, clean up any existing playgrounds first
echo "checking for existing playgrounds to clean up..."
for playground_id in $(labctl playground list -q); do
  labctl playground stop $playground_id
done

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
                ramSize: 1.5GiB
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
                ramSize: 1.5GiB
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
                ramSize: 1.5GiB
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
              ramSize: 1.5GiB
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
              ramSize: 1.5GiB

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
              ramSize: 1.5GiB

          - name: load-balancer
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
              ramSize: 1.5GiB
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
              ramSize: 1.5GiB
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

source .env

for playground_id in $(labctl playground list -q); do
  for machine_name in $(labctl playground machines $playground_id | sed '1d'); do
    SCRIPT=$(sed "s/TAILSCALE_AUTH_KEY_PLACEHOLDER/${TAILSCALE_AUTH_KEY//\"/\\\"}/" scripts/install_tailscale.sh)
    echo "$SCRIPT" | labctl ssh $playground_id --machine $machine_name
  done
done
