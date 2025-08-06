# Bootstrapping the etcd Cluster

Kubernetes components are stateless and store cluster state in [etcd](https://github.com/etcd-io/etcd). In this lab you will bootstrap a multi-node etcd cluster.

> The original was a single-node cluster, but we gotta do it real big!

## Prerequisites

### Getting the correct IP addresses for the cluster

Since etcd can't use domain names for all of its configuration, we need to get the tailscale IPs.

> NB: We technically _could_ just use the internal private IPs from the subnet, since this is only for etcd cluster communication, but this approach will work even if the etcd cluster is split across subnets (or even regions!), and tailscale is cool, so let's use it

Run the following commands on the jumpbox:

```bash
CONTROLLER_1_IP=$(ssh -i ~/.ssh/kubernetes.ed25519 controller-1 "tailscale ip -4" | tr -d '\n\r')
CONTROLLER_2_IP=$(ssh -i ~/.ssh/kubernetes.ed25519 controller-2 "tailscale ip -4" | tr -d '\n\r')
CONTROLLER_3_IP=$(ssh -i ~/.ssh/kubernetes.ed25519 controller-3 "tailscale ip -4" | tr -d '\n\r')

# now we swap those into the unit file for the placeholder values
sed -i "s|CONTROLLER_1_IP|${CONTROLLER_1_IP}|g" ./units/etcd.service
sed -i "s|CONTROLLER_2_IP|${CONTROLLER_2_IP}|g" ./units/etcd.service
sed -i "s|CONTROLLER_3_IP|${CONTROLLER_3_IP}|g" ./units/etcd.service
```

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

The commands in the rest of this lab must be run on the `controller-*` machines. Login to each of the `controller-*` machines using the `ssh` command. Example:

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

We first need to swap in the hostnames for the NODE_NAME placeholder (this is so each of the cluster members can find each other). We also need the IPs of the node for each of the individual etcd members.

```bash
sudo sed -i "s/NODE_NAME/$(hostname -s)/g" etcd.service
sudo sed -i "s/NODE_IP/$(tailscale ip -4)/g" etcd.service
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

And now we've got a live etcd cluster :tada:

```text
726a079b31509e4c, started, controller-1, http://100.123.83.62:2380, http://100.123.83.62:2379, false
a429c409a79b5330, started, controller-2, http://100.66.41.29:2380, http://100.66.41.29:2379, false
e71faea8aa692d80, started, controller-3, http://100.95.84.24:2380, http://100.95.84.24:2379, false
```

Next: [Bootstrapping the Kubernetes Control Plane](08-bootstrapping-kubernetes-controllers.md)
