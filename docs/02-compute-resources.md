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
```
