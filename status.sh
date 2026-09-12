#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

brief=0
[[ "${1:-}" == "--brief" ]] && brief=1

container_state() {
  local name="$1"
  if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true; then
    printf 'OK'
  else
    printf 'DOWN'
  fi
}

port_state_tcp() {
  if ss -lntH | grep -Eq "[:.]${VLESS_LISTEN_PORT}[[:space:]]"; then
    printf 'LISTEN'
  else
    printf 'CLOSED'
  fi
}

port_state_udp() {
  if ss -lnuH | grep -Eq "[:.]${HY2_LISTEN_PORT}[[:space:]]"; then
    printf 'LISTEN'
  else
    printf 'CLOSED'
  fi
}

printf 'Vless.Hysteria status\n'
printf '  Xray container:      %s\n' "$(container_state vpn-xray)"
printf '  Hysteria2 container: %s\n' "$(container_state vpn-hysteria)"
printf '  TCP/%s:              %s\n' "$VLESS_LISTEN_PORT" "$(port_state_tcp)"
printf '  UDP/%s:              %s\n' "$HY2_LISTEN_PORT" "$(port_state_udp)"

if systemctl is-active --quiet vless-hysteria-watchdog.timer; then
  printf '  Watchdog timer:      OK\n'
else
  printf '  Watchdog timer:      DOWN\n'
fi

printf '  Public VLESS:        %s:%s/TCP\n' "$PUBLIC_HOST" "$PUBLIC_VLESS_PORT"
printf '  Public Hysteria2:    %s:%s/UDP\n' "$PUBLIC_HOST" "$PUBLIC_HY2_PORT"
printf '  Users:               %s\n' "$(jq 'length' "$USERS_FILE")"

if [[ $brief -eq 0 ]]; then
  printf '\nContainers:\n'
  (cd "$VH_HOME" && docker compose ps)
  printf '\nListening sockets:\n'
  ss -lntup | grep -E "(:${VLESS_LISTEN_PORT}[[:space:]]|:${HY2_LISTEN_PORT}[[:space:]])" || true
  printf '\nRecent watchdog entries:\n'
  journalctl -u vless-hysteria-watchdog.service -n 10 --no-pager 2>/dev/null || true
fi
