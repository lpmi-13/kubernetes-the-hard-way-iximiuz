#!/usr/bin/env bash
set -euo pipefail

rm -rf downloads
mkdir -p downloads

wget --show-progress \
  --https-only \
  --tries=3 \
  -P downloads \
  -i downloads.txt

ARCH=$(dpkg --print-architecture)
mkdir -p downloads/{client,controller,worker}

tar -xvf downloads/crictl-v1.32.0-linux-${ARCH}.tar.gz \
  -C downloads/worker/
tar -xvf downloads/containerd-2.1.0-beta.0-linux-${ARCH}.tar.gz \
  --strip-components 1 \
  -C downloads/worker/
tar -xvf downloads/etcd-v3.6.0-rc.3-linux-${ARCH}.tar.gz \
  -C downloads/ \
  --strip-components 1 \
  etcd-v3.6.0-rc.3-linux-${ARCH}/etcdctl \
  etcd-v3.6.0-rc.3-linux-${ARCH}/etcd
mv downloads/{etcdctl,kubectl} downloads/client/
mv downloads/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler} \
  downloads/controller/
mv downloads/kubelet downloads/worker/
mv downloads/runc.${ARCH} downloads/worker/runc


rm -rf downloads/*gz

chmod +x downloads/{client,controller,worker}/*

sudo cp downloads/client/kubectl /usr/local/bin/

kubectl version --client
