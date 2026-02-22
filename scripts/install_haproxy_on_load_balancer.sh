#!/usr/bin/env bash
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519

scp -i "${SSH_KEY}" ~/install_haproxy.sh root@load-balancer:~/install_haproxy.sh
ssh -i "${SSH_KEY}" root@load-balancer "bash ~/install_haproxy.sh"
