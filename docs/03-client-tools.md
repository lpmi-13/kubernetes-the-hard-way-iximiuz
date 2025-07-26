# Client Tools

We need to install all the relevant binaries to your jumpbox (you _could_ install all this locally, but it's just as easy to download them to an ephemeral remote workstation, and saves the need to clean up later).

## Setting up the jumpbox server

First, we need to get the ID of the playground that has the jumpbox.

```sh
JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')
```

and then we need to copy over the file with the installation URLs.

```sh
labctl cp ./downloads.txt $JUMPBOX_PLAYGROUND_ID:~/downloads.txt
```

and now we're ready to jump on there and install some tools.

```sh
labctl ssh $JUMPBOX_PLAYGROUND_ID
```

your terminal should know look like this:

```sh
laborant@jumpbox:~$
```

Let's download all the tools first

```sh
wget -q --show-progress \
  --https-only \
  --timestamping \
  -P downloads \
  -i downloads.txt
```

and now we can expand the tar files and move the binaries

```sh
ARCH=$(dpkg --print-architecture)
mkdir -p downloads/{client,cni-plugins,controller,worker}
tar -xvf downloads/crictl-v1.32.0-linux-${ARCH}.tar.gz \
  -C downloads/worker/
tar -xvf downloads/containerd-2.1.0-beta.0-linux-${ARCH}.tar.gz \
  --strip-components 1 \
  -C downloads/worker/
tar -xvf downloads/cni-plugins-linux-${ARCH}-v1.6.2.tgz \
  -C downloads/cni-plugins/
tar -xvf downloads/etcd-v3.6.0-rc.3-linux-${ARCH}.tar.gz \
  -C downloads/ \
  --strip-components 1 \
  etcd-v3.6.0-rc.3-linux-${ARCH}/etcdctl \
  etcd-v3.6.0-rc.3-linux-${ARCH}/etcd
mv downloads/{etcdctl,kubectl} downloads/client/
mv downloads/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler} \
  downloads/controller/
mv downloads/{kubelet,kube-proxy} downloads/worker/
mv downloads/runc.${ARCH} downloads/worker/runc
```

and remove the archives

```sh
rm -rf downloads/*gz
```

and then we need to make the binaries executable

```sh
chmod +x downloads/{client,cni-plugins,controller,worker}/*
```

## Install Kubectl

We need the `kubectl` binary to be available to run on the jumpbox, so let's move it into the `$PATH`.

```sh
sudo cp downloads/client/kubectl /usr/local/bin/
```

You'll now be able to run the `kubectl` command and see the version info:

```sh
kubectl version --client
```
```sh
Client Version: v1.32.3
Kustomize Version: v5.5.0
```

Your jumpbox is now set up and ready to run the rest of the commands.
