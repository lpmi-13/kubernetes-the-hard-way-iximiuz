#!/usr/bin/env bash
set -euo pipefail

SSH_KEY=~/.ssh/kubernetes.ed25519
KUBE_APISERVER_UNIT_TEMPLATE="${HOME}/kube-apiserver.service"
CA_CONFIG="${HOME}/ca.conf"

ensure_front_proxy_ca() {
  if [ -s "${HOME}/front-proxy-ca.key" ] && [ -s "${HOME}/front-proxy-ca.crt" ]; then
    return 0
  fi

  echo "[aggregation] generating front-proxy CA"
  openssl genrsa -out "${HOME}/front-proxy-ca.key" 4096
  openssl req -x509 -new -sha512 -noenc \
    -key "${HOME}/front-proxy-ca.key" \
    -days 3653 \
    -subj "/C=US/ST=Washington/L=Seattle/CN=front-proxy-ca" \
    -out "${HOME}/front-proxy-ca.crt"
}

front_proxy_client_is_valid() {
  if [ ! -s "${HOME}/front-proxy-client.key" ] || [ ! -s "${HOME}/front-proxy-client.crt" ]; then
    return 1
  fi

  openssl verify -CAfile "${HOME}/front-proxy-ca.crt" "${HOME}/front-proxy-client.crt" >/dev/null 2>&1 &&
    openssl x509 -in "${HOME}/front-proxy-client.crt" -noout -subject \
      | grep -q 'CN = front-proxy-client'
}

ensure_front_proxy_client() {
  if front_proxy_client_is_valid; then
    return 0
  fi

  if [ ! -s "${HOME}/front-proxy-ca.key" ] || [ ! -s "${HOME}/front-proxy-ca.crt" ]; then
    echo "front-proxy CA files are missing" >&2
    exit 1
  fi

  if [ ! -s "${CA_CONFIG}" ]; then
    echo "missing ${CA_CONFIG}" >&2
    exit 1
  fi

  echo "[aggregation] generating front-proxy client certificate"
  rm -f \
    "${HOME}/front-proxy-client.key" \
    "${HOME}/front-proxy-client.crt" \
    "${HOME}/front-proxy-client.csr"
  openssl genrsa -out "${HOME}/front-proxy-client.key" 4096
  openssl req -new -key "${HOME}/front-proxy-client.key" -sha256 \
    -config "${CA_CONFIG}" -section front-proxy-client \
    -out "${HOME}/front-proxy-client.csr"
  openssl x509 -req -days 3653 \
    -in "${HOME}/front-proxy-client.csr" \
    -sha256 \
    -CA "${HOME}/front-proxy-ca.crt" \
    -CAkey "${HOME}/front-proxy-ca.key" \
    -CAcreateserial \
    -copy_extensions copyall \
    -out "${HOME}/front-proxy-client.crt"
  rm -f "${HOME}/front-proxy-client.csr"
}

controller_is_configured() {
  local host="$1"

  ssh -i "${SSH_KEY}" root@"${host}" '
    set -euo pipefail
    grep -q -- "--enable-aggregator-routing=true" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--proxy-client-cert-file=/var/lib/kubernetes/front-proxy-client.crt" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--proxy-client-key-file=/var/lib/kubernetes/front-proxy-client.key" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--requestheader-client-ca-file=/var/lib/kubernetes/front-proxy-ca.crt" /etc/systemd/system/kube-apiserver.service &&
    grep -q -- "--requestheader-allowed-names=front-proxy-client" /etc/systemd/system/kube-apiserver.service &&
    [ -s /var/lib/kubernetes/front-proxy-ca.crt ] &&
    [ -s /var/lib/kubernetes/front-proxy-client.crt ] &&
    [ -s /var/lib/kubernetes/front-proxy-client.key ] &&
    openssl verify -CAfile /var/lib/kubernetes/front-proxy-ca.crt /var/lib/kubernetes/front-proxy-client.crt >/dev/null 2>&1 &&
    openssl x509 -in /var/lib/kubernetes/front-proxy-client.crt -noout -subject | grep -q "CN = front-proxy-client"
  ' >/dev/null 2>&1
}

configure_controller() {
  local host="$1"
  local advertise_address
  local rendered_unit

  if controller_is_configured "${host}"; then
    echo "[aggregation] ${host} already configured"
    return 0
  fi

  if [ ! -s "${KUBE_APISERVER_UNIT_TEMPLATE}" ]; then
    echo "missing ${KUBE_APISERVER_UNIT_TEMPLATE}" >&2
    exit 1
  fi

  echo "[aggregation] updating ${host}"
  advertise_address="$(
    ssh -i "${SSH_KEY}" root@"${host}" "tailscale ip -4" | tr -d '\n\r'
  )"

  rendered_unit="$(mktemp)"
  sed "s|ADVERTISE_ADDRESS|${advertise_address}|g" "${KUBE_APISERVER_UNIT_TEMPLATE}" > "${rendered_unit}"

  scp -i "${SSH_KEY}" \
    "${rendered_unit}" \
    root@"${host}":/tmp/kube-apiserver.service
  scp -i "${SSH_KEY}" \
    "${HOME}/front-proxy-ca.crt" \
    "${HOME}/front-proxy-client.crt" \
    "${HOME}/front-proxy-client.key" \
    root@"${host}":~/
  rm -f "${rendered_unit}"

  ssh -i "${SSH_KEY}" root@"${host}" 'bash -s' <<'REMOTE'
set -euo pipefail

cp front-proxy-ca.crt front-proxy-client.crt front-proxy-client.key /var/lib/kubernetes/
mv /tmp/kube-apiserver.service /etc/systemd/system/kube-apiserver.service

systemctl daemon-reload
systemctl restart kube-apiserver

until systemctl is-active --quiet kube-apiserver; do
  sleep 2
done
REMOTE
}

wait_for_cluster_api() {
  echo "[aggregation] waiting for HA API endpoint"
  for _ in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "cluster API did not become ready after aggregation-layer update" >&2
  exit 1
}

ensure_front_proxy_ca
ensure_front_proxy_client

for host in controller-{1..3}; do
  configure_controller "${host}"
done

wait_for_cluster_api
echo "[aggregation] aggregation layer is configured"
