#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root (sudo).' >&2; exit 1; }

systemctl disable --now vless-hysteria-watchdog.timer 2>/dev/null || true
rm -f /etc/systemd/system/vless-hysteria-watchdog.timer
rm -f /etc/systemd/system/vless-hysteria-watchdog.service
systemctl daemon-reload

if [[ -f "$VH_HOME/compose.yml" ]]; then
  (cd "$VH_HOME" && docker compose down) || true
fi

cat <<EOF
Vless.Hysteria services are stopped and the watchdog is disabled.
Runtime state was intentionally preserved at:
  $VH_HOME

This keeps users, keys, certificates and backups recoverable.
Docker itself was not removed.
EOF
