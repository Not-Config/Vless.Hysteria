#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
ENV_FILE="$VH_HOME/.env"
USERS_FILE="$VH_HOME/users.json"
LAB_ENV_FILE="$VH_HOME/lab-grpc.env"
LAB_DIR="$VH_HOME/lab-grpc"
LAB_TEMPLATE="$VH_HOME/templates/xray-lab-grpc.json.tpl"
LAB_COMPOSE="$VH_HOME/compose.lab-grpc.yml"

log() { printf '[Vless.Hysteria lab] %s\n' "$*"; }
warn() { printf '[Vless.Hysteria lab] WARNING: %s\n' "$*" >&2; }
die() { printf '[Vless.Hysteria lab] ERROR: %s\n' "$*" >&2; exit 1; }

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
  LAB_GRPC_LISTEN_PORT="20493"
  PUBLIC_LAB_GRPC_PORT="20493"
  LAB_GRPC_SERVICE="ws"

  if [[ -f "$LAB_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$LAB_ENV_FILE"
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

valid_service() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != /* && "$1" != */ ]]
}

compose_lab() {
  (
    cd "$VH_HOME"
    docker compose -f compose.lab-grpc.yml "$@"
  )
}

render_config() {
  [[ -f "$LAB_TEMPLATE" ]] || die "Missing $LAB_TEMPLATE. Copy the new template into the runtime first."

  mkdir -p "$LAB_DIR"
  local clients
  clients="$(jq -c '[.[] | {id: .vless_uuid, email: .name}]' "$USERS_FILE")"

  export R_LAB_GRPC_LISTEN_PORT="$LAB_GRPC_LISTEN_PORT"
  export R_LAB_GRPC_SERVICE="$LAB_GRPC_SERVICE"
  export R_VLESS_CLIENTS_JSON="$clients"

  python3 - "$LAB_TEMPLATE" "$LAB_DIR/config.json" <<'PY'
import os
import pathlib
import sys

src, dst = map(pathlib.Path, sys.argv[1:3])
s = src.read_text()
repl = {
    "__LAB_GRPC_LISTEN_PORT__": os.environ["R_LAB_GRPC_LISTEN_PORT"],
    "__LAB_GRPC_SERVICE__": os.environ["R_LAB_GRPC_SERVICE"],
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

save_lab_env() {
  cat > "$LAB_ENV_FILE" <<EOF
LAB_GRPC_LISTEN_PORT=$LAB_GRPC_LISTEN_PORT
PUBLIC_LAB_GRPC_PORT=$PUBLIC_LAB_GRPC_PORT
LAB_GRPC_SERVICE=$LAB_GRPC_SERVICE
EOF
  chmod 600 "$LAB_ENV_FILE"
}

enable_lab() {
  LAB_GRPC_LISTEN_PORT="${1:-$LAB_GRPC_LISTEN_PORT}"
  PUBLIC_LAB_GRPC_PORT="${2:-$PUBLIC_LAB_GRPC_PORT}"
  LAB_GRPC_SERVICE="${3:-$LAB_GRPC_SERVICE}"

  valid_port "$LAB_GRPC_LISTEN_PORT" || die "Invalid listen port: $LAB_GRPC_LISTEN_PORT"
  valid_port "$PUBLIC_LAB_GRPC_PORT" || die "Invalid public port: $PUBLIC_LAB_GRPC_PORT"
  valid_service "$LAB_GRPC_SERVICE" || die "Invalid gRPC service name: $LAB_GRPC_SERVICE"
  [[ -f "$LAB_COMPOSE" ]] || die "Missing $LAB_COMPOSE. Copy compose.lab-grpc.yml into the runtime first."

  # Free an old lab listener before checking the requested port.
  compose_lab down >/dev/null 2>&1 || true

  if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${LAB_GRPC_LISTEN_PORT}$"; then
    die "TCP/$LAB_GRPC_LISTEN_PORT is already in use by another service."
  fi

  save_lab_env
  render_config
  validate_config

  warn "This profile intentionally uses VLESS gRPC without TLS/REALITY. Use it only for controlled lab comparison."
  compose_lab up -d lab-grpc

  log "Lab VLESS gRPC listener enabled on TCP/$LAB_GRPC_LISTEN_PORT"
  log "Client/public port: $PUBLIC_LAB_GRPC_PORT"
  log "gRPC service: $LAB_GRPC_SERVICE"
}

disable_lab() {
  if [[ -f "$LAB_COMPOSE" ]]; then
    compose_lab down >/dev/null 2>&1 || true
  else
    docker rm -f vpn-lab-grpc >/dev/null 2>&1 || true
  fi
  log "Lab gRPC listener disabled"
}

status_lab() {
  local state="DOWN" socket="CLOSED"
  if docker inspect -f '{{.State.Running}}' vpn-lab-grpc 2>/dev/null | grep -qx true; then
    state="OK"
  fi
  if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${LAB_GRPC_LISTEN_PORT}$"; then
    socket="LISTEN"
  fi

  printf 'Vless.Hysteria lab gRPC status\n'
  printf '  Container:          %s\n' "$state"
  printf '  Server TCP/%s:      %s\n' "$LAB_GRPC_LISTEN_PORT" "$socket"
  printf '  Public endpoint:    %s:%s/TCP\n' "$PUBLIC_HOST" "$PUBLIC_LAB_GRPC_PORT"
  printf '  Transport:          VLESS + gRPC/h2c\n'
  printf '  Transport security: none\n'
  printf '  gRPC service:       %s\n' "$LAB_GRPC_SERVICE"
}

print_link() {
  local user="${1:?username required}"
  local row uuid
  row="$(jq -c --arg u "$user" '.[] | select(.name == $u)' "$USERS_FILE" | head -n1)"
  [[ -n "$row" ]] || die "Unknown user: $user"
  uuid="$(jq -r '.vless_uuid' <<<"$row")"

  python3 - "$PUBLIC_HOST" "$PUBLIC_LAB_GRPC_PORT" "$LAB_GRPC_SERVICE" "$user" "$uuid" <<'PY'
import sys
from urllib.parse import quote, urlencode

host, port, service, user, uuid = sys.argv[1:]
query = {
    "encryption": "none",
    "security": "none",
    "type": "grpc",
    "serviceName": service,
}
print(f"vless://{uuid}@{host}:{port}?{urlencode(query)}#{quote('VLESS-LAB-gRPC-' + user)}")
PY
}

usage() {
  cat <<'EOF'
Usage:
  sudo lab-grpc.sh enable [listen_port] [public_port] [service_name]
  sudo lab-grpc.sh disable
  sudo lab-grpc.sh status
  sudo lab-grpc.sh link <username>

Defaults reproduce the transport shape of the supplied working test profile:
  listen/public port: 20493
  service name:        ws
  transport:           VLESS + gRPC, security=none
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
    [[ -n "${2:-}" ]] || die "Usage: lab-grpc.sh link <username>"
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
