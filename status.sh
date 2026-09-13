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
  local port="$1"
  if ss -lntH | grep -Eq "[:.]${port}[[:space:]]"; then
    printf 'LISTEN'
  else
    printf 'CLOSED'
  fi
}

port_state_udp() {
  local port="$1"
  if ss -lnuH | grep -Eq "[:.]${port}[[:space:]]"; then
    printf 'LISTEN'
  else
    printf 'CLOSED'
  fi
}

cert_expiry() {
  if [[ -f "$VH_HOME/hysteria/certs/server.crt" ]]; then
    openssl x509 -in "$VH_HOME/hysteria/certs/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2-
  else
    printf 'missing'
  fi
}

printf 'Vless.Hysteria status\n'
printf '  VLESS mode:          %s\n' "$VLESS_MODE"
printf '  Xray container:      %s\n' "$(container_state vpn-xray)"
printf '  Hysteria2 container: %s\n' "$(container_state vpn-hysteria)"
printf '  Web container:       %s\n' "$(container_state vpn-web)"
printf '  TCP/%s:              %s\n' "$VLESS_LISTEN_PORT" "$(port_state_tcp "$VLESS_LISTEN_PORT")"
if [[ "$VLESS_MODE" == "web-xhttp" ]]; then
  printf '  XHTTP backend TCP/%s: %s\n' "$VLESS_XHTTP_BACKEND_PORT" "$(port_state_tcp "$VLESS_XHTTP_BACKEND_PORT")"
fi
printf '  UDP/%s:              %s\n' "$HY2_LISTEN_PORT" "$(port_state_udp "$HY2_LISTEN_PORT")"
printf '  Web local TCP/%s:    %s\n' "$WEB_LOCAL_PORT" "$(port_state_tcp "$WEB_LOCAL_PORT")"

if systemctl is-active --quiet vless-hysteria-watchdog.timer; then
  printf '  Watchdog timer:      OK\n'
else
  printf '  Watchdog timer:      DOWN\n'
fi

printf '  TLS certificate:     %s\n' "$TLS_CERT_MODE"
printf '  TLS expires:         %s\n' "$(cert_expiry)"
if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
  if systemctl is-active --quiet vless-hysteria-cert-renew.timer; then
    printf '  Cert renew timer:    OK\n'
  else
    printf '  Cert renew timer:    DOWN\n'
  fi
fi

printf '  Public VLESS:        %s:%s/TCP\n' "$PUBLIC_HOST" "$PUBLIC_VLESS_PORT"
printf '  Public Hysteria2:    %s:%s/UDP\n' "$PUBLIC_HOST" "$PUBLIC_HY2_PORT"
printf '  Hysteria2 SNI:       %s\n' "$HY2_SNI"
if [[ "$VLESS_MODE" == "web-xhttp" ]]; then
  printf '  Website SNI:         %s\n' "$WEB_DOMAIN"
  printf '  XHTTP mode:          stream-up / H2\n'
  printf '  XHTTP path:          %s\n' "$VLESS_XHTTP_PATH"
else
  printf '  REALITY SNI:         %s\n' "$REALITY_SNI"
fi
printf '  Users:               %s\n' "$(jq 'length' "$USERS_FILE")"

if [[ $brief -eq 0 ]]; then
  printf '\nContainers:\n'
  (cd "$VH_HOME" && docker compose ps)
  printf '\nListening sockets:\n'
  ss -lntup | grep -E "(:${VLESS_LISTEN_PORT}[[:space:]]|:${VLESS_XHTTP_BACKEND_PORT}[[:space:]]|:${WEB_LOCAL_PORT}[[:space:]]|:${HY2_LISTEN_PORT}[[:space:]])" || true
  printf '\nRecent watchdog entries:\n'
  journalctl -u vless-hysteria-watchdog.service -n 10 --no-pager 2>/dev/null || true
  if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
    printf '\nRecent certificate renewal entries:\n'
    journalctl -u vless-hysteria-cert-renew.service -n 10 --no-pager 2>/dev/null || true
  fi
fi
