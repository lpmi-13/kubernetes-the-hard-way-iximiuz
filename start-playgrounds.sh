# just to keep this tidy, clean up any existing playgrounds first
echo "checking for existing playgrounds to clean up..."
for playground_id in $(labctl playground list -q); do
  labctl playground stop $playground_id
done

# Set up 1 worker cluster with 5 workers
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
