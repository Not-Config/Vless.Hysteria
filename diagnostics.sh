#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

printf '===== SYSTEM =====\n'
uname -a
printf '\n'
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)=' || true

printf '\n===== NETWORK =====\n'
ip -br addr
ip route

printf '\n===== DOCKER =====\n'
docker --version
docker compose version
(cd "$VH_HOME" && docker compose ps)

printf '\n===== LISTENERS =====\n'
ss -lntup | grep -E "(:${VLESS_LISTEN_PORT}[[:space:]]|:${VLESS_GRPC_BACKEND_PORT}[[:space:]]|:${WEB_LOCAL_PORT}[[:space:]]|:${HY2_LISTEN_PORT}[[:space:]])" || true

printf '\n===== WATCHDOG =====\n'
systemctl status vless-hysteria-watchdog.timer --no-pager || true
journalctl -u vless-hysteria-watchdog.service -n 20 --no-pager || true

printf '\n===== XRAY LOG =====\n'
docker logs --tail 50 vpn-xray 2>&1 || true

printf '\n===== HYSTERIA2 LOG =====\n'
docker logs --tail 50 vpn-hysteria 2>&1 || true

printf '\n===== WEB LOG =====\n'
docker logs --tail 50 vpn-web 2>&1 || true

printf '\n===== NON-SECRET CONFIG =====\n'
printf 'VLESS_MODE=%s\n' "$VLESS_MODE"
printf 'PUBLIC_HOST=%s\n' "$PUBLIC_HOST"
printf 'PUBLIC_VLESS_PORT=%s\n' "$PUBLIC_VLESS_PORT"
printf 'PUBLIC_HY2_PORT=%s\n' "$PUBLIC_HY2_PORT"
printf 'VLESS_LISTEN_PORT=%s\n' "$VLESS_LISTEN_PORT"
printf 'VLESS_GRPC_BACKEND_PORT=%s\n' "$VLESS_GRPC_BACKEND_PORT"
printf 'VLESS_GRPC_SERVICE=%s\n' "$VLESS_GRPC_SERVICE"
printf 'HY2_LISTEN_PORT=%s\n' "$HY2_LISTEN_PORT"
printf 'REALITY_SNI=%s\n' "$REALITY_SNI"
printf 'REALITY_DEST=%s\n' "$REALITY_DEST"
printf 'HY2_SNI=%s\n' "$HY2_SNI"
printf 'WEB_DOMAIN=%s\n' "$WEB_DOMAIN"
printf 'WEB_LOCAL_PORT=%s\n' "$WEB_LOCAL_PORT"
printf 'XRAY_IMAGE=%s\n' "$XRAY_IMAGE"
printf 'HYSTERIA_IMAGE=%s\n' "$HYSTERIA_IMAGE"
printf 'NGINX_IMAGE=%s\n' "$NGINX_IMAGE"
printf 'USERS=%s\n' "$(jq -r '[.[].name] | join(",")' "$USERS_FILE")"

printf '\nNo passwords, UUIDs, private keys, public REALITY keys, short IDs, or certificate pins are printed by this script.\n'
