#!/usr/bin/env bash
set -euo pipefail

API_SERVER_IP="${API_SERVER_IP:?API_SERVER_IP must be set}"
API_SERVER_HOST="${API_SERVER_HOST:-server.kubernetes.local}"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

${SUDO} sed -i "/[[:space:]]${API_SERVER_HOST}$/d" /etc/hosts
printf '%s %s\n' "${API_SERVER_IP}" "${API_SERVER_HOST}" | ${SUDO} tee -a /etc/hosts >/dev/null
