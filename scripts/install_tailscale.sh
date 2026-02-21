#!/usr/bin/env sh
set -eu

if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  echo "TAILSCALE_AUTH_KEY must be set"
  exit 1
fi

if [ -z "${TAILSCALE_HOSTNAME:-}" ]; then
  TAILSCALE_HOSTNAME="$(hostname)"
fi

if [ -z "${TAILSCALE_TAGS:-}" ]; then
  TAILSCALE_TAGS="tag:kthw"
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

$SUDO systemctl enable --now tailscaled
$SUDO tailscale up \
  --auth-key="$TAILSCALE_AUTH_KEY" \
  --hostname="$TAILSCALE_HOSTNAME" \
  --advertise-tags="$TAILSCALE_TAGS"
$SUDO tailscale status >/dev/null
