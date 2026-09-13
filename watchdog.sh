#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

cd "$VH_HOME"

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}

tcp_listening() {
  local port="$1"
  ss -lntH | grep -Eq "[:.]${port}[[:space:]]"
}

udp_listening() {
  local port="$1"
  ss -lnuH | grep -Eq "[:.]${port}[[:space:]]"
}

if ! container_running vpn-xray; then
  logger -t vless-hysteria-watchdog 'vpn-xray is not running; starting it'
  docker compose up -d xray
elif [[ "$VLESS_MODE" == "reality" ]] && ! tcp_listening "$VLESS_LISTEN_PORT"; then
  logger -t vless-hysteria-watchdog "TCP/$VLESS_LISTEN_PORT is not listening for REALITY; restarting vpn-xray"
  docker restart vpn-xray >/dev/null
elif [[ "$VLESS_MODE" == "web-xhttp" ]] && ! tcp_listening "$VLESS_XHTTP_BACKEND_PORT"; then
  logger -t vless-hysteria-watchdog "XHTTP backend TCP/$VLESS_XHTTP_BACKEND_PORT is not listening; restarting vpn-xray"
  docker restart vpn-xray >/dev/null
fi

if ! container_running vpn-web; then
  logger -t vless-hysteria-watchdog 'vpn-web is not running; starting it'
  docker compose up -d web
elif ! tcp_listening "$WEB_LOCAL_PORT"; then
  logger -t vless-hysteria-watchdog "Local website TCP/$WEB_LOCAL_PORT is not listening; restarting vpn-web"
  docker restart vpn-web >/dev/null
elif [[ "$VLESS_MODE" == "web-xhttp" ]] && ! tcp_listening "$VLESS_LISTEN_PORT"; then
  logger -t vless-hysteria-watchdog "Public web/VLESS TCP/$VLESS_LISTEN_PORT is not listening; restarting vpn-web"
  docker restart vpn-web >/dev/null
fi

if ! container_running vpn-hysteria; then
  logger -t vless-hysteria-watchdog 'vpn-hysteria is not running; starting it'
  docker compose up -d hysteria
elif ! udp_listening "$HY2_LISTEN_PORT"; then
  logger -t vless-hysteria-watchdog "UDP/$HY2_LISTEN_PORT is not listening; restarting vpn-hysteria"
  docker restart vpn-hysteria >/dev/null
fi
