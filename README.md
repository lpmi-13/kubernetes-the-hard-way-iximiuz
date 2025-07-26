# Kubernetes multi-cluster cluster

This is the working title of creating a mega-cluster on Iximiuz Labs via tailscale tailnet.

The idea is that in the original k8s-the-hard-way, we had 3 control plan nodes and 3 worker nodes, but now we're going to have one cluster of control plane nodes (3) and three clusters of worker nodes (3 x 3)...all networked via tailscale.

We'll also have one admin node in a standalone ubuntu playground to act as the jumpbox (a concept that Kelsey Hightower introduced in the later K8s the hard way walkthroughs to simplify the setup a bit, so I copied it here as well). This is the machine that we'll use to actually provision the k8s megacluster, and since it's also an ephemeral VM, there's no clean up to be done, just shut it down!

## Cluster Details

Kubernetes The Hard Way guides you through bootstrapping a basic Kubernetes cluster with all control plane components running on a single node, and two worker nodes, which is enough to learn the core concepts.

Component versions:

* [kubernetes](https://github.com/kubernetes/kubernetes) v1.32.x
* [containerd](https://github.com/containerd/containerd) v2.1.x
* [cni](https://github.com/containernetworking/cni) v1.6.x
* [etcd](https://github.com/etcd-io/etcd) v3.6.x

## Action sequence

Because we're interacting with the VMs slightly differently from a regular cloud provider, and the configuration is a bit custom, we need to do things a bit different from the regular tutorial.

1) We create all the clusters. For now, we'll do 4 flexbox playgrounds that each have 3 machines (1 controller cluster and three worker node clusters), and one standalone flexbox playground (that only has one machine in it) as the jumpbox server.

2) We install all the necessary tooling in the jumpbox.

> We do this here so we can just install the tooling once and copy it over to all the other servers. Also so we don't need to clutter your local workstation with anything!

3) We configure the networking. This is using tailscale and is going to be conceptually very simple, but we just need to track all the DNS names for each of the hosts. Maybe a scheme like:

- jumpbox
- controller-{1..3}
- worker-{1..3}
- worker-{4..6}
- worker-{7..9}

We also set the hostnames as above, so we can install/start tailscale on each node and they'll be able to contact each other using just the hostname as the DNS name (magic!).

4) We set up the PKI certificate authority and distribute certs/keys/etc to each of the machines.

5) We generate the kubernetes config files for the worker nodes.

6) We generate and distribute the data encryption keys.

7) We bootstrap an etcd server (we might want to do this with an etcd cluster...not sure yet)

8) We bootstrap the kubernetes control plane.

9) We bootstrap the kubernetes worker nodes.

10) We configure kubectl on the jumpbox for remote access.

11) We'll provision the pod networking routes.

12) We run some smoke tests like data encryption and port-forwarding an nginx service.

13) We cleanup by just terminating all playgrounds...hashtag delicious!
