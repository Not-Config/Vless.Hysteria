#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

usage() {
  cat <<'EOF'
Usage:
  user.sh list
  user.sh add <name>
  user.sh remove <name>
  user.sh links <name>
  user.sh rotate <name>
EOF
}

restart_after_user_change() {
  render_configs
  validate_xray_config
  restart_stack
}

cmd="${1:-}"
name="${2:-}"

case "$cmd" in
  list)
    jq -r '.[] | [.name, .vless_uuid] | @tsv' "$USERS_FILE" |
      awk 'BEGIN {printf "%-20s %s\n", "USER", "VLESS UUID"} {printf "%-20s %s\n", $1, $2}'
    ;;

  add)
    [[ -n "$name" ]] || { usage; exit 2; }
    valid_username "$name" || die "Username must match [A-Za-z0-9_.-] and be 1-32 characters long."
    if jq -e --arg u "$name" '.[] | select(.name == $u)' "$USERS_FILE" >/dev/null; then
      die "User already exists: $name"
    fi

    uuid="$(uuidgen)"
    hy2="$(openssl rand -hex 20)"
    tmp="$(mktemp)"
    jq --arg name "$name" --arg uuid "$uuid" --arg hy2 "$hy2" \
      '. + [{name:$name, vless_uuid:$uuid, hy2_password:$hy2}]' \
      "$USERS_FILE" > "$tmp"
    install -m 0600 "$tmp" "$USERS_FILE"
    rm -f "$tmp"

    restart_after_user_change
    log "User created: $name"
    printf '\n'
    print_user_links "$name"
    ;;

  remove)
    [[ -n "$name" ]] || { usage; exit 2; }
    valid_username "$name" || die "Invalid username."
    jq -e --arg u "$name" '.[] | select(.name == $u)' "$USERS_FILE" >/dev/null || die "Unknown user: $name"
    [[ "$(jq 'length' "$USERS_FILE")" -gt 1 ]] || die "Refusing to remove the final user."

    tmp="$(mktemp)"
    jq --arg u "$name" '[.[] | select(.name != $u)]' "$USERS_FILE" > "$tmp"
    install -m 0600 "$tmp" "$USERS_FILE"
    rm -f "$tmp"

    restart_after_user_change
    log "User removed: $name"
    ;;

  rotate)
    [[ -n "$name" ]] || { usage; exit 2; }
    valid_username "$name" || die "Invalid username."
    jq -e --arg u "$name" '.[] | select(.name == $u)' "$USERS_FILE" >/dev/null || die "Unknown user: $name"

    uuid="$(uuidgen)"
    hy2="$(openssl rand -hex 20)"
    tmp="$(mktemp)"
    jq --arg u "$name" --arg uuid "$uuid" --arg hy2 "$hy2" \
      'map(if .name == $u then .vless_uuid=$uuid | .hy2_password=$hy2 else . end)' \
      "$USERS_FILE" > "$tmp"
    install -m 0600 "$tmp" "$USERS_FILE"
    rm -f "$tmp"

    restart_after_user_change
    log "Credentials rotated: $name"
    printf '\n'
    print_user_links "$name"
    ;;

  links)
    [[ -n "$name" ]] || { usage; exit 2; }
    print_user_links "$name"
    ;;

  *)
    usage
    exit 2
    ;;
esac
