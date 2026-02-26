# Bootstrapping the Kubernetes Worker Nodes

In this lab you will bootstrap nine Kubernetes worker nodes across 3 playgrounds. The following components will be installed on each node: containerd and kubelet. CNI networking and service proxy functionality are handled by Cilium (deployed in step 11).

## Prerequisites

This lab assumes:

- The Kubernetes control plane is running.
- The jumpbox can SSH to all `worker-*` nodes using `~/.ssh/kubernetes.ed25519`.
- Worker certificates and kubeconfigs were generated and copied to each worker.

The commands in this lab are run from the jumpbox unless otherwise noted.

## Copy Worker Binaries to Each Node

From the jumpbox, copy the worker binaries to each worker:

```sh
for host in worker-{1..9}; do
  scp -i ~/.ssh/kubernetes.ed25519 -r \
    ~/downloads/worker \
    root@${host}:~/
done
```

Now SSH to each worker and run the commands below.

## Provisioning a Worker Node

Install the OS dependencies:

```sh
apt-get update
apt-get -y install socat conntrack ipset
```

Create the required directories:

```sh
mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /etc/containerd \
  /var/lib/kubelet \
  /var/lib/kubernetes \
  /var/run/kubernetes
```

Install the worker binaries:

```sh
for bin in containerd containerd-shim-runc-v2 runc kubelet; do
  install -m 0755 ~/worker/${bin} /usr/local/bin/${bin}
done
```

> **Note**: We do not install CNI plugins (bridge, host-local, loopback) or kube-proxy here. Cilium will be deployed as a DaemonSet in step 11 and handles both CNI networking (via VXLAN overlay) and service proxy (via eBPF kube-proxy replacement).

### Configure containerd

Create the containerd configuration file:

```sh
cat <<'EOF' > /etc/containerd/config.toml
version = 2

[plugins."io.containerd.grpc.v1.cri"]
[plugins."io.containerd.grpc.v1.cri".containerd]
snapshotter = "overlayfs"
default_runtime_name = "runc"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
SystemdCgroup = true
[plugins."io.containerd.grpc.v1.cri".cni]
bin_dir = "/opt/cni/bin"
conf_dir = "/etc/cni/net.d"
EOF
```

Create the `containerd.service` unit file:

```sh
cat <<'EOF' > /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
```

### Configure the Kubelet

Ensure the kubelet certificates and kubeconfigs are in place:

```sh
# These files should already exist from earlier steps.
# If not, copy them from the jumpbox.
ls -la /var/lib/kubelet/kubelet.crt /var/lib/kubelet/kubelet.key /var/lib/kubelet/kubeconfig
```

Determine this worker's pod CIDR based on its hostname:

```sh
WORKER_NUMBER=$(hostname | awk -F '-' '{print $2}')
POD_CIDR="10.200.${WORKER_NUMBER}.0/24"
```

Create the kubelet configuration file:

```sh
cat <<EOF > /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
address: '0.0.0.0'
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: '/var/lib/kubelet/ca.crt'
authorization:
  mode: Webhook
clusterDomain: 'cluster.local'
clusterDNS:
  - '10.32.0.10'
cgroupDriver: systemd
containerRuntimeEndpoint: 'unix:///var/run/containerd/containerd.sock'
enableServer: true
failSwapOn: false
maxPods: 16
memorySwap:
  swapBehavior: NoSwap
podCIDR: '${POD_CIDR}'
port: 10250
resolvConf: '/etc/resolv.conf'
registerNode: true
runtimeRequestTimeout: '15m'
tlsCertFile: '/var/lib/kubelet/kubelet.crt'
tlsPrivateKeyFile: '/var/lib/kubelet/kubelet.key'
EOF
```

Create the `kubelet.service` unit file:

```sh
cat <<'EOF' > /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Start the Worker Services

```sh
swapoff -a

systemctl daemon-reload
systemctl enable containerd kubelet
systemctl start containerd kubelet
```

> **Note**: Nodes will appear as `NotReady` until Cilium is deployed in step 11, which installs the CNI plugin.

Repeat the worker setup on all nine workers.

## Verification

From controller-1, check node status:

```sh
ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1 \
  "kubectl get nodes --kubeconfig /root/admin.kubeconfig"
```

Nodes will show `NotReady` — this is expected. They will become `Ready` after Cilium is deployed.

Next: [Configuring kubectl for Remote Access](10-configuring-kubectl.md)
