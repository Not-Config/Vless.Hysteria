# Vless.Hysteria

Portable Docker-based VPN lab that deploys two independent transports on one Linux host:

- **VLESS + REALITY + XTLS Vision** over TCP
- **Hysteria2 + Salamander** over UDP

The project is designed for reproducible deployment on a clean Ubuntu/Debian VM or VPS. The installer generates all credentials locally on the target host, renders the service configs, starts Docker containers, installs a watchdog, and prints ready-to-import client links.

> No production secret, UUID, password, REALITY private key, or certificate key is stored in this repository.

## Why two transports?

TCP and UDP fail differently on real networks. Running VLESS/REALITY and Hysteria2 independently gives the client two paths without coupling their failure domains. Both may use port `443` at the same time because one listens on TCP and the other on UDP.

## Quick start

On a clean Ubuntu/Debian server:

```bash
git clone https://github.com/Not-Config/Vless.Hysteria.git
cd Vless.Hysteria
sudo ./install.sh
```

The interactive installer asks for the public host/ports and disguise/SNI values. It then:

1. installs Docker Engine + Compose if necessary;
2. generates a VLESS UUID and REALITY X25519 key pair;
3. generates a REALITY short ID;
4. generates a Hysteria2 Salamander secret;
5. generates a local TLS certificate for Hysteria2;
6. creates the initial `default` user for both transports;
7. renders Xray and Hysteria2 configuration;
8. starts both containers;
9. installs a systemd watchdog;
10. prints VLESS and HY2 import links.

Runtime state is stored in:

```text
/opt/vless-hysteria/
```

## Non-interactive install

Useful for VPS provisioning or a demonstration:

```bash
sudo PUBLIC_HOST=vpn.example.com \
  PUBLIC_VLESS_PORT=443 \
  PUBLIC_HY2_PORT=443 \
  REALITY_SNI=www.yandex.ru \
  HY2_SNI=vpn.example.com \
  ./install.sh --non-interactive
```

If the host sits behind NAT, `PUBLIC_VLESS_PORT` and `PUBLIC_HY2_PORT` are the **external** ports placed into generated client links. The services can still listen internally on `443`.

Example:

```text
Internet TCP :8443 -> server TCP :443 -> VLESS/REALITY
Internet UDP :8443 -> server UDP :443 -> Hysteria2
```

## Management

Show state:

```bash
sudo /opt/vless-hysteria/status.sh
```

Reconfigure public ports/SNI values:

```bash
sudo /opt/vless-hysteria/configure.sh
```

Manage users:

```bash
sudo /opt/vless-hysteria/user.sh list
sudo /opt/vless-hysteria/user.sh add user
sudo /opt/vless-hysteria/user.sh links user
sudo /opt/vless-hysteria/user.sh remove user
```

Create a backup:

```bash
sudo /opt/vless-hysteria/backup.sh
```

Run diagnostics:

```bash
sudo /opt/vless-hysteria/diagnostics.sh
```

Update pinned image versions after changing them in `/opt/vless-hysteria/.env`:

```bash
sudo /opt/vless-hysteria/update.sh
```

Uninstall:

```bash
sudo /opt/vless-hysteria/uninstall.sh
```

## Configuration model

Non-secret settings live in `/opt/vless-hysteria/.env`.

Important variables:

```dotenv
XRAY_IMAGE=ghcr.io/xtls/xray-core:26.9.8
HYSTERIA_IMAGE=tobyxdd/hysteria:v2.12.2

VLESS_LISTEN_PORT=443
HY2_LISTEN_PORT=443

PUBLIC_HOST=203.0.113.10
PUBLIC_VLESS_PORT=443
PUBLIC_HY2_PORT=443

REALITY_SNI=www.yandex.ru
REALITY_DEST=www.yandex.ru
HY2_SNI=vpn.example.invalid
HY2_MASQUERADE=https://www.yandex.ru/
```

Secrets are stored separately in `/opt/vless-hysteria/secrets.env` with mode `0600`. User credentials are stored in `/opt/vless-hysteria/users.json` with mode `0600`.

## Client links

The project generates both:

```text
vless://...
hy2://...
```

The HY2 link uses certificate SHA-256 pinning, which avoids publishing the private CA/certificate material and works with clients that support the standard Hysteria2 URI parameters.

## NAT / firewall

On a directly attached VPS, allow the selected ports through the provider firewall and local firewall.

For the default configuration:

```text
TCP/443 -> VLESS + REALITY
UDP/443 -> Hysteria2 + Salamander
```

For a home lab behind NAT, forward both protocols separately. TCP and UDP are independent even when the port number is identical.

## Watchdog

Docker already uses `restart: unless-stopped`. In addition, a systemd timer checks once per minute that:

- both containers are running;
- the VLESS TCP listener exists;
- the Hysteria2 UDP listener exists.

If a component is unhealthy, only that component is restarted/recreated.

Check it with:

```bash
systemctl status vless-hysteria-watchdog.timer
journalctl -u vless-hysteria-watchdog.service
```

## Migration to another VPS

A backup contains the runtime configuration, identities, users and TLS material. Treat it as a secret.

```bash
sudo /opt/vless-hysteria/backup.sh /root/vless-hysteria-backup.tar.gz
```

Copy the archive to the new server, clone this repository, run the installer, then restore the state or migrate the relevant `.env`, `secrets.env`, `users.json` and certificate files. Update `PUBLIC_HOST` and regenerate client links afterward.

## Notes

- The pinned image versions are the versions tested by this project. Change them deliberately, then run `update.sh`.
- A self-signed certificate is used for portable Hysteria2 deployment. Client links use SHA-256 certificate pinning. For a public production service you can replace it with a normal CA/ACME certificate.
- REALITY target choice matters. The installer validates that the configured target is reachable with TLS 1.3, but the operator is responsible for choosing a suitable target for the deployment network.
- Use the project only on systems and networks you are authorized to administer.
