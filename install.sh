#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
INSTALL_MARKER="$VH_HOME/.installed"
NON_INTERACTIVE=0
FORCE=0
RESET_EXISTING=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ./install.sh [--non-interactive] [--force]

Environment variables can override installer defaults, for example:
  PUBLIC_HOST=vpn.example.com VLESS_MODE=reality REALITY_SNI=www.yandex.ru sudo -E ./install.sh
  PUBLIC_HOST=vpn.example.com VLESS_MODE=web-xhttp HY2_SNI=vpn.example.com WEB_DOMAIN=vpn.example.com TLS_CERT_MODE=letsencrypt ACME_EMAIL=admin@example.com sudo -E ./install.sh
  VLESS_MODE=web-xhttp CAMOUFLAGE_MODE=reverse-proxy CAMOUFLAGE_UPSTREAM=https://prime-top.ru sudo -E ./install.sh
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

if [[ -e "$VH_HOME/.env" ]]; then
  if [[ -e "$INSTALL_MARKER" && $FORCE -ne 1 ]]; then
    die "$VH_HOME already contains a completed installation. Use --force only if you intend to replace generated configuration."
  fi

  RESET_EXISTING=1
  if [[ -e "$INSTALL_MARKER" ]]; then
    log "Force reinstall requested; existing generated configuration will be replaced"
  else
    log "Detected an incomplete previous installation; resuming from a clean generated state"
  fi
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

port_in_use_tcp() {
  local port="$1"
  ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

port_in_use_udp() {
  local port="$1"
  ss -lnuH | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

validate_camouflage_upstream() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import sys
from urllib.parse import urlsplit

u = urlsplit(sys.argv[1])
if u.scheme != "https" or not u.hostname:
    raise SystemExit(1)
if u.username or u.password or u.query or u.fragment:
    raise SystemExit(1)
if u.path not in ("", "/"):
    raise SystemExit(1)
PY
}

install_base_packages() {
  log "Installing base packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl openssl jq uuid-runtime python3 iproute2 tar certbot
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
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "/etc/apt/keyrings/docker.asc" "$ID" "$VERSION_CODENAME" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_base_packages
install_docker

if [[ $RESET_EXISTING -eq 1 && -f "$VH_HOME/compose.yml" ]]; then
  log "Stopping any containers left by the previous installation attempt"
  (cd "$VH_HOME" && docker compose down --remove-orphans) >/dev/null 2>&1 || true
fi

AUTO_PUBLIC="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$AUTO_PUBLIC" ]]; then
  AUTO_PUBLIC="$(hostname -I | awk '{print $1}')"
fi

prompt_value PUBLIC_HOST "Public IP or DNS name used by clients" "$AUTO_PUBLIC"
prompt_value PUBLIC_VLESS_PORT "Public VLESS TCP port" "443"
prompt_value PUBLIC_HY2_PORT "Public Hysteria2 UDP port" "443"
prompt_value VLESS_LISTEN_PORT "Server public VLESS/web TCP listen port" "443"
prompt_value HY2_LISTEN_PORT "Server Hysteria2 UDP listen port" "443"
prompt_value VLESS_MODE "VLESS mode (reality or web-xhttp)" "reality"

CAMOUFLAGE_MODE="${CAMOUFLAGE_MODE:-local}"
CAMOUFLAGE_UPSTREAM="${CAMOUFLAGE_UPSTREAM:-https://prime-top.ru}"

case "$VLESS_MODE" in
  reality)
    prompt_value REALITY_SNI "REALITY SNI" "www.yandex.ru"
    prompt_value REALITY_DEST "REALITY destination host" "$REALITY_SNI"
    CAMOUFLAGE_MODE=local
    ;;
  web-xhttp)
    REALITY_SNI="${REALITY_SNI:-www.yandex.ru}"
    REALITY_DEST="${REALITY_DEST:-$REALITY_SNI}"
    prompt_value VLESS_XHTTP_BACKEND_PORT "Local Xray XHTTP backend port" "10000"
    prompt_value VLESS_XHTTP_PATH "VLESS XHTTP path" "/api/v1/stream"
    prompt_value CAMOUFLAGE_MODE "Camouflage website mode (local or reverse-proxy)" "$CAMOUFLAGE_MODE"
    case "$CAMOUFLAGE_MODE" in
      local)
        ;;
      reverse-proxy)
        prompt_value CAMOUFLAGE_UPSTREAM "Camouflage upstream HTTPS URL" "$CAMOUFLAGE_UPSTREAM"
        validate_camouflage_upstream "$CAMOUFLAGE_UPSTREAM" || die "CAMOUFLAGE_UPSTREAM must be an HTTPS origin URL such as https://prime-top.ru"
        CAMOUFLAGE_UPSTREAM="${CAMOUFLAGE_UPSTREAM%/}"
        ;;
      *) die "CAMOUFLAGE_MODE must be local or reverse-proxy" ;;
    esac
    ;;
  *) die "VLESS_MODE must be reality or web-xhttp" ;;
esac

prompt_value REALITY_FINGERPRINT "Client TLS fingerprint" "chrome"
prompt_value HY2_SNI "Hysteria2 certificate/SNI name" "vpn.example.invalid"
prompt_value WEB_DOMAIN "Website domain/SNI for web-xhttp mode" "$HY2_SNI"
prompt_value TLS_CERT_MODE "Shared TLS certificate mode (selfsigned or letsencrypt)" "selfsigned"

case "$TLS_CERT_MODE" in
  letsencrypt)
    prompt_value ACME_EMAIL "Let's Encrypt account email" ""
    WEB_ALLOW_INSECURE=0
    ;;
  selfsigned)
    ACME_EMAIL="${ACME_EMAIL:-}"
    prompt_value WEB_ALLOW_INSECURE "Allow self-signed TLS in generated web-xhttp client link (1 or 0)" "1"
    ;;
  *) die "TLS_CERT_MODE must be selfsigned or letsencrypt" ;;
esac

prompt_value WEB_LOCAL_PORT "Internal camouflage website HTTP port" "8080"
prompt_value HY2_MASQUERADE "Hysteria2 masquerade URL" "http://127.0.0.1:${WEB_LOCAL_PORT}/"
prompt_value INITIAL_USER "Initial username" "default"

VLESS_XHTTP_BACKEND_PORT="${VLESS_XHTTP_BACKEND_PORT:-10000}"
VLESS_XHTTP_PATH="${VLESS_XHTTP_PATH:-/api/v1/stream}"
[[ "$VLESS_XHTTP_PATH" == /* ]] || VLESS_XHTTP_PATH="/$VLESS_XHTTP_PATH"
VLESS_XHTTP_PATH="${VLESS_XHTTP_PATH%/}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.9.8}"
HYSTERIA_IMAGE="${HYSTERIA_IMAGE:-tobyxdd/hysteria:v2.12.2}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.30.4-alpine}"
HY2_CERT_DAYS="${HY2_CERT_DAYS:-3650}"

for p in "$PUBLIC_VLESS_PORT" "$PUBLIC_HY2_PORT" "$VLESS_LISTEN_PORT" "$HY2_LISTEN_PORT" "$VLESS_XHTTP_BACKEND_PORT" "$WEB_LOCAL_PORT"; do
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "Invalid port: $p"
done

case "$REALITY_FINGERPRINT" in
  chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
  *) die "Invalid REALITY_FINGERPRINT. Use chrome, firefox, safari, ios, android, edge, 360, qq, random or randomized." ;;
esac

[[ "$WEB_ALLOW_INSECURE" == "0" || "$WEB_ALLOW_INSECURE" == "1" ]] || die "WEB_ALLOW_INSECURE must be 0 or 1"
[[ "$VLESS_XHTTP_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "VLESS_XHTTP_PATH contains unsupported characters"
[[ "$INITIAL_USER" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "INITIAL_USER must match [A-Za-z0-9_.-] and be 1-32 characters long"

if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
  [[ "$HY2_SNI" == "$WEB_DOMAIN" ]] || die "Let's Encrypt shared mode requires HY2_SNI and WEB_DOMAIN to be identical"
  [[ "$ACME_EMAIL" == *@*.* ]] || die "ACME_EMAIL must look like an email address"
fi

if [[ "$VLESS_MODE" == "web-xhttp" ]]; then
  [[ "$VLESS_XHTTP_BACKEND_PORT" != "$VLESS_LISTEN_PORT" ]] || die "VLESS_XHTTP_BACKEND_PORT must differ from VLESS_LISTEN_PORT"
  [[ "$WEB_LOCAL_PORT" != "$VLESS_LISTEN_PORT" ]] || die "WEB_LOCAL_PORT must differ from VLESS_LISTEN_PORT"
fi

if port_in_use_tcp "$VLESS_LISTEN_PORT"; then
  die "TCP/$VLESS_LISTEN_PORT is already in use. Choose another VLESS_LISTEN_PORT."
fi
if [[ "$VLESS_MODE" == "web-xhttp" ]] && port_in_use_tcp "$VLESS_XHTTP_BACKEND_PORT"; then
  die "TCP/$VLESS_XHTTP_BACKEND_PORT is already in use. Choose another VLESS_XHTTP_BACKEND_PORT."
fi
if port_in_use_tcp "$WEB_LOCAL_PORT"; then
  die "TCP/$WEB_LOCAL_PORT is already in use. Choose another WEB_LOCAL_PORT."
fi
if port_in_use_udp "$HY2_LISTEN_PORT"; then
  die "UDP/$HY2_LISTEN_PORT is already in use. Choose another HY2_LISTEN_PORT."
fi

log "Creating runtime directory: $VH_HOME"
install -d -m 0750 \
  "$VH_HOME" \
  "$VH_HOME/templates" \
  "$VH_HOME/lib" \
  "$VH_HOME/systemd" \
  "$VH_HOME/xray" \
  "$VH_HOME/hysteria/certs" \
  "$VH_HOME/web/html"
install -m 0644 "$SOURCE_DIR/compose.yml" "$VH_HOME/compose.yml"
install -m 0644 "$SOURCE_DIR/templates/xray.json.tpl" "$VH_HOME/templates/xray.json.tpl"
install -m 0644 "$SOURCE_DIR/templates/xray-xhttp.json.tpl" "$VH_HOME/templates/xray-xhttp.json.tpl"
install -m 0644 "$SOURCE_DIR/templates/hysteria.yaml.tpl" "$VH_HOME/templates/hysteria.yaml.tpl"
install -m 0644 "$SOURCE_DIR/templates/nginx-local.conf.tpl" "$VH_HOME/templates/nginx-local.conf.tpl"
install -m 0644 "$SOURCE_DIR/templates/nginx-xhttp.conf.tpl" "$VH_HOME/templates/nginx-xhttp.conf.tpl"
install -m 0644 "$SOURCE_DIR/templates/nginx-xhttp-reverse-proxy.conf.tpl" "$VH_HOME/templates/nginx-xhttp-reverse-proxy.conf.tpl"
install -m 0644 "$SOURCE_DIR/web/index.html" "$VH_HOME/web/html/index.html"
install -m 0644 "$SOURCE_DIR/lib/common.sh" "$VH_HOME/lib/common.sh"

for unit in \
  vless-hysteria-watchdog.service \
  vless-hysteria-watchdog.timer \
  vless-hysteria-cert-renew.service \
  vless-hysteria-cert-renew.timer; do
  install -m 0644 "$SOURCE_DIR/systemd/$unit" "$VH_HOME/systemd/$unit"
done

for script in configure.sh status.sh user.sh backup.sh diagnostics.sh update.sh uninstall.sh watchdog.sh cert-renew.sh; do
  install -m 0750 "$SOURCE_DIR/$script" "$VH_HOME/$script"
done

cat > "$VH_HOME/.env" <<EOF
XRAY_IMAGE=$XRAY_IMAGE
HYSTERIA_IMAGE=$HYSTERIA_IMAGE
NGINX_IMAGE=$NGINX_IMAGE
VLESS_MODE=$VLESS_MODE
VLESS_LISTEN_PORT=$VLESS_LISTEN_PORT
VLESS_XHTTP_BACKEND_PORT=$VLESS_XHTTP_BACKEND_PORT
VLESS_XHTTP_PATH=$VLESS_XHTTP_PATH
HY2_LISTEN_PORT=$HY2_LISTEN_PORT
PUBLIC_HOST=$PUBLIC_HOST
PUBLIC_VLESS_PORT=$PUBLIC_VLESS_PORT
PUBLIC_HY2_PORT=$PUBLIC_HY2_PORT
REALITY_SNI=$REALITY_SNI
REALITY_DEST=$REALITY_DEST
REALITY_FINGERPRINT=$REALITY_FINGERPRINT
HY2_SNI=$HY2_SNI
HY2_MASQUERADE=$HY2_MASQUERADE
HY2_CERT_DAYS=$HY2_CERT_DAYS
WEB_DOMAIN=$WEB_DOMAIN
WEB_LOCAL_PORT=$WEB_LOCAL_PORT
WEB_ALLOW_INSECURE=$WEB_ALLOW_INSECURE
CAMOUFLAGE_MODE=$CAMOUFLAGE_MODE
CAMOUFLAGE_UPSTREAM=$CAMOUFLAGE_UPSTREAM
TLS_CERT_MODE=$TLS_CERT_MODE
ACME_EMAIL=$ACME_EMAIL
INITIAL_USER=$INITIAL_USER
EOF
chmod 600 "$VH_HOME/.env"
rm -f "$INSTALL_MARKER"

log "Pulling pinned container images"
docker pull "$XRAY_IMAGE"
docker pull "$HYSTERIA_IMAGE"
docker pull "$NGINX_IMAGE"

log "Generating REALITY X25519 key pair"
XRAY_KEYS="$(docker run --rm "$XRAY_IMAGE" x25519)"
REALITY_PRIVATE_KEY="$(awk -F': ' '/PrivateKey/ {print $2; exit}' <<<"$XRAY_KEYS")"
REALITY_PUBLIC_KEY="$(awk -F': ' '/Password/ {print $2; exit}' <<<"$XRAY_KEYS")"
if [[ -z "$REALITY_PUBLIC_KEY" ]]; then
  REALITY_PUBLIC_KEY="$(awk -F': ' '/PublicKey/ {print $2; exit}' <<<"$XRAY_KEYS")"
fi
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Could not parse Xray x25519 output."

REALITY_SHORT_ID="$(openssl rand -hex 8)"

cat > "$VH_HOME/secrets.env" <<EOF
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
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
validate_nginx_config

if [[ "$VLESS_MODE" == "web-xhttp" && "$TLS_CERT_MODE" == "selfsigned" && "$WEB_ALLOW_INSECURE" == "1" ]]; then
  warn "web-xhttp is using a self-signed certificate. The generated VLESS link disables certificate verification. Use TLS_CERT_MODE=letsencrypt for a normal public certificate."
fi

log "Starting VPN stack"
restart_stack

install -m 0644 "$VH_HOME/systemd/vless-hysteria-watchdog.service" /etc/systemd/system/vless-hysteria-watchdog.service
install -m 0644 "$VH_HOME/systemd/vless-hysteria-watchdog.timer" /etc/systemd/system/vless-hysteria-watchdog.timer
install -m 0644 "$VH_HOME/systemd/vless-hysteria-cert-renew.service" /etc/systemd/system/vless-hysteria-cert-renew.service
install -m 0644 "$VH_HOME/systemd/vless-hysteria-cert-renew.timer" /etc/systemd/system/vless-hysteria-cert-renew.timer
systemctl daemon-reload
systemctl enable --now vless-hysteria-watchdog.timer

if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
  systemctl enable --now vless-hysteria-cert-renew.timer
else
  systemctl disable --now vless-hysteria-cert-renew.timer >/dev/null 2>&1 || true
fi

sleep 2

touch "$INSTALL_MARKER"
chmod 600 "$INSTALL_MARKER"

printf '\n========================================\n'
printf ' Vless.Hysteria installation complete\n'
printf '========================================\n\n'
"$VH_HOME/status.sh" --brief
printf '\nClient links for %s:\n\n' "$INITIAL_USER"
print_user_links "$INITIAL_USER"
printf '\nRuntime directory: %s\n' "$VH_HOME"
printf 'Secrets: %s and %s (mode 0600)\n' "$SECRETS_FILE" "$USERS_FILE"
