#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

if [[ "$TLS_CERT_MODE" != "letsencrypt" ]]; then
  exit 0
fi

command -v certbot >/dev/null 2>&1 || die "certbot is not installed"

old_sha=""
if [[ -f "$VH_HOME/hysteria/certs/server.crt" ]]; then
  old_sha="$(sha256sum "$VH_HOME/hysteria/certs/server.crt" | awk '{print $1}')"
fi

log "Checking Let's Encrypt certificate renewal for $WEB_DOMAIN"
certbot renew --quiet
sync_letsencrypt_certificate

new_sha="$(sha256sum "$VH_HOME/hysteria/certs/server.crt" | awk '{print $1}')"
if [[ "$new_sha" != "$old_sha" ]]; then
  log "Certificate changed; recreating web and Hysteria2 containers"
  (cd "$VH_HOME" && docker compose up -d --force-recreate web hysteria)
else
  log "Certificate is unchanged"
fi
