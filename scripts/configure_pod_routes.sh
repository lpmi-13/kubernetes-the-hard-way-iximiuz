#!/usr/bin/env bash
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519

TARGET_WORKERS=""
for i in {1..9}; do
  TARGET_WORKERS+="worker-${i}:10.200.${i}.0/24 "
done

for host in worker-{1..9}; do
  echo "[routes] ${host}"

  scp -i "${SSH_KEY}" ~/route_worker.sh root@${host}:~/route_worker.sh
  ssh -i "${SSH_KEY}" root@${host} "TARGET_WORKERS='${TARGET_WORKERS}' bash ~/route_worker.sh"
  ssh -i "${SSH_KEY}" root@${host} "ip route show | grep 10.200."
done
