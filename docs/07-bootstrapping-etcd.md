# Bootstrapping the etcd Cluster

Kubernetes components are stateless and store cluster state in [etcd](https://github.com/etcd-io/etcd). In this lab you will bootstrap a multi-node etcd cluster.

> The original was a single-node cluster, but we gotta do it real big!

## Prerequisites

Copy `etcd` binaries and systemd unit files to the `controller-*` machines:

```bash
for host in controller-{1..3}; do
 scp -i ~/.ssh/kubernetes.ed25519 \
    downloads/controller/etcd \
    downloads/client/etcdctl \
    units/etcd.service \
    root@${host}:~/
done
```

The commands in this lab must be run on the `controller-*` machines. Login to each of the `controller-*` machines using the `ssh` command. Example:

```bash
ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1
```

## Bootstrapping an etcd Cluster

### Install the etcd Binaries

Extract and install the `etcd` server and the `etcdctl` command line utility:

```bash
mv etcd etcdctl /usr/local/bin/
```

### Configure the etcd Server

```bash
mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd
cp ca.crt kube-api-server.key kube-api-server.crt \
  /etc/etcd/
```

Each etcd member must have a unique name within an etcd cluster. Set the etcd name to match the hostname of the current compute instance:

Create the `etcd.service` systemd unit file:

We first need to swap in the hostnames for the NODE_NAME placeholder (this is so each of the cluster members can find each other)

```bash
sudo sed -i "s/NODE_NAME/$(hostname -s)/g" etcd.service
```

Then once that's done, we can put it in the right place for systemd to pick it up.

```bash
mv etcd.service /etc/systemd/system/
```

### Start the etcd Server

```bash
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
```

## Verification

List the etcd cluster members:

```bash
etcdctl member list
```

THIS IS GOING TO BE DIFFERENT AND HOPEFULLY HAVE THREE MEMBERS
```text
6702b0a34e2cfd39, started, controller, http://127.0.0.1:2380, http://127.0.0.1:2379, false
```

Next: [Bootstrapping the Kubernetes Control Plane](08-bootstrapping-kubernetes-controllers.md)
