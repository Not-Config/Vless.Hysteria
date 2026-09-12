#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
NON_INTERACTIVE=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ./install.sh [--non-interactive] [--force]

Environment variables can override installer defaults, for example:
  PUBLIC_HOST=vpn.example.com REALITY_SNI=www.yandex.ru sudo -E ./install.sh
EOF
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log() { printf '[Vless.Hysteria] %s\n' "$*"; }
die() { printf '[Vless.Hysteria] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)."
[[ -f "$SOURCE_DIR/compose.yml" ]] || die "Run install.sh from a complete repository checkout."

if [[ -e "$VH_HOME/.env" && $FORCE -ne 1 ]]; then
  die "$VH_HOME already contains an installation. Use --force only if you intend to replace generated configuration."
fi

prompt_value() {
  local var="$1" text="$2" default="$3" value=""
  if [[ -v "$var" ]]; then
    value="${!var}"
  fi
  if [[ -z "$value" ]]; then
    if [[ $NON_INTERACTIVE -eq 1 ]]; then
      value="$default"
    else
      read -r -p "$text [$default]: " value
      value="${value:-$default}"
    fi
  fi
  printf -v "$var" '%s' "$value"
  export "$var"
}

install_base_packages() {
  log "Installing base packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl openssl jq uuid-runtime python3 iproute2 tar
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Engine and Compose are already installed"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Automatic Docker installation currently supports Ubuntu and Debian only (detected: ${ID:-unknown})." ;;
  esac

  log "Installing Docker Engine from the official Docker repository"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_base_packages
install_docker

AUTO_PUBLIC="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$AUTO_PUBLIC" ]]; then
  AUTO_PUBLIC="$(hostname -I | awk '{print $1}')"
fi

prompt_value PUBLIC_HOST "Public IP or DNS name used by clients" "$AUTO_PUBLIC"
prompt_value PUBLIC_VLESS_PORT "Public VLESS TCP port" "443"
prompt_value PUBLIC_HY2_PORT "Public Hysteria2 UDP port" "443"
prompt_value VLESS_LISTEN_PORT "Server VLESS TCP listen port" "443"
prompt_value HY2_LISTEN_PORT "Server Hysteria2 UDP listen port" "443"
prompt_value REALITY_SNI "REALITY SNI" "www.yandex.ru"
prompt_value REALITY_DEST "REALITY destination host" "$REALITY_SNI"
prompt_value HY2_SNI "Hysteria2 certificate/SNI name" "vpn.example.invalid"
prompt_value HY2_MASQUERADE "Hysteria2 masquerade URL" "https://www.yandex.ru/"
prompt_value INITIAL_USER "Initial username" "default"

XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.9.8}"
HYSTERIA_IMAGE="${HYSTERIA_IMAGE:-tobyxdd/hysteria:v2.12.2}"
HY2_CERT_DAYS="${HY2_CERT_DAYS:-3650}"

[[ "$PUBLIC_VLESS_PORT" =~ ^[0-9]+$ && "$PUBLIC_VLESS_PORT" -ge 1 && "$PUBLIC_VLESS_PORT" -le 65535 ]] || die "Invalid PUBLIC_VLESS_PORT"
[[ "$PUBLIC_HY2_PORT" =~ ^[0-9]+$ && "$PUBLIC_HY2_PORT" -ge 1 && "$PUBLIC_HY2_PORT" -le 65535 ]] || die "Invalid PUBLIC_HY2_PORT"
[[ "$VLESS_LISTEN_PORT" =~ ^[0-9]+$ && "$VLESS_LISTEN_PORT" -ge 1 && "$VLESS_LISTEN_PORT" -le 65535 ]] || die "Invalid VLESS_LISTEN_PORT"
[[ "$HY2_LISTEN_PORT" =~ ^[0-9]+$ && "$HY2_LISTEN_PORT" -ge 1 && "$HY2_LISTEN_PORT" -le 65535 ]] || die "Invalid HY2_LISTEN_PORT"
[[ "$INITIAL_USER" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "INITIAL_USER must match [A-Za-z0-9_.-] and be 1-32 characters long"

if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${VLESS_LISTEN_PORT}$"; then
  die "TCP/$VLESS_LISTEN_PORT is already in use. Choose another VLESS_LISTEN_PORT."
fi
if ss -lnuH | awk '{print $4}' | grep -Eq "(^|:)${HY2_LISTEN_PORT}$"; then
  die "UDP/$HY2_LISTEN_PORT is already in use. Choose another HY2_LISTEN_PORT."
fi

log "Creating runtime directory: $VH_HOME"
install -d -m 0750 "$VH_HOME" "$VH_HOME/templates" "$VH_HOME/lib" "$VH_HOME/systemd" "$VH_HOME/xray" "$VH_HOME/hysteria/certs"
install -m 0644 "$SOURCE_DIR/compose.yml" "$VH_HOME/compose.yml"
install -m 0644 "$SOURCE_DIR/templates/xray.json.tpl" "$VH_HOME/templates/xray.json.tpl"
install -m 0644 "$SOURCE_DIR/templates/hysteria.yaml.tpl" "$VH_HOME/templates/hysteria.yaml.tpl"
install -m 0644 "$SOURCE_DIR/lib/common.sh" "$VH_HOME/lib/common.sh"

for script in configure.sh status.sh user.sh backup.sh diagnostics.sh update.sh uninstall.sh watchdog.sh; do
  install -m 0750 "$SOURCE_DIR/$script" "$VH_HOME/$script"
done

cat > "$VH_HOME/.env" <<EOF
XRAY_IMAGE=$XRAY_IMAGE
HYSTERIA_IMAGE=$HYSTERIA_IMAGE
VLESS_LISTEN_PORT=$VLESS_LISTEN_PORT
HY2_LISTEN_PORT=$HY2_LISTEN_PORT
PUBLIC_HOST=$PUBLIC_HOST
PUBLIC_VLESS_PORT=$PUBLIC_VLESS_PORT
PUBLIC_HY2_PORT=$PUBLIC_HY2_PORT
REALITY_SNI=$REALITY_SNI
REALITY_DEST=$REALITY_DEST
HY2_SNI=$HY2_SNI
HY2_MASQUERADE=$HY2_MASQUERADE
HY2_CERT_DAYS=$HY2_CERT_DAYS
INITIAL_USER=$INITIAL_USER
EOF
chmod 600 "$VH_HOME/.env"

log "Pulling pinned container images"
docker pull "$XRAY_IMAGE"
docker pull "$HYSTERIA_IMAGE"

log "Generating REALITY X25519 key pair"
XRAY_KEYS="$(docker run --rm "$XRAY_IMAGE" x25519)"
REALITY_PRIVATE_KEY="$(awk -F': ' '/PrivateKey/ {print $2; exit}' <<<"$XRAY_KEYS")"
REALITY_PUBLIC_KEY="$(awk -F': ' '/Password/ {print $2; exit}' <<<"$XRAY_KEYS")"
if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
  REALITY_PUBLIC_KEY="$(awk -F': ' '/PublicKey/ {print $2; exit}' <<<"$XRAY_KEYS")"
fi
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Could not parse Xray x25519 output."

REALITY_SHORT_ID="$(openssl rand -hex 8)"
HY2_OBFS_PASSWORD="$(openssl rand -hex 24)"

cat > "$VH_HOME/secrets.env" <<EOF
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
HY2_OBFS_PASSWORD=$HY2_OBFS_PASSWORD
HY2_CERT_SHA256=
EOF
chmod 600 "$VH_HOME/secrets.env"

VLESS_UUID="$(uuidgen)"
HY2_PASSWORD="$(openssl rand -hex 20)"
jq -n \
  --arg name "$INITIAL_USER" \
  --arg uuid "$VLESS_UUID" \
  --arg hy2 "$HY2_PASSWORD" \
  '[{name:$name, vless_uuid:$uuid, hy2_password:$hy2}]' \
  > "$VH_HOME/users.json"
chmod 600 "$VH_HOME/users.json"

# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
generate_certificate
render_configs
validate_reality_target
validate_xray_config

log "Starting VPN stack"
(cd "$VH_HOME" && docker compose up -d)

install -m 0644 "$SOURCE_DIR/systemd/vless-hysteria-watchdog.service" /etc/systemd/system/vless-hysteria-watchdog.service
install -m 0644 "$SOURCE_DIR/systemd/vless-hysteria-watchdog.timer" /etc/systemd/system/vless-hysteria-watchdog.timer
systemctl daemon-reload
systemctl enable --now vless-hysteria-watchdog.timer

sleep 2

printf '\n========================================\n'
printf ' Vless.Hysteria installation complete\n'
printf '========================================\n\n'
"$VH_HOME/status.sh" --brief
printf '\nClient links for %s:\n\n' "$INITIAL_USER"
print_user_links "$INITIAL_USER"
printf '\nRuntime directory: %s\n' "$VH_HOME"
printf 'Secrets: %s and %s (mode 0600)\n' "$SECRETS_FILE" "$USERS_FILE"
