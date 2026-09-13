#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
ENV_FILE="$VH_HOME/.env"
USERS_FILE="$VH_HOME/users.json"
LAB_ENV_FILE="$VH_HOME/lab-reality.env"
LAB_DIR="$VH_HOME/lab-reality"
LAB_TEMPLATE="$VH_HOME/templates/xray-lab-reality.json.tpl"
LAB_COMPOSE="$VH_HOME/compose.lab-reality.yml"

log() { printf '[Vless.Hysteria reality-lab] %s\n' "$*"; }
warn() { printf '[Vless.Hysteria reality-lab] WARNING: %s\n' "$*" >&2; }
die() { printf '[Vless.Hysteria reality-lab] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this command as root (sudo)."
}

load_main() {
  [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Install the main stack first."
  [[ -f "$USERS_FILE" ]] || die "Missing $USERS_FILE. Install the main stack first."
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.9.8}"
  PUBLIC_HOST="${PUBLIC_HOST:?PUBLIC_HOST is missing from $ENV_FILE}"
}

load_lab() {
  LAB_REALITY_LISTEN_PORT="24443"
  PUBLIC_LAB_REALITY_PORT="24443"
  LAB_REALITY_TARGET="web.max.ru"
  LAB_REALITY_FINGERPRINT="chrome"
  LAB_REALITY_PRIVATE_KEY=""
  LAB_REALITY_PUBLIC_KEY=""
  LAB_REALITY_SHORT_ID=""

  if [[ -f "$LAB_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$LAB_ENV_FILE"
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" == *.* && "$1" != .* && "$1" != *. ]]
}

resolve_target() {
  case "$1" in
    max)
      printf '%s' 'web.max.ru'
      ;;
    smartcaptcha|yandex-smartcaptcha)
      printf '%s' 'smartcaptcha.cloud.yandex.ru'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

compose_lab() {
  (
    cd "$VH_HOME"
    docker compose -f compose.lab-reality.yml "$@"
  )
}

check_target() {
  log "Checking TLS 1.3 target: $LAB_REALITY_TARGET:443"
  if timeout 10 openssl s_client \
      -connect "$LAB_REALITY_TARGET:443" \
      -servername "$LAB_REALITY_TARGET" \
      -tls1_3 </dev/null 2>/dev/null |
      grep -q 'TLSv1.3'; then
    log "Target supports TLS 1.3"
  else
    die "Could not confirm TLS 1.3 for $LAB_REALITY_TARGET. Choose another REALITY target."
  fi
}

generate_keys_if_needed() {
  if [[ -n "$LAB_REALITY_PRIVATE_KEY" && -n "$LAB_REALITY_PUBLIC_KEY" && -n "$LAB_REALITY_SHORT_ID" ]]; then
    return
  fi

  log "Generating separate REALITY keys for the lab listener"
  local output
  output="$(docker run --rm "$XRAY_IMAGE" x25519)"
  LAB_REALITY_PRIVATE_KEY="$(awk -F': ' '/PrivateKey/ {print $2; exit}' <<<"$output")"
  LAB_REALITY_PUBLIC_KEY="$(awk -F': ' '/Password/ {print $2; exit}' <<<"$output")"
  if [[ -z "$LAB_REALITY_PUBLIC_KEY" ]]; then
    LAB_REALITY_PUBLIC_KEY="$(awk -F': ' '/PublicKey/ {print $2; exit}' <<<"$output")"
  fi
  LAB_REALITY_SHORT_ID="$(openssl rand -hex 8)"

  [[ -n "$LAB_REALITY_PRIVATE_KEY" && -n "$LAB_REALITY_PUBLIC_KEY" ]] || die "Could not parse Xray x25519 output."
}

save_lab_env() {
  cat > "$LAB_ENV_FILE" <<EOF
LAB_REALITY_LISTEN_PORT=$LAB_REALITY_LISTEN_PORT
PUBLIC_LAB_REALITY_PORT=$PUBLIC_LAB_REALITY_PORT
LAB_REALITY_TARGET=$LAB_REALITY_TARGET
LAB_REALITY_FINGERPRINT=$LAB_REALITY_FINGERPRINT
LAB_REALITY_PRIVATE_KEY=$LAB_REALITY_PRIVATE_KEY
LAB_REALITY_PUBLIC_KEY=$LAB_REALITY_PUBLIC_KEY
LAB_REALITY_SHORT_ID=$LAB_REALITY_SHORT_ID
EOF
  chmod 600 "$LAB_ENV_FILE"
}

render_config() {
  [[ -f "$LAB_TEMPLATE" ]] || die "Missing $LAB_TEMPLATE. Copy the new template into the runtime first."

  mkdir -p "$LAB_DIR"
  local clients
  clients="$(jq -c '[.[] | {id: .vless_uuid, flow: "xtls-rprx-vision", email: .name}]' "$USERS_FILE")"

  export R_LAB_REALITY_LISTEN_PORT="$LAB_REALITY_LISTEN_PORT"
  export R_LAB_REALITY_TARGET="$LAB_REALITY_TARGET"
  export R_LAB_REALITY_PRIVATE_KEY="$LAB_REALITY_PRIVATE_KEY"
  export R_LAB_REALITY_SHORT_ID="$LAB_REALITY_SHORT_ID"
  export R_VLESS_CLIENTS_JSON="$clients"

  python3 - "$LAB_TEMPLATE" "$LAB_DIR/config.json" <<'PY'
import os
import pathlib
import sys

src, dst = map(pathlib.Path, sys.argv[1:3])
s = src.read_text()
repl = {
    "__LAB_REALITY_LISTEN_PORT__": os.environ["R_LAB_REALITY_LISTEN_PORT"],
    "__LAB_REALITY_TARGET__": os.environ["R_LAB_REALITY_TARGET"],
    "__LAB_REALITY_PRIVATE_KEY__": os.environ["R_LAB_REALITY_PRIVATE_KEY"],
    "__LAB_REALITY_SHORT_ID__": os.environ["R_LAB_REALITY_SHORT_ID"],
    "__VLESS_CLIENTS_JSON__": os.environ["R_VLESS_CLIENTS_JSON"],
}
for old, new in repl.items():
    s = s.replace(old, new)
dst.write_text(s)
PY

  chmod 600 "$LAB_DIR/config.json"
}

validate_config() {
  docker run --rm \
    --user 0:0 \
    -v "$LAB_DIR/config.json:/usr/local/etc/xray/config.json:ro" \
    "$XRAY_IMAGE" \
    run -test -config /usr/local/etc/xray/config.json
}

enable_lab() {
  local requested_target="${1:-max}"
  LAB_REALITY_TARGET="$(resolve_target "$requested_target")"
  LAB_REALITY_LISTEN_PORT="${2:-$LAB_REALITY_LISTEN_PORT}"
  PUBLIC_LAB_REALITY_PORT="${3:-$PUBLIC_LAB_REALITY_PORT}"

  valid_hostname "$LAB_REALITY_TARGET" || die "Invalid REALITY target: $LAB_REALITY_TARGET"
  valid_port "$LAB_REALITY_LISTEN_PORT" || die "Invalid listen port: $LAB_REALITY_LISTEN_PORT"
  valid_port "$PUBLIC_LAB_REALITY_PORT" || die "Invalid public port: $PUBLIC_LAB_REALITY_PORT"
  [[ -f "$LAB_COMPOSE" ]] || die "Missing $LAB_COMPOSE. Copy compose.lab-reality.yml into the runtime first."

  compose_lab down >/dev/null 2>&1 || true

  if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${LAB_REALITY_LISTEN_PORT}$"; then
    die "TCP/$LAB_REALITY_LISTEN_PORT is already in use by another service."
  fi

  check_target
  generate_keys_if_needed
  save_lab_env
  render_config
  validate_config

  warn "This is a controlled REALITY camouflage experiment. A matching SNI does not prove that a whitelist will permit the connection."
  compose_lab up -d lab-reality

  log "Lab REALITY listener enabled on TCP/$LAB_REALITY_LISTEN_PORT"
  log "Client/public port: $PUBLIC_LAB_REALITY_PORT"
  log "Camouflage target/SNI: $LAB_REALITY_TARGET"
}

disable_lab() {
  if [[ -f "$LAB_COMPOSE" ]]; then
    compose_lab down >/dev/null 2>&1 || true
  else
    docker rm -f vpn-lab-reality >/dev/null 2>&1 || true
  fi
  log "Lab REALITY listener disabled"
}

status_lab() {
  local state="DOWN" socket="CLOSED"
  if docker inspect -f '{{.State.Running}}' vpn-lab-reality 2>/dev/null | grep -qx true; then
    state="OK"
  fi
  if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${LAB_REALITY_LISTEN_PORT}$"; then
    socket="LISTEN"
  fi

  printf 'Vless.Hysteria lab REALITY status\n'
  printf '  Container:          %s\n' "$state"
  printf '  Server TCP/%s:      %s\n' "$LAB_REALITY_LISTEN_PORT" "$socket"
  printf '  Public endpoint:    %s:%s/TCP\n' "$PUBLIC_HOST" "$PUBLIC_LAB_REALITY_PORT"
  printf '  Transport:          VLESS + REALITY + Vision\n'
  printf '  Camouflage SNI:     %s\n' "$LAB_REALITY_TARGET"
  printf '  TLS fingerprint:    %s\n' "$LAB_REALITY_FINGERPRINT"
}

print_link() {
  local user="${1:?username required}"
  local row uuid
  row="$(jq -c --arg u "$user" '.[] | select(.name == $u)' "$USERS_FILE" | head -n1)"
  [[ -n "$row" ]] || die "Unknown user: $user"
  uuid="$(jq -r '.vless_uuid' <<<"$row")"

  python3 - \
    "$PUBLIC_HOST" \
    "$PUBLIC_LAB_REALITY_PORT" \
    "$LAB_REALITY_TARGET" \
    "$LAB_REALITY_FINGERPRINT" \
    "$LAB_REALITY_PUBLIC_KEY" \
    "$LAB_REALITY_SHORT_ID" \
    "$user" \
    "$uuid" <<'PY'
import sys
from urllib.parse import quote, urlencode

host, port, target, fingerprint, public_key, short_id, user, uuid = sys.argv[1:]
query = {
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": target,
    "fp": fingerprint,
    "pbk": public_key,
    "sid": short_id,
    "type": "tcp",
}
print(f"vless://{uuid}@{host}:{port}?{urlencode(query)}#{quote('VLESS-LAB-REALITY-' + user)}")
PY
}

usage() {
  cat <<'EOF'
Usage:
  sudo lab-reality.sh enable [max|smartcaptcha|hostname] [listen_port] [public_port]
  sudo lab-reality.sh disable
  sudo lab-reality.sh status
  sudo lab-reality.sh link <username>

Defaults:
  target preset:       max -> web.max.ru
  listen/public port:  24443
  transport:           VLESS + REALITY + XTLS Vision

Other preset:
  smartcaptcha -> smartcaptcha.cloud.yandex.ru

The helper verifies TLS 1.3 on the selected target before starting Xray.
EOF
}

require_root
load_main
load_lab

case "${1:-}" in
  enable)
    enable_lab "${2:-}" "${3:-}" "${4:-}"
    ;;
  disable)
    disable_lab
    ;;
  status)
    status_lab
    ;;
  link)
    [[ -n "${2:-}" ]] || die "Usage: lab-reality.sh link <username>"
    print_link "$2"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
