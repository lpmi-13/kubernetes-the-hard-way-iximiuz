#!/usr/bin/env bash
set -euo pipefail

TARGET_WORKERS="${TARGET_WORKERS:?TARGET_WORKERS must be set}"
SELF_HOSTNAME=$(hostname -s)

for entry in ${TARGET_WORKERS}; do
  name="${entry%%:*}"
  cidr="${entry##*:}"

  if [ "${name}" = "${SELF_HOSTNAME}" ]; then
    continue
  fi

  resolved_ip=$(getent ahostsv4 "${name}" | awk 'NR==1 {print $1}')
  if [ -z "${resolved_ip}" ]; then
    echo "failed to resolve ${name}" >&2
    exit 1
  fi

  route_dev="$(ip -4 route get "${resolved_ip}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [ -n "${route_dev}" ]; then
    if ip route replace "${cidr}" via "${resolved_ip}" dev "${route_dev}" 2>/dev/null; then
      continue
    fi
    # tailscale peers are /32 routes; onlink is required when used as next-hop gateways.
    if [ "${route_dev}" = "tailscale0" ] && ip route replace "${cidr}" via "${resolved_ip}" dev "${route_dev}" onlink 2>/dev/null; then
      continue
    fi
  fi

  if ip route replace "${cidr}" via "${resolved_ip}" 2>/dev/null; then
    continue
  fi

  echo "failed to install route ${cidr} via ${name} (${resolved_ip})" >&2
  exit 1
done
