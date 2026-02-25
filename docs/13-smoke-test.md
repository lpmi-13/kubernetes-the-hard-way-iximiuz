# Smoke Test

In this lab you will complete a series of tasks to ensure your Kubernetes cluster is functioning correctly.

## Data Encryption

Create a generic secret:

```sh
kubectl create secret generic kubernetes-the-hard-way --from-literal="mykey=mydata"
```

Retrieve the raw secret from etcd (run this on controller-1):

```sh
ssh -i ~/.ssh/kubernetes.ed25519 root@controller-1

etcdctl --endpoints=http://127.0.0.1:2379 \
  get /registry/secrets/default/kubernetes-the-hard-way | hexdump -C
```

The output should include the `k8s:enc:aescbc:v1:key1` prefix, which indicates the data is encrypted at rest.

## Deployments

Create a deployment for nginx:

```sh
kubectl create deployment nginx --image=nginx
```

List the pod created by the deployment:

```sh
kubectl get pods -l app=nginx
```

## Port Forwarding

Retrieve the name of the nginx pod:

```sh
POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
```

Forward port `8080` on the jumpbox to port `80` in the pod:

```sh
kubectl port-forward ${POD_NAME} 8080:80
```

In another terminal, verify the response:

```sh
curl --head http://127.0.0.1:8080
```

Stop the port-forwarding session when done.

## Logs

Print the nginx pod logs:

```sh
kubectl logs ${POD_NAME}
```

## Exec

Execute a command in the container:

```sh
kubectl exec -ti ${POD_NAME} -- nginx -v
```

## Services

Expose the nginx deployment with a NodePort:

```sh
kubectl expose deployment nginx --port 80 --type NodePort
```

Find the node port and the node hosting the nginx pod:

```sh
NODE_PORT=$(kubectl get svc nginx --output=jsonpath='{range .spec.ports[0]}{.nodePort}')
NODE_NAME=$(kubectl get pod ${POD_NAME} --output=jsonpath='{.spec.nodeName}')
```

Make an HTTP request through the worker hostname and node port:

```sh
curl -I http://${NODE_NAME}:${NODE_PORT}
```

## DNS Resolution

Re-run the DNS lookup from the busybox pod:

```sh
kubectl exec -it busybox -- nslookup kubernetes.default.svc.cluster.local
```

Next: [Cleanup](14-cleanup.md)
