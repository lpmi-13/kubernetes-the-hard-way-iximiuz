# Bootstrapping the Kubernetes Control Plane

In this lab you will bootstrap the Kubernetes control plane across three controller nodes and configure HAProxy on the load-balancer. The HAProxy load balancer is the canonical API entrypoint for the jumpbox and for future external access, and it distributes requests across controller nodes using the default HAProxy balancing behavior.

## Prerequisites

This lab assumes:

- The `controller-*`, `load-balancer`, and `jumpbox` nodes are running.
- Tailscale is installed and running on all nodes.
- Certificates, kubeconfigs, and the encryption config were generated on the jumpbox.
- The etcd cluster is bootstrapped on all controllers.

The commands in this lab are run from the jumpbox unless otherwise noted.

## Configure HAProxy on the Load Balancer

SSH to the load balancer and install HAProxy:

```sh
ssh -i ~/.ssh/kubernetes.ed25519 root@load-balancer
apt update && apt install -y haproxy
systemctl enable haproxy
```

Create the HAProxy configuration file:

```sh
cat <<'HAPROXY' > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

frontend kubernetes_api
    bind *:6443
    mode tcp
    default_backend k8s_controllers

backend k8s_controllers
    mode tcp
    balance roundrobin
    server controller-1 controller-1:6443 check
    server controller-2 controller-2:6443 check
    server controller-3 controller-3:6443 check

listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth admin:ChangeThisPassword
HAPROXY
```

Restart HAProxy:

```sh
systemctl restart haproxy
```

Exit the load balancer shell:

```sh
exit
```

## Configure the API Hostname

All kubeconfigs in this walkthrough use `server.kubernetes.local:6443`. That hostname should resolve to the load balancer.

Get the load balancer Tailscale IP from the jumpbox:

```sh
LOAD_BALANCER_IP=$(ssh -i ~/.ssh/kubernetes.ed25519 root@load-balancer "tailscale ip -4" | tr -d '\n\r')
```

Update the `/etc/hosts` entry on the jumpbox:

```sh
sudo sed -i "/[[:space:]]server.kubernetes.local$/d" /etc/hosts
printf '%s %s\n' "${LOAD_BALANCER_IP}" "server.kubernetes.local" | sudo tee -a /etc/hosts >/dev/null
```

Update `/etc/hosts` on all nodes:

```sh
for host in controller-{1..3} worker-{1..5} load-balancer; do
  ssh -i ~/.ssh/kubernetes.ed25519 root@${host} \
    "sed -i '/[[:space:]]server.kubernetes.local$/d' /etc/hosts; \
     printf '%s %s\n' '${LOAD_BALANCER_IP}' 'server.kubernetes.local' >> /etc/hosts"
done
```

## Provision the Control Plane

The following commands must be run on each controller: `controller-1`, `controller-2`, and `controller-3`.

From the jumpbox, copy the controller binaries and kubectl to each controller:

```sh
for host in controller-{1..3}; do
  scp -i ~/.ssh/kubernetes.ed25519 \
    ~/downloads/controller/* \
    ~/downloads/client/kubectl \
    root@${host}:~/
done
```

Now SSH to each controller and run the commands below.

### Install the Controller Binaries

```sh
chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
```

### Configure the Kubernetes API Server

Create the Kubernetes directories:

```sh
mkdir -p /etc/kubernetes/config /var/lib/kubernetes
```

Move the certificates and encryption config into place:

```sh
cp ca.crt ca.key \
  front-proxy-ca.crt \
  front-proxy-client.crt front-proxy-client.key \
  kube-api-server.crt kube-api-server.key \
  service-accounts.crt service-accounts.key \
  encryption-config.yaml /var/lib/kubernetes/
```

Create the `kube-apiserver.service` unit file:

```sh
ADVERTISE_ADDRESS=$(tailscale ip -4)

cat <<EOF > /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${ADVERTISE_ADDRESS} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.crt \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-servers=http://127.0.0.1:2379 \\
  --event-ttl=1h \\
  --enable-aggregator-routing=true \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/kube-api-server.crt \\
  --kubelet-client-key=/var/lib/kubernetes/kube-api-server.key \\
  --proxy-client-cert-file=/var/lib/kubernetes/front-proxy-client.crt \\
  --proxy-client-key-file=/var/lib/kubernetes/front-proxy-client.key \\
  --requestheader-allowed-names=front-proxy-client \\
  --requestheader-client-ca-file=/var/lib/kubernetes/front-proxy-ca.crt \\
  --requestheader-extra-headers-prefix=X-Remote-Extra- \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-accounts.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-accounts.key \\
  --service-account-issuer=https://server.kubernetes.local:6443 \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kube-api-server.crt \\
  --tls-private-key-file=/var/lib/kubernetes/kube-api-server.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Configure the Kubernetes Controller Manager

Move the kubeconfig into place:

```sh
cp kube-controller-manager.kubeconfig /var/lib/kubernetes/
```

Create the `kube-controller-manager.service` unit file:

```sh
cat <<EOF > /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.crt \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca.key \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.crt \\
  --service-account-private-key-file=/var/lib/kubernetes/service-accounts.key \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Configure the Kubernetes Scheduler

Move the kubeconfig into place:

```sh
cp kube-scheduler.kubeconfig /var/lib/kubernetes/
```

Create the scheduler configuration file:

```sh
cat <<EOF > /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF
```

Create the `kube-scheduler.service` unit file:

```sh
cat <<EOF > /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Start the Controller Services

```sh
systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl start kube-apiserver kube-controller-manager kube-scheduler
```

Repeat the controller setup on all three controllers.

## Configure RBAC for the API Server to Kubelet Access

On controller-1, create the RBAC manifest:

```sh
cat <<'EOF' > /root/kube-api-server-to-kubelet.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: 'true'
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ''
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - '*'
---
apiVersion: rbac.authorization.kubernetes.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ''
roleRef:
  apiGroup: rbac.authorization.kubernetes.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.kubernetes.io
    kind: User
    name: kubernetes
EOF
```

Apply the RBAC bindings:

```sh
kubectl apply --kubeconfig /root/admin.kubeconfig -f /root/kube-api-server-to-kubelet.yaml
```

## Verification

From controller-1, verify component health:

```sh
kubectl get componentstatuses --kubeconfig /root/admin.kubeconfig
```

From the jumpbox, verify the API server through HAProxy:

```sh
curl -k --cacert ~/ca.crt https://server.kubernetes.local:6443/version
```

Next: [Bootstrapping the Kubernetes Worker Nodes](09-bootstrapping-kubernetes-workers.md)
