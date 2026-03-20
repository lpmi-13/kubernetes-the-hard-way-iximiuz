# Configuring kubectl for Remote Access

In this lab you will generate a kubeconfig for the `kubectl` command line utility on the jumpbox. The jumpbox should access the API server via the HAProxy endpoint at `server.kubernetes.local:6443`.

## The Admin Kubernetes Configuration File

Run the following commands on the jumpbox:

```sh
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server=https://server.kubernetes.local:6443 \
  --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=admin.crt \
  --client-key=admin.key \
  --embed-certs=true \
  --kubeconfig=admin.kubeconfig

kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin \
  --kubeconfig=admin.kubeconfig

kubectl config use-context kubernetes-the-hard-way --kubeconfig=admin.kubeconfig

mkdir -p ~/.kube
cp admin.kubeconfig ~/.kube/config
```

## Verification

Check the readiness of the remote cluster:

```sh
kubectl get --raw='/readyz?verbose'
```

List the nodes:

```sh
kubectl get nodes
```

you should see output like this

```sh
NAME       STATUS   ROLES    AGE     VERSION
worker-1   Ready    <none>   12m     v1.34.5
worker-2   Ready    <none>   10m     v1.34.5
worker-3   Ready    <none>   8m14s   v1.34.5
worker-4   Ready    <none>   7m44s   v1.34.5
worker-5   Ready    <none>   7m13s   v1.34.5
```

Next: [Deploying Cilium and Hubble](11-cilium-hubble.md)
