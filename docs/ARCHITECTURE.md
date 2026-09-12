# Architecture

## Goal

The stack keeps the two client transports independent while sharing one Linux host and one Docker deployment.

```text
                         Internet
                            |
              +-------------+-------------+
              |                           |
         TCP public port              UDP public port
              |                           |
              v                           v
        +-----------+               +-------------+
        | Xray-core |               | Hysteria2   |
        | VLESS     |               | QUIC        |
        | REALITY   |               | Salamander  |
        +-----------+               +-------------+
              |                           |
              +-------------+-------------+
                            |
                         Internet
```

TCP and UDP can both use port `443` because they are different transport protocols.

## Components

### Xray-core

Provides:

- VLESS authentication;
- `xtls-rprx-vision` flow;
- REALITY TLS camouflage;
- direct outbound traffic.

The container is configured with host networking and only `NET_BIND_SERVICE` after dropping all other Linux capabilities.

### Hysteria2

Provides:

- QUIC/UDP transport;
- Salamander obfuscation;
- per-user `userpass` authentication;
- HTTPS masquerading;
- certificate SHA-256 pinning for portable self-signed TLS.

### Docker Compose

Both services use `restart: unless-stopped`. Generated runtime configuration is mounted read-only into the containers.

### systemd watchdog

Docker restart policy handles ordinary process exits. The watchdog adds a second recovery layer and checks once per minute that:

- `vpn-xray` is running;
- the VLESS TCP port is listening;
- `vpn-hysteria` is running;
- the Hysteria2 UDP port is listening.

If one service is unhealthy, only that service is restarted.

## Configuration separation

Runtime state lives under `/opt/vless-hysteria`:

```text
/opt/vless-hysteria/
├── .env                 # non-secret deployment settings
├── secrets.env          # REALITY/Salamander/certificate data
├── users.json           # per-user credentials
├── compose.yml
├── xray/config.json     # generated
├── hysteria/config.yaml # generated
└── hysteria/certs/      # generated TLS material
```

The source repository contains templates, never generated credentials.

## NAT model

The public ports placed in client links are deliberately separate from the server listen ports.

A home-lab example:

```text
Public TCP :8443  -> NAT -> server TCP :443 -> VLESS
Public UDP :8443  -> NAT -> server UDP :443 -> Hysteria2
```

A VPS can normally use direct `443/TCP` and `443/UDP` without this translation.

## Failure domains

The design avoids making one proxy process responsible for both transports.

- Xray failure does not stop Hysteria2.
- Hysteria2 failure does not stop Xray.
- TCP filtering does not automatically imply UDP failure.
- UDP filtering does not automatically imply TCP failure.
- Container crashes are recovered by Docker.
- Listener/container failures are additionally checked by systemd.
- Complete host/provider failure still requires another server for true high availability.

## Migration

The deployment is intentionally host-independent. A new server needs Docker plus the runtime state. For a fresh identity, simply rerun `install.sh`; for identity-preserving migration, move a protected backup and update the public address before regenerating client links.
