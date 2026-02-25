#!/usr/bin/env bash
set -euo pipefail

kubectl apply --kubeconfig /root/admin.kubeconfig -f /root/kube-api-server-to-kubelet.yaml
