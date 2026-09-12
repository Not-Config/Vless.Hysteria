#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

out="${1:-/root/vless-hysteria-$(date +%Y%m%d-%H%M%S).tar.gz}"
mkdir -p "$(dirname "$out")"

log "Creating backup: $out"
tar -C "$VH_HOME" -czf "$out" \
  .env \
  secrets.env \
  users.json \
  compose.yml \
  templates \
  lib \
  xray \
  hysteria \
  configure.sh \
  status.sh \
  user.sh \
  diagnostics.sh \
  update.sh \
  watchdog.sh
chmod 600 "$out"

printf 'Backup created: %s\n' "$out"
printf 'WARNING: this archive contains private keys and user credentials. Store it securely.\n'
