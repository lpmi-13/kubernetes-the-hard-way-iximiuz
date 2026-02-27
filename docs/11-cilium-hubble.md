# Deploying Cilium and Hubble

In this section you will deploy [Cilium](https://cilium.io/) as the Container Network Interface (CNI) plugin and [Hubble](https://docs.cilium.io/en/stable/overview/intro/#what-is-hubble) for network observability. Cilium replaces the bridge CNI and kube-proxy that are traditionally used in Kubernetes-the-hard-way, providing eBPF-based networking, load balancing, and network policy enforcement.

## Why Cilium?

The original Kubernetes the Hard Way tutorial uses a bridge CNI with manual static routes between workers, plus kube-proxy in iptables mode for service load balancing. This works, but:

- **Manual routes don't scale** — every new worker requires route updates on all other workers
- **iptables-based kube-proxy** adds latency and is hard to debug
- **No observability** — you can't see what traffic is flowing between pods

Cilium solves all three:

1. **VXLAN overlay** — pods on different workers communicate via VXLAN tunnels, no manual routes needed
2. **eBPF kube-proxy replacement** — service load balancing happens in the kernel via eBPF programs, bypassing iptables entirely
3. **Hubble** — provides flow-level visibility into all network traffic using eBPF

## VXLAN over Tailscale

This mega-cluster uses Tailscale to connect workers across multiple playgrounds. Cilium's VXLAN encapsulation works transparently over Tailscale:

- Cilium wraps pod-to-pod traffic in UDP packets (VXLAN, port 8472)
- The outer IP headers use the workers' Tailscale IPs
- These UDP packets traverse Tailscale's WireGuard tunnels like any other traffic
- No Tailscale configuration changes are needed

### The `--node-ip` requirement

For this to work, each kubelet must be started with `--node-ip` set to the worker's **Tailscale IP** (e.g., `100.x.x.x`). This is done in step 9.

Cilium uses each node's Kubernetes `InternalIP` as the source and destination address for VXLAN tunnel packets. Without `--node-ip`, kubelet auto-detects the `eth0` LAN address (`172.16.x.x`), which is only reachable within the same playground. Workers in different playgrounds would have unreachable VXLAN tunnel endpoints, and cross-playground pod traffic would silently black-hole.

By setting `--node-ip` to the Tailscale address, the Kubernetes node object advertises an IP that is routable across all playgrounds (via Tailscale's WireGuard mesh), and Cilium's VXLAN tunnels just work.

## Prerequisites

- All worker nodes running with containerd and kubelet (no CNI or kube-proxy)
- kubectl configured on the jumpbox
- Helm and Cilium CLI installed on the jumpbox

## Install Cilium CLI and Helm

```bash
bash ~/install_cilium_tools_on_jumpbox.sh
```

This installs:
- **Cilium CLI** (v0.19.2) — for checking Cilium status and connectivity
- **Helm** (v3.17.0) — for rendering Cilium's Kubernetes manifests

## Deploy Cilium

```bash
bash ~/deploy_cilium_on_jumpbox.sh
```

This uses `helm template` to render Cilium manifests with these key settings, then applies them with `kubectl apply`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `kubeProxyReplacement` | `true` | Cilium replaces kube-proxy entirely |
| `tunnel` | `vxlan` | Use VXLAN overlay for pod-to-pod traffic |
| `k8sServiceHost` | `server.kubernetes.local` | API server endpoint (HAProxy) |
| `k8sServicePort` | `6443` | API server port |
| `hubble.enabled` | `true` | Enable Hubble flow observability |
| `hubble.relay.enabled` | `true` | Deploy Hubble Relay for centralized flow access |
| `hubble.ui.enabled` | `true` | Deploy Hubble UI |
| `operator.replicas` | `1` | Single Cilium operator replica |
| `ipam.mode` | `kubernetes` | Use Kubernetes-native IPAM |
| `ipam.operator.clusterPoolIPv4PodCIDRList` | `10.200.0.0/16` | Pod CIDR range |
| `ipam.operator.clusterPoolIPv4MaskSize` | `24` | Per-node pod CIDR size |

## Verification

After deployment, verify that Cilium is healthy:

```bash
cilium status
```

All 9 Cilium agents should be reporting as healthy, and Hubble Relay should be connected.

Test cross-worker pod connectivity:

```bash
cilium connectivity test
```

Check that Hubble is observing flows:

```bash
kubectl -n kube-system exec -i ds/cilium -- hubble observe --last 10
```

## Architecture

```
                    ┌─────────────────┐
                    │   Hubble UI     │
                    │  (kube-system)  │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Hubble Relay   │ ◄── gRPC :4245
                    │  (kube-system)  │
                    └────────┬────────┘
                             │ aggregates from all agents
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼───┐  ┌──────▼─────┐  ┌─────▼──────┐
     │  Cilium    │  │  Cilium    │  │  Cilium    │  ... (9 agents)
     │  Agent     │  │  Agent     │  │  Agent     │
     │ (worker-1) │  │ (worker-2) │  │ (worker-3) │
     └────────────┘  └────────────┘  └────────────┘
         │ eBPF          │ eBPF          │ eBPF
     ┌───▼────┐      ┌───▼────┐      ┌───▼────┐
     │  Pods  │      │  Pods  │      │  Pods  │
     └────────┘      └────────┘      └────────┘
```

Each Cilium agent runs as a DaemonSet pod on every worker. It:
1. Attaches eBPF programs to network interfaces to capture and process all traffic
2. Handles pod-to-pod routing via VXLAN tunnels
3. Implements kube-proxy functionality (service ClusterIP/NodePort) in eBPF
4. Reports flow data to Hubble Relay via gRPC

Hubble Relay aggregates flow data from all agents and exposes a single gRPC endpoint that clients (Hubble UI, CLI, or custom tools) can connect to.
