#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

old_hy2_sni="$HY2_SNI"
old_web_domain="$WEB_DOMAIN"
old_tls_cert_mode="$TLS_CERT_MODE"

ask() {
  local var="$1" label="$2" current="" value=""
  if [[ -v "$var" ]]; then
    current="${!var}"
  fi
  read -r -p "$label [$current]: " value
  printf -v "$var" '%s' "${value:-$current}"
}

printf 'Reconfigure Vless.Hysteria\n'
printf 'Press Enter to keep the current value.\n\n'

ask PUBLIC_HOST "Public IP/DNS used in client links"
ask PUBLIC_VLESS_PORT "Public VLESS TCP port"
ask PUBLIC_HY2_PORT "Public Hysteria2 UDP port"
ask VLESS_LISTEN_PORT "Public VLESS/web TCP listen port"
ask HY2_LISTEN_PORT "Hysteria2 UDP listen port"
ask VLESS_MODE "VLESS mode (reality or web-grpc)"

case "$VLESS_MODE" in
  reality)
    ask REALITY_SNI "REALITY SNI"
    ask REALITY_DEST "REALITY destination host"
    ;;
  web-grpc)
    ask VLESS_GRPC_BACKEND_PORT "Local Xray gRPC backend port"
    ask VLESS_GRPC_SERVICE "VLESS gRPC service name"
    ;;
  *) die "VLESS_MODE must be reality or web-grpc" ;;
esac

ask REALITY_FINGERPRINT "Client TLS fingerprint"
ask HY2_SNI "Hysteria2 certificate/SNI name"
ask WEB_DOMAIN "Website domain/SNI for web-grpc mode"
ask TLS_CERT_MODE "Shared TLS certificate mode (selfsigned or letsencrypt)"

case "$TLS_CERT_MODE" in
  letsencrypt)
    ask ACME_EMAIL "Let's Encrypt account email"
    WEB_ALLOW_INSECURE=0
    if ! command -v certbot >/dev/null 2>&1; then
      log "Installing certbot"
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
    fi
    ;;
  selfsigned)
    ask WEB_ALLOW_INSECURE "Allow self-signed TLS in generated web-grpc client link (1 or 0)"
    ;;
  *) die "TLS_CERT_MODE must be selfsigned or letsencrypt" ;;
esac

ask WEB_LOCAL_PORT "Internal camouflage website HTTP port"
ask HY2_MASQUERADE "Hysteria2 masquerade URL"

for p in "$PUBLIC_VLESS_PORT" "$PUBLIC_HY2_PORT" "$VLESS_LISTEN_PORT" "$HY2_LISTEN_PORT" "$VLESS_GRPC_BACKEND_PORT" "$WEB_LOCAL_PORT"; do
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "Invalid port: $p"
done

case "$REALITY_FINGERPRINT" in
  chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
  *) die "Invalid REALITY_FINGERPRINT. Use chrome, firefox, safari, ios, android, edge, 360, qq, random or randomized." ;;
esac

[[ "$WEB_ALLOW_INSECURE" == "0" || "$WEB_ALLOW_INSECURE" == "1" ]] || die "WEB_ALLOW_INSECURE must be 0 or 1"
[[ "$VLESS_GRPC_SERVICE" =~ ^[A-Za-z0-9._/-]+$ ]] || die "VLESS_GRPC_SERVICE contains unsupported characters"
[[ "$VLESS_GRPC_SERVICE" != /* && "$VLESS_GRPC_SERVICE" != */ ]] || die "VLESS_GRPC_SERVICE must not start or end with /"

if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
  [[ "$HY2_SNI" == "$WEB_DOMAIN" ]] || die "Let's Encrypt shared mode requires HY2_SNI and WEB_DOMAIN to be identical"
  [[ "$ACME_EMAIL" == *@*.* ]] || die "ACME_EMAIL must look like an email address"
fi

if [[ "$VLESS_MODE" == "web-grpc" ]]; then
  [[ "$VLESS_GRPC_BACKEND_PORT" != "$VLESS_LISTEN_PORT" ]] || die "VLESS_GRPC_BACKEND_PORT must differ from VLESS_LISTEN_PORT"
  [[ "$WEB_LOCAL_PORT" != "$VLESS_LISTEN_PORT" ]] || die "WEB_LOCAL_PORT must differ from VLESS_LISTEN_PORT"
fi

cat > "$ENV_FILE" <<EOF
XRAY_IMAGE=$XRAY_IMAGE
HYSTERIA_IMAGE=$HYSTERIA_IMAGE
NGINX_IMAGE=$NGINX_IMAGE
VLESS_MODE=$VLESS_MODE
VLESS_LISTEN_PORT=$VLESS_LISTEN_PORT
VLESS_GRPC_BACKEND_PORT=$VLESS_GRPC_BACKEND_PORT
VLESS_GRPC_SERVICE=$VLESS_GRPC_SERVICE
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
TLS_CERT_MODE=$TLS_CERT_MODE
ACME_EMAIL=$ACME_EMAIL
INITIAL_USER=$INITIAL_USER
EOF
chmod 600 "$ENV_FILE"

if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
  le_live_dir="/etc/letsencrypt/live/$WEB_DOMAIN"
  if [[ "$HY2_SNI" != "$old_hy2_sni" || "$WEB_DOMAIN" != "$old_web_domain" || "$TLS_CERT_MODE" != "$old_tls_cert_mode" || ! -f "$le_live_dir/fullchain.pem" || ! -f "$le_live_dir/privkey.pem" ]]; then
    warn "Requesting a public certificate requires $WEB_DOMAIN to resolve to this server and TCP/80 to be reachable from the Internet."
    generate_certificate
  else
    sync_letsencrypt_certificate
  fi
elif [[ "$HY2_SNI" != "$old_hy2_sni" || "$WEB_DOMAIN" != "$old_web_domain" || "$TLS_CERT_MODE" != "$old_tls_cert_mode" || ! -f "$VH_HOME/hysteria/certs/server.crt" ]]; then
  warn "TLS names or certificate mode changed; regenerating the shared Hysteria2/web certificate. Existing HY2 client pins will change."
  generate_certificate
fi

render_configs
validate_reality_target
validate_xray_config
validate_nginx_config
restart_stack

if [[ -f "$VH_HOME/systemd/vless-hysteria-cert-renew.service" && -f "$VH_HOME/systemd/vless-hysteria-cert-renew.timer" ]]; then
  install -m 0644 "$VH_HOME/systemd/vless-hysteria-cert-renew.service" /etc/systemd/system/vless-hysteria-cert-renew.service
  install -m 0644 "$VH_HOME/systemd/vless-hysteria-cert-renew.timer" /etc/systemd/system/vless-hysteria-cert-renew.timer
  systemctl daemon-reload
  if [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
    systemctl enable --now vless-hysteria-cert-renew.timer
  else
    systemctl disable --now vless-hysteria-cert-renew.timer >/dev/null 2>&1 || true
  fi
elif [[ "$TLS_CERT_MODE" == "letsencrypt" ]]; then
  warn "Certificate renewal timer files are not installed in $VH_HOME/systemd. Update the runtime files from the repository."
fi

if [[ "$VLESS_MODE" == "web-grpc" && "$TLS_CERT_MODE" == "selfsigned" && "$WEB_ALLOW_INSECURE" == "1" ]]; then
  warn "web-grpc is using a self-signed certificate, so the generated VLESS link disables certificate verification."
fi

printf '\nConfiguration applied.\n\n'
"$VH_HOME/status.sh" --brief
printf '\nRegenerate client links with:\n  sudo %s/user.sh links <username>\n' "$VH_HOME"
