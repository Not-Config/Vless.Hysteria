#!/usr/bin/env bash
set -Eeuo pipefail

VH_HOME="${VH_HOME:-/opt/vless-hysteria}"
# shellcheck disable=SC1091
source "$VH_HOME/lib/common.sh"
require_root
load_state

old_hy2_sni="$HY2_SNI"

ask() {
  local var="$1" label="$2" current="${!var}"
  local value
  read -r -p "$label [$current]: " value
  printf -v "$var" '%s' "${value:-$current}"
}

printf 'Reconfigure Vless.Hysteria\n'
printf 'Press Enter to keep the current value.\n\n'

ask PUBLIC_HOST "Public IP/DNS used in client links"
ask PUBLIC_VLESS_PORT "Public VLESS TCP port"
ask PUBLIC_HY2_PORT "Public Hysteria2 UDP port"
ask VLESS_LISTEN_PORT "VLESS TCP listen port"
ask HY2_LISTEN_PORT "Hysteria2 UDP listen port"
ask REALITY_SNI "REALITY SNI"
ask REALITY_DEST "REALITY destination host"
ask HY2_SNI "Hysteria2 certificate/SNI name"
ask HY2_MASQUERADE "Hysteria2 masquerade URL"

for p in "$PUBLIC_VLESS_PORT" "$PUBLIC_HY2_PORT" "$VLESS_LISTEN_PORT" "$HY2_LISTEN_PORT"; do
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "Invalid port: $p"
done

cat > "$ENV_FILE" <<EOF
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
chmod 600 "$ENV_FILE"

if [[ "$HY2_SNI" != "$old_hy2_sni" ]]; then
  warn "HY2_SNI changed; regenerating the self-signed certificate. Existing HY2 client pins will change."
  generate_certificate
fi

render_configs
validate_reality_target
validate_xray_config
restart_stack

printf '\nConfiguration applied.\n\n'
"$VH_HOME/status.sh" --brief
printf '\nRegenerate client links with:\n  sudo %s/user.sh links <username>\n' "$VH_HOME"
