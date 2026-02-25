# Provisioning Pod Network Routes

Pods scheduled to a node receive an IP address from that node's Pod CIDR range. At this point, pods cannot reach pods on other nodes until the route table contains entries for each worker's Pod CIDR.

In this lab you will add routes so every worker can reach every other worker's pod subnet. We resolve worker hostnames to IPv4 addresses first and install routes using those addresses. For Tailscale `/32` peers we add routes with `dev tailscale0 onlink`.

## Configure Routes

Run the following on the jumpbox to install routes on all workers:

```sh
TARGET_WORKERS=""
for i in {1..9}; do
  TARGET_WORKERS+="worker-${i}:10.200.${i}.0/24 "
done

for host in worker-{1..9}; do
  ssh -i ~/.ssh/kubernetes.ed25519 root@${host} "TARGET_WORKERS='${TARGET_WORKERS}' bash -s" <<'ROUTES'
set -euo pipefail
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

  route_dev=$(ip -4 route get "${resolved_ip}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "${route_dev}" ]; then
    if ip route replace "${cidr}" via "${resolved_ip}" dev "${route_dev}" 2>/dev/null; then
      continue
    fi
    if [ "${route_dev}" = "tailscale0" ] && ip route replace "${cidr}" via "${resolved_ip}" dev "${route_dev}" onlink 2>/dev/null; then
      continue
    fi
  fi

  ip route replace "${cidr}" via "${resolved_ip}"
done

ip route show | grep 10.200.
ROUTES
done
```

## Example (Single Worker)

If you want to do it manually on a single worker (for example `worker-1`):

```sh
ssh -i ~/.ssh/kubernetes.ed25519 root@worker-1

ip route replace 10.200.2.0/24 via "$(getent ahostsv4 worker-2 | awk 'NR==1 {print $1}')"
ip route replace 10.200.3.0/24 via "$(getent ahostsv4 worker-3 | awk 'NR==1 {print $1}')"
ip route replace 10.200.4.0/24 via "$(getent ahostsv4 worker-4 | awk 'NR==1 {print $1}')"
# ...continue for all other workers
```

Next: [Deploying the DNS Cluster Add-on](12-dns-addon.md)
