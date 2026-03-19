# Kubernetes multi-cluster cluster

This is heavily based on the Excellent [kubernetes the hard way](https://github.com/kelseyhightower/kubernetes-the-hard-way) by Kelsey Hightower.

This is the working title of creating a mega-cluster on Iximiuz Labs via tailscale tailnet.

The idea is that in the original k8s-the-hard-way, we had 3 control plan nodes and 3 worker nodes, but now we're going to have one cluster of control plane nodes (3) and three clusters of worker nodes (3 x 3)...all networked via tailscale.

> this got downscoped from 3 clusters of 3 worker nodes to just 1 cluster of 5 worker nodes. you can read about that journey [here](https://dev.to/lpmi13/an-iximiuz-cluster-of-clusters-with-tailscale-and-cilium-43d4)

We'll also have one admin node in a standalone ubuntu playground to act as the jumpbox (a concept that Kelsey Hightower introduced in the later K8s the hard way walkthroughs to simplify the setup a bit, so I copied it here as well). This is the machine that we'll use to actually provision the k8s megacluster, and since it's also an ephemeral VM, there's no clean up to be done, just shut it down!


## Cluster Details

Kubernetes The Hard Way guides you through bootstrapping a basic Kubernetes cluster with all control plane components running on a single node, and two worker nodes, which is enough to learn the core concepts.

Component versions:

* [kubernetes](https://github.com/kubernetes/kubernetes) v1.32.x
* [containerd](https://github.com/containerd/containerd) v2.1.x
* [cilium](https://github.com/cilium/cilium) v1.16.x
* [etcd](https://github.com/etcd-io/etcd) v3.6.x

## Action sequence

Because we're interacting with the VMs slightly differently from a regular cloud provider, and the configuration is a bit custom, we need to do things a bit different from the regular tutorial.

1) We create all the clusters. For now, we'll do 4 flexbox playgrounds that each have 3 machines (1 controller cluster and three worker node clusters), and one standalone flexbox playground (that only has one machine in it) as the jumpbox server.

2) We install all the necessary tooling in the jumpbox.

> We do this here so we can just install the tooling once and copy it over to all the other servers. Also so we don't need to clutter your local workstation with anything!

3) We configure the networking. This is using tailscale and is going to be conceptually very simple, but we just need to track all the DNS names for each of the hosts. Maybe a scheme like:

- jumpbox
- controller-{1..3}
- load-balancer (this will be in the same subnet as the controller instances)
- worker-{1..3}
- worker-{4..6}
- worker-{7..9}

We also set the hostnames as above, so we can install/start tailscale on each node and they'll be able to contact each other using just the hostname as the DNS name (magic!).

4) We set up the PKI certificate authority and distribute certs/keys/etc to each of the machines.

5) We generate the kubernetes config files for the worker nodes.

6) We generate and distribute the data encryption keys.

7) We bootstrap an etcd server (we might want to do this with an etcd cluster...not sure yet)

8) We bootstrap the kubernetes control plane and configure HAProxy on the load-balancer. HAProxy is the canonical entrypoint for jumpbox traffic and future external access, distributing API requests across controller nodes.

9) We bootstrap the kubernetes worker nodes (containerd + kubelet only — no CNI or kube-proxy, Cilium handles both).

10) We configure kubectl on the jumpbox for remote access via `server.kubernetes.local:6443` (the HAProxy endpoint).

11) We deploy Cilium (eBPF-based CNI + kube-proxy replacement) and Hubble (network observability) across all workers. Cilium uses VXLAN overlay tunnels that traverse Tailscale's WireGuard tunnels transparently, replacing the manual pod routes and iptables-based kube-proxy.

12) We deploy CoreDNS and verify in-cluster name resolution.

13) We install KEDA, deploy the Bookinfo sample application with wave-based traffic generation plus a Redis-backed worker queue, and run the full smoke test suite: data encryption at rest, deployments, port-forwarding, logs, exec, NodePort, DNS resolution, Cilium/Hubble health, Bookinfo connectivity, and visible KEDA-driven worker scale-out and scale-in.

14) Optional add-on: deploy [hubble-gazer](https://github.com/lpmi-13/hubble-gazer) `0.3.0` to consume Hubble Relay flow data and visualize live traffic in a browser tab via exposed ports.

15) We cleanup with `bash clean-up.sh`, which removes stale Tailscale devices and then terminates all playgrounds.
