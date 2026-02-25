#!/usr/bin/env bash
set -euo pipefail

[ -f ./etcd.service ] || { echo "missing etcd.service in home directory" >&2; exit 1; }
grep -q '^\[Unit\]$' ./etcd.service || { echo "invalid etcd.service on controller: missing [Unit] section" >&2; exit 1; }

systemctl stop etcd >/dev/null 2>&1 || true

mv etcd etcdctl /usr/local/bin/

mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd
rm -rf /var/lib/etcd/*
cp ca.crt kube-api-server.key kube-api-server.crt \
  /etc/etcd/

sudo sed -i "s/NODE_NAME/$(hostname -s)/g" etcd.service
sudo sed -i "s/NODE_IP/$(tailscale ip -4)/g" etcd.service

mv etcd.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable etcd
# etcd with Type=notify may block until peers are reachable. Start non-blocking here
# and let the orchestration script verify cluster health once all controllers are configured.
systemctl reset-failed etcd >/dev/null 2>&1 || true
systemctl restart etcd --no-block

echo "etcd startup triggered on $(hostname -s); cluster verification happens after all controllers are configured."
