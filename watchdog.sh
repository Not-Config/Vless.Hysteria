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
  ss -lntH | grep -Eq "[:.]${VLESS_LISTEN_PORT}[[:space:]]"
}

udp_listening() {
  ss -lnuH | grep -Eq "[:.]${HY2_LISTEN_PORT}[[:space:]]"
}

if ! container_running vpn-xray; then
  logger -t vless-hysteria-watchdog 'vpn-xray is not running; starting it'
  docker compose up -d xray
elif ! tcp_listening; then
  logger -t vless-hysteria-watchdog "TCP/$VLESS_LISTEN_PORT is not listening; restarting vpn-xray"
  docker restart vpn-xray >/dev/null
fi

if ! container_running vpn-hysteria; then
  logger -t vless-hysteria-watchdog 'vpn-hysteria is not running; starting it'
  docker compose up -d hysteria
elif ! udp_listening; then
  logger -t vless-hysteria-watchdog "UDP/$HY2_LISTEN_PORT is not listening; restarting vpn-hysteria"
  docker restart vpn-hysteria >/dev/null
fi
