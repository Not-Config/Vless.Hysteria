#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

backup="/root/vless-hysteria-pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
"$VH_HOME/backup.sh" "$backup"

log "Pulling configured images"
docker pull "$XRAY_IMAGE"
docker pull "$HYSTERIA_IMAGE"

render_configs
validate_xray_config

log "Recreating stack"
(cd "$VH_HOME" && docker compose up -d --force-recreate)

sleep 2
"$VH_HOME/status.sh" --brief
printf '\nPre-update backup: %s\n' "$backup"
