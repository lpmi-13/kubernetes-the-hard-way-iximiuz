#!/usr/bin/env bash
set -euo pipefail

SOURCE_SCRIPT="${HOME}/cordon_workers_with_broken_dns_on_jumpbox.sh"
INSTALLED_SCRIPT="/usr/local/bin/worker-dns-healer.sh"
SERVICE_FILE="/etc/systemd/system/worker-dns-healer.service"
TIMER_FILE="/etc/systemd/system/worker-dns-healer.timer"

if [ ! -f "${SOURCE_SCRIPT}" ]; then
  echo "[healer] missing ${SOURCE_SCRIPT}" >&2
  exit 1
fi

echo "[healer] installing worker DNS healer script"
install -m 0755 "${SOURCE_SCRIPT}" "${INSTALLED_SCRIPT}"

echo "[healer] writing systemd service"
cat >"${SERVICE_FILE}" <<'EOF'
[Unit]
Description=Heal worker pod DNS and networking failures
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=KUBECONFIG=/root/.kube/config
Environment=MIN_HEALTHY_WORKERS=3
Environment=AUTO_UNCORDON_HEALTHY_CHECKS=3
ExecStart=/bin/bash /usr/local/bin/worker-dns-healer.sh
EOF

echo "[healer] writing systemd timer"
cat >"${TIMER_FILE}" <<'EOF'
[Unit]
Description=Periodically run the worker DNS healer

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
RandomizedDelaySec=30s
Persistent=true
Unit=worker-dns-healer.service

[Install]
WantedBy=timers.target
EOF

echo "[healer] enabling timer"
systemctl daemon-reload
systemctl enable --now worker-dns-healer.timer

echo "[healer] running an immediate healing pass"
systemctl start worker-dns-healer.service

echo "[healer] current timer status"
systemctl --no-pager --full status worker-dns-healer.timer || true
