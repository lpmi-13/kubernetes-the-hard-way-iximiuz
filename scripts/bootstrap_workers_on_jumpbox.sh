#!/usr/bin/env bash
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519
WORKER_BINARIES=(
  containerd
  containerd-shim-runc-v2
  runc
  kubelet
)

for host in worker-{1..9}; do
  echo "[worker] preparing ${host}"

  ssh -i "${SSH_KEY}" root@${host} "mkdir -p ~/worker"

  for bin in "${WORKER_BINARIES[@]}"; do
    scp -i "${SSH_KEY}" \
      "${HOME}/downloads/worker/${bin}" \
      "root@${host}:~/worker/${bin}"
  done

  scp -i "${SSH_KEY}" -r \
    ~/configs \
    ~/units \
    ~/bootstrap_workers.sh \
    root@${host}:~/

  ssh -i "${SSH_KEY}" root@${host} "bash ~/bootstrap_workers.sh"
done
