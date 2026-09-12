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
}

generate_certificate() {
  load_state
  mkdir -p "$VH_HOME/hysteria/certs"

  local san
  if python3 - "$HY2_SNI" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
  then
    san="IP:$HY2_SNI"
  else
    san="DNS:$HY2_SNI"
  fi

  log "Generating Hysteria2 TLS certificate for $HY2_SNI"
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

render_configs() {
  load_state

  mkdir -p "$VH_HOME/xray" "$VH_HOME/hysteria"

  local vless_clients hy2_users
  vless_clients="$(
    jq -c '[.[] | {id: .vless_uuid, flow: "xtls-rprx-vision", email: .name}]' "$USERS_FILE"
  )"

  hy2_users="$(
    jq -r '.[] | "    " + .name + ": \"" + .hy2_password + "\""' "$USERS_FILE"
  )"

  export R_VLESS_LISTEN_PORT="$VLESS_LISTEN_PORT"
  export R_VLESS_CLIENTS_JSON="$vless_clients"
  export R_REALITY_DEST="$REALITY_DEST"
  export R_REALITY_SNI="$REALITY_SNI"
  export R_REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
  export R_REALITY_SHORT_ID="$REALITY_SHORT_ID"
  export R_HY2_LISTEN_PORT="$HY2_LISTEN_PORT"
  export R_HY2_USERPASS_YAML="$hy2_users"
  export R_HY2_MASQUERADE="$HY2_MASQUERADE"

  python3 - "$VH_HOME/templates/xray.json.tpl" "$VH_HOME/xray/config.json" <<'PY'
import os, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:3])
s = src.read_text()
repl = {
    "__VLESS_LISTEN_PORT__": os.environ["R_VLESS_LISTEN_PORT"],
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

  chmod 600 "$VH_HOME/xray/config.json" "$VH_HOME/hysteria/config.yaml"
}

validate_xray_config() {
  load_state
  docker run --rm \
    --user 0:0 \
    -v "$VH_HOME/xray/config.json:/usr/local/etc/xray/config.json:ro" \
    "$XRAY_IMAGE" \
    run -test -config /usr/local/etc/xray/config.json
}

validate_reality_target() {
  load_state
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
  (cd "$VH_HOME" && docker compose up -d --force-recreate)
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
    "$PUBLIC_HOST" \
    "$PUBLIC_VLESS_PORT" \
    "$PUBLIC_HY2_PORT" \
    "$user" \
    "$uuid" \
    "$hy2_password" \
    "$REALITY_SNI" \
    "$REALITY_PUBLIC_KEY" \
    "$REALITY_SHORT_ID" \
    "$HY2_SNI" \
    "$HY2_CERT_SHA256" <<'PY'
import sys
from urllib.parse import quote, urlencode
(
    host, vport, hport, user, uuid, hy2_password, reality_sni,
    reality_public, short_id, hy2_sni, cert_pin
) = sys.argv[1:]

v_query = urlencode({
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": reality_sni,
    "fp": "chrome",
    "pbk": reality_public,
    "sid": short_id,
    "type": "tcp",
})
vless = f"vless://{uuid}@{host}:{vport}?{v_query}#{quote('VLESS-' + user)}"

hy2_auth = f"{quote(user, safe='')}:{quote(hy2_password, safe='')}"
h_query = urlencode({
    "sni": hy2_sni,
    "pinSHA256": cert_pin,
})
hy2 = f"hy2://{hy2_auth}@{host}:{hport}/?{h_query}#{quote('HY2-' + user)}"

print("VLESS:")
print(vless)
print()
print("Hysteria2:")
print(hy2)
PY
}
