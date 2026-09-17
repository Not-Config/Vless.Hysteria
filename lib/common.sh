#!/usr/bin/env bash

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
ENV_FILE="$VH_HOME/.env"
SECRETS_FILE="$VH_HOME/secrets.env"
USERS_FILE="$VH_HOME/users.json"

log() {
  printf '[Vless.Hysteria] %s\n' "$*"
}

warn() {
  printf '[Vless.Hysteria] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[Vless.Hysteria] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this command as root (sudo)."
}

valid_username() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

load_state() {
  [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run install.sh first."
  [[ -f "$SECRETS_FILE" ]] || die "Missing $SECRETS_FILE. Run install.sh first."
  [[ -f "$USERS_FILE" ]] || die "Missing $USERS_FILE. Run install.sh first."

  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  # Backward-compatible defaults for older installations.
  VLESS_MODE="${VLESS_MODE:-reality}"
  if [[ "$VLESS_MODE" == "web-grpc" ]]; then
    VLESS_MODE="web-xhttp"
  fi

  VLESS_XHTTP_BACKEND_PORT="${VLESS_XHTTP_BACKEND_PORT:-${VLESS_GRPC_BACKEND_PORT:-10000}}"
  VLESS_XHTTP_PATH="${VLESS_XHTTP_PATH:-/${VLESS_GRPC_SERVICE:-api/v1/stream}}"
  [[ "$VLESS_XHTTP_PATH" == /* ]] || VLESS_XHTTP_PATH="/$VLESS_XHTTP_PATH"
  VLESS_XHTTP_PATH="${VLESS_XHTTP_PATH%/}"

  # Compatibility aliases for older helper scripts/runtime files.
  VLESS_GRPC_BACKEND_PORT="$VLESS_XHTTP_BACKEND_PORT"
  VLESS_GRPC_SERVICE="${VLESS_XHTTP_PATH#/}"

  REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}"
  WEB_LOCAL_PORT="${WEB_LOCAL_PORT:-8080}"
  WEB_DOMAIN="${WEB_DOMAIN:-${HY2_SNI:-vpn.example.invalid}}"
  WEB_ALLOW_INSECURE="${WEB_ALLOW_INSECURE:-1}"
  CAMOUFLAGE_MODE="${CAMOUFLAGE_MODE:-local}"
  CAMOUFLAGE_UPSTREAM="${CAMOUFLAGE_UPSTREAM:-https://prime-top.ru}"
  NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.30.4-alpine}"
  TLS_CERT_MODE="${TLS_CERT_MODE:-selfsigned}"
  ACME_EMAIL="${ACME_EMAIL:-}"
}

update_certificate_fingerprint() {
  HY2_CERT_SHA256="$(
    openssl x509 \
      -in "$VH_HOME/hysteria/certs/server.crt" \
      -noout \
      -fingerprint \
      -sha256 |
      cut -d= -f2 |
      tr -d ':' |
      tr '[:upper:]' '[:lower:]'
  )"

  if grep -q '^HY2_CERT_SHA256=' "$SECRETS_FILE"; then
    sed -i "s/^HY2_CERT_SHA256=.*/HY2_CERT_SHA256=$HY2_CERT_SHA256/" "$SECRETS_FILE"
  else
    printf 'HY2_CERT_SHA256=%s\n' "$HY2_CERT_SHA256" >> "$SECRETS_FILE"
  fi
  chmod 600 "$SECRETS_FILE"
}

sync_letsencrypt_certificate() {
  load_state
  local live_dir="/etc/letsencrypt/live/$WEB_DOMAIN"

  [[ -f "$live_dir/fullchain.pem" ]] || die "Missing Let's Encrypt certificate: $live_dir/fullchain.pem"
  [[ -f "$live_dir/privkey.pem" ]] || die "Missing Let's Encrypt private key: $live_dir/privkey.pem"

  mkdir -p "$VH_HOME/hysteria/certs"
  install -m 0644 "$live_dir/fullchain.pem" "$VH_HOME/hysteria/certs/server.crt"
  install -m 0600 "$live_dir/privkey.pem" "$VH_HOME/hysteria/certs/server.key"
  update_certificate_fingerprint
}

generate_certificate() {
  load_state
  mkdir -p "$VH_HOME/hysteria/certs"

  case "$TLS_CERT_MODE" in
    letsencrypt)
      [[ "$HY2_SNI" == "$WEB_DOMAIN" ]] || die "Let's Encrypt shared mode requires HY2_SNI and WEB_DOMAIN to be the same domain"
      [[ -n "$ACME_EMAIL" ]] || die "ACME_EMAIL is required for Let's Encrypt mode"
      command -v certbot >/dev/null 2>&1 || die "certbot is not installed"

      if python3 - "$WEB_DOMAIN" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
      then
        die "Let's Encrypt mode requires a DNS name, not an IP address"
      fi

      if [[ ! -f "/etc/letsencrypt/live/$WEB_DOMAIN/fullchain.pem" ]]; then
        log "Requesting Let's Encrypt certificate for $WEB_DOMAIN"
        log "TCP/80 must reach this server and the domain must already resolve to its public IP"
        certbot certonly \
          --standalone \
          --non-interactive \
          --agree-tos \
          --preferred-challenges http \
          --email "$ACME_EMAIL" \
          -d "$WEB_DOMAIN"
      else
        log "Using existing Let's Encrypt certificate for $WEB_DOMAIN"
      fi

      sync_letsencrypt_certificate
      ;;

    selfsigned)
      local san
      san="$(python3 - "$HY2_SNI" "$WEB_DOMAIN" <<'PY'
import ipaddress, sys

values = []
for value in sys.argv[1:]:
    if value in values:
        continue
    values.append(value)

parts = []
for value in values:
    try:
        ipaddress.ip_address(value)
        parts.append(f"IP:{value}")
    except ValueError:
        parts.append(f"DNS:{value}")

print(",".join(parts))
PY
)"

      log "Generating shared self-signed TLS certificate for Hysteria2/web: $HY2_SNI, $WEB_DOMAIN"
      openssl req \
        -x509 \
        -newkey rsa:3072 \
        -sha256 \
        -nodes \
        -days "${HY2_CERT_DAYS:-3650}" \
        -keyout "$VH_HOME/hysteria/certs/server.key" \
        -out "$VH_HOME/hysteria/certs/server.crt" \
        -subj "/CN=$HY2_SNI" \
        -addext "subjectAltName=$san" \
        >/dev/null 2>&1

      chmod 600 "$VH_HOME/hysteria/certs/server.key"
      chmod 644 "$VH_HOME/hysteria/certs/server.crt"
      update_certificate_fingerprint
      ;;

    *)
      die "TLS_CERT_MODE must be selfsigned or letsencrypt"
      ;;
  esac
}

render_configs() {
  load_state

  mkdir -p "$VH_HOME/xray" "$VH_HOME/hysteria" "$VH_HOME/web/html"

  local vless_clients hy2_users xray_template nginx_template
  if [[ "$VLESS_MODE" == "web-xhttp" ]]; then
    vless_clients="$(
      jq -c '[.[] | {id: .vless_uuid, email: .name}]' "$USERS_FILE"
    )"
    xray_template="$VH_HOME/templates/xray-xhttp.json.tpl"

    case "$CAMOUFLAGE_MODE" in
      local)
        nginx_template="$VH_HOME/templates/nginx-xhttp.conf.tpl"
        ;;
      reverse-proxy)
        nginx_template="$VH_HOME/templates/nginx-xhttp-reverse-proxy.conf.tpl"
        ;;
      *)
        die "CAMOUFLAGE_MODE must be local or reverse-proxy"
        ;;
    esac
  else
    vless_clients="$(
      jq -c '[.[] | {id: .vless_uuid, flow: "xtls-rprx-vision", email: .name}]' "$USERS_FILE"
    )"
    xray_template="$VH_HOME/templates/xray.json.tpl"
    nginx_template="$VH_HOME/templates/nginx-local.conf.tpl"
  fi

  [[ -f "$nginx_template" ]] || die "Missing nginx template: $nginx_template"

  hy2_users="$(
    jq -r '.[] | "    " + .name + ": \"" + .hy2_password + "\""' "$USERS_FILE"
  )"

  export R_VLESS_LISTEN_PORT="$VLESS_LISTEN_PORT"
  export R_VLESS_XHTTP_BACKEND_PORT="$VLESS_XHTTP_BACKEND_PORT"
  export R_VLESS_XHTTP_PATH="$VLESS_XHTTP_PATH"
  export R_VLESS_CLIENTS_JSON="$vless_clients"
  export R_REALITY_DEST="$REALITY_DEST"
  export R_REALITY_SNI="$REALITY_SNI"
  export R_REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
  export R_REALITY_SHORT_ID="$REALITY_SHORT_ID"
  export R_HY2_LISTEN_PORT="$HY2_LISTEN_PORT"
  export R_HY2_USERPASS_YAML="$hy2_users"
  export R_HY2_MASQUERADE="$HY2_MASQUERADE"
  export R_WEB_LOCAL_PORT="$WEB_LOCAL_PORT"
  export R_WEB_DOMAIN="$WEB_DOMAIN"
  export R_CAMOUFLAGE_UPSTREAM="$CAMOUFLAGE_UPSTREAM"

  python3 - "$xray_template" "$VH_HOME/xray/config.json" <<'PY'
import os, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:3])
s = src.read_text()
repl = {
    "__VLESS_LISTEN_PORT__": os.environ["R_VLESS_LISTEN_PORT"],
    "__VLESS_XHTTP_BACKEND_PORT__": os.environ["R_VLESS_XHTTP_BACKEND_PORT"],
    "__VLESS_XHTTP_PATH__": os.environ["R_VLESS_XHTTP_PATH"],
    "__VLESS_CLIENTS_JSON__": os.environ["R_VLESS_CLIENTS_JSON"],
    "__REALITY_DEST__": os.environ["R_REALITY_DEST"],
    "__REALITY_SNI__": os.environ["R_REALITY_SNI"],
    "__REALITY_PRIVATE_KEY__": os.environ["R_REALITY_PRIVATE_KEY"],
    "__REALITY_SHORT_ID__": os.environ["R_REALITY_SHORT_ID"],
}
for old, new in repl.items():
    s = s.replace(old, new)
dst.write_text(s)
PY

  python3 - "$VH_HOME/templates/hysteria.yaml.tpl" "$VH_HOME/hysteria/config.yaml" <<'PY'
import os, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:3])
s = src.read_text()
repl = {
    "__HY2_LISTEN_PORT__": os.environ["R_HY2_LISTEN_PORT"],
    "__HY2_USERPASS_YAML__": os.environ["R_HY2_USERPASS_YAML"],
    "__HY2_MASQUERADE__": os.environ["R_HY2_MASQUERADE"],
}
for old, new in repl.items():
    s = s.replace(old, new)
dst.write_text(s)
PY

  python3 - "$nginx_template" "$VH_HOME/web/nginx.conf" <<'PY'
import os, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:3])
s = src.read_text()
repl = {
    "__VLESS_LISTEN_PORT__": os.environ["R_VLESS_LISTEN_PORT"],
    "__VLESS_XHTTP_BACKEND_PORT__": os.environ["R_VLESS_XHTTP_BACKEND_PORT"],
    "__VLESS_XHTTP_PATH__": os.environ["R_VLESS_XHTTP_PATH"],
    "__WEB_LOCAL_PORT__": os.environ["R_WEB_LOCAL_PORT"],
    "__WEB_DOMAIN__": os.environ["R_WEB_DOMAIN"],
    "__CAMOUFLAGE_UPSTREAM__": os.environ["R_CAMOUFLAGE_UPSTREAM"],
}
for old, new in repl.items():
    s = s.replace(old, new)
dst.write_text(s)
PY

  chmod 600 "$VH_HOME/xray/config.json" "$VH_HOME/hysteria/config.yaml" "$VH_HOME/web/nginx.conf"
}

validate_xray_config() {
  load_state
  docker run --rm \
    --user 0:0 \
    -v "$VH_HOME/xray/config.json:/usr/local/etc/xray/config.json:ro" \
    "$XRAY_IMAGE" \
    run -test -config /usr/local/etc/xray/config.json
}

validate_nginx_config() {
  load_state
  docker run --rm \
    --network host \
    -v "$VH_HOME/web/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$VH_HOME/web/html:/usr/share/nginx/html:ro" \
    -v "$VH_HOME/hysteria/certs:/etc/nginx/tls:ro" \
    "$NGINX_IMAGE" \
    nginx -t
}

validate_reality_target() {
  load_state
  [[ "$VLESS_MODE" == "reality" ]] || return 0

  if timeout 10 openssl s_client \
      -connect "$REALITY_DEST:443" \
      -servername "$REALITY_SNI" \
      -tls1_3 </dev/null 2>/dev/null |
      grep -q 'TLSv1.3'; then
    log "REALITY target supports TLS 1.3: $REALITY_DEST"
  else
    warn "Could not confirm TLS 1.3 on REALITY target $REALITY_DEST."
  fi
}

restart_stack() {
  load_state
  (
    cd "$VH_HOME"
    docker compose down >/dev/null 2>&1 || true
    docker compose up -d
  )
}

print_user_links() {
  load_state
  local user="${1:?user required}"
  valid_username "$user" || die "Invalid username: $user"

  local row uuid hy2_password
  row="$(jq -c --arg u "$user" '.[] | select(.name == $u)' "$USERS_FILE" | head -n1)"
  [[ -n "$row" ]] || die "Unknown user: $user"

  uuid="$(jq -r '.vless_uuid' <<<"$row")"
  hy2_password="$(jq -r '.hy2_password' <<<"$row")"

  python3 - \
    "$VLESS_MODE" \
    "$PUBLIC_HOST" \
    "$PUBLIC_VLESS_PORT" \
    "$PUBLIC_HY2_PORT" \
    "$user" \
    "$uuid" \
    "$hy2_password" \
    "$REALITY_SNI" \
    "$REALITY_FINGERPRINT" \
    "$REALITY_PUBLIC_KEY" \
    "$REALITY_SHORT_ID" \
    "$HY2_SNI" \
    "$HY2_CERT_SHA256" \
    "$WEB_DOMAIN" \
    "$WEB_ALLOW_INSECURE" \
    "$VLESS_XHTTP_PATH" \
    "$TLS_CERT_MODE" <<'PY'
import sys
from urllib.parse import quote, urlencode
(
    mode, host, vport, hport, user, uuid, hy2_password, reality_sni,
    reality_fp, reality_public, short_id, hy2_sni, cert_pin, web_domain,
    web_allow_insecure, xhttp_path, tls_cert_mode
) = sys.argv[1:]

if mode == "web-xhttp":
    v_query = {
        "encryption": "none",
        "security": "tls",
        "sni": web_domain,
        "fp": reality_fp,
        "alpn": "h2",
        "type": "xhttp",
        "host": web_domain,
        "path": xhttp_path,
        "mode": "stream-up",
    }
    if tls_cert_mode != "letsencrypt" and web_allow_insecure == "1":
        v_query["allowInsecure"] = "1"
    vless_name = "VLESS-XHTTP-" + user
else:
    v_query = {
        "encryption": "none",
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "sni": reality_sni,
        "fp": reality_fp,
        "pbk": reality_public,
        "sid": short_id,
        "type": "tcp",
    }
    vless_name = "VLESS-REALITY-" + user

vless = f"vless://{uuid}@{host}:{vport}?{urlencode(v_query)}#{quote(vless_name)}"

hy2_auth = f"{quote(user, safe='')}:{quote(hy2_password, safe='')}"
h_query = {"sni": hy2_sni}
if tls_cert_mode != "letsencrypt" and cert_pin:
    h_query["pinSHA256"] = cert_pin
hy2 = f"hy2://{hy2_auth}@{host}:{hport}/?{urlencode(h_query)}#{quote('HY2-' + user)}"

print("VLESS:")
print(vless)
print()
print("Hysteria2:")
print(hy2)
PY
}
