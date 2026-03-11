# Smoke Test And KEDA Demo

In this lab you deploy the Bookinfo sample application, install the autoscaling add-on needed for the demo, and run an expanded smoke test suite against the cluster.

Step 13 now verifies three things together:

1. Core Kubernetes workflows still work: secrets, deployments, logs, exec, port-forwarding, NodePort, and DNS.
2. Bookinfo remains reachable under wave-based traffic.
3. Backend queue workers scale with KEDA based on Redis queue depth.

## Autoscaling Components

The demo installs and verifies:

1. `keda` in the `keda` namespace for queue-depth autoscaling.
2. Bookinfo Deployments in the `demo` namespace with:
   - explicit CPU and memory requests
   - topology spread constraints
3. Redis plus `demo-worker` in the `demo` namespace.
4. A traffic-generator Deployment that:
   - sends wave-based HTTP traffic to `productpage`
   - pushes randomized burst/cooldown waves of work items directly into Redis

The async demo intentionally avoids custom application images. Queue publishing is handled by the traffic generator, and the workers use a stock image with inline script logic to consume Redis jobs and spend bounded CPU on each message. The scale signal comes from queue depth, not kubelet CPU metrics.

## Run The Demo

From your local machine, execute:

```sh
bash scripts/13.sh
```

That script copies the manifests and helper scripts to the jumpbox, then runs:

1. `enable_aggregation_layer_on_jumpbox.sh`
2. `install_keda_on_jumpbox.sh`
3. `deploy_bookinfo_on_jumpbox.sh`
4. `smoke_test_on_jumpbox.sh`

## What The Smoke Test Checks

The smoke test still covers the classic cluster checks:

1. data encryption at rest
2. a basic nginx deployment
3. port-forwarding
4. logs and `kubectl exec`
5. NodePort access
6. DNS resolution from a pod
7. Cilium and Hubble health

It then adds autoscaling verification:

1. `kubectl get scaledobject -n demo` shows `demo-worker` as `Ready`.
2. `demo-worker` scales above zero as queue bursts build up.
3. `demo-worker` later scales back down during idle cooldown windows.
4. Demo pods spread across multiple worker nodes.

## Useful Manual Commands

If you want to watch the demo live from the jumpbox:

```sh
kubectl -n demo get deploy demo-worker -w
```

```sh
kubectl -n demo get scaledobject -w
```

```sh
kubectl -n demo get hpa
```

```sh
kubectl -n demo exec deploy/redis -- redis-cli LLEN demo-jobs
```

```sh
kubectl -n demo get pods -o wide
```

If you also deployed the visualizer in step 14, Hubble-gazer should show the Bookinfo traffic waves and the Redis/worker activity changing as KEDA reacts to queue bursts and cooldowns.

Next: [Optional: Hubble Gazer Visualizer](14-hubble-gazer-visualizer.md)
