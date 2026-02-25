#!/usr/bin/env bash
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519

for host in controller-{1..3}; do
  echo "[controller] preparing ${host}"

  scp -i "${SSH_KEY}" \
    ~/downloads/controller/* \
    ~/downloads/client/kubectl \
    ~/units/kube-apiserver.service \
    ~/units/kube-controller-manager.service \
    ~/units/kube-scheduler.service \
    ~/configs/kube-scheduler.yaml \
    root@${host}:~/

  ssh -i "${SSH_KEY}" root@${host} "bash -s" <<'REMOTE'
set -euo pipefail

mkdir -p /etc/kubernetes/config /var/lib/kubernetes

chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/

cp ca.crt ca.key \
  kube-api-server.crt kube-api-server.key \
  service-accounts.crt service-accounts.key \
  encryption-config.yaml /var/lib/kubernetes/

cp kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig /var/lib/kubernetes/

cp kube-scheduler.yaml /etc/kubernetes/config/kube-scheduler.yaml

sed -i "s|ADVERTISE_ADDRESS|$(tailscale ip -4)|g" kube-apiserver.service
mv kube-apiserver.service kube-controller-manager.service kube-scheduler.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl start kube-apiserver kube-controller-manager kube-scheduler
REMOTE

done
