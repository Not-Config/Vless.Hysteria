# Architecture

## Goal

The stack keeps TCP and UDP transports independent while allowing them to present one coherent public website identity.

In `web-grpc` mode the preferred public layout is:

```text
                         vpn.example.com
                               |
                 +-------------+-------------+
                 |                           |
              TCP/443                     UDP/443
                 |                           |
               nginx                     Hysteria2
                 |                           |
          HTTPS + gRPC                  QUIC/HTTP3
            /       \                       |
       website      Xray               masquerade
                      |                     |
                    VLESS             local website
```

TCP and UDP may both use port `443` because they are different transport protocols.

## VLESS modes

### REALITY mode

```text
TCP/443 -> Xray -> VLESS + REALITY + XTLS Vision
```

This keeps the original design: Xray owns the public TCP listener and uses a configurable REALITY target, SNI and client TLS fingerprint.

### Web + gRPC mode

```text
TCP/443 -> nginx
             |-- /                     -> ordinary website
             `-- /api/v1/stream/...    -> local Xray gRPC backend
```

Xray listens only on a loopback backend port. nginx terminates normal TLS and routes the configured gRPC path to Xray while serving all other requests as a real website.

## Hysteria2

Hysteria2 provides:

- QUIC/UDP transport;
- native HTTP/3-compatible behavior without Salamander;
- per-user `userpass` authentication;
- HTTP/3 masquerading through a reverse proxy;
- either certificate pinning for lab certificates or normal CA validation for a public certificate.

The default masquerade upstream is the local nginx website, so an ordinary HTTP/3 request and an ordinary HTTPS request can return the same site content.

## Shared TLS identity

nginx and Hysteria2 mount the same certificate directory:

```text
/opt/vless-hysteria/hysteria/certs/server.crt
/opt/vless-hysteria/hysteria/certs/server.key
```

Two certificate modes are supported.

### `selfsigned`

A local RSA certificate is generated with SAN entries for the configured Hysteria2 and website names. Hysteria client links include `pinSHA256`; web-gRPC links can use `allowInsecure=1` for lab use.

### `letsencrypt`

`HY2_SNI` and `WEB_DOMAIN` must be the same real DNS name. Certbot obtains an HTTP-01 certificate, requiring public TCP/80 to reach the server during validation. The same public certificate is copied into the shared certificate directory and used by both nginx and Hysteria2.

With a publicly trusted certificate:

- VLESS web-gRPC links do not use `allowInsecure`;
- Hysteria2 links do not pin the leaf certificate, so normal renewal does not break clients;
- a daily systemd timer checks Certbot renewal and recreates only nginx and Hysteria2 when the certificate changes.

This produces a consistent public identity across TCP/HTTPS and UDP/HTTP3. It does not imply that a network allow-list will permit the traffic: a filter can still make separate decisions based on destination IP, ASN, protocol, UDP availability and other signals.

## Docker Compose

The deployment contains three containers:

- `vpn-xray`;
- `vpn-hysteria`;
- `vpn-web`.

Generated runtime configuration is mounted read-only. The shared TLS directory is mounted read-only into both the Hysteria2 and nginx containers.

## systemd timers

The watchdog checks once per minute that the required containers and listeners are alive.

When `TLS_CERT_MODE=letsencrypt`, a second timer runs the certificate renewal helper daily. If the deployed certificate changed, it recreates only `vpn-web` and `vpn-hysteria` so both processes load the new certificate.

## Runtime state

Runtime state lives under `/opt/vless-hysteria`:

```text
/opt/vless-hysteria/
├── .env
├── secrets.env
├── users.json
├── compose.yml
├── xray/config.json
├── hysteria/config.yaml
├── hysteria/certs/
├── web/nginx.conf
└── web/html/
```

Certbot account and renewal state remains under `/etc/letsencrypt` and is not stored in the repository.

## NAT model

Public client ports are separate from local listener ports. A home-lab example is:

```text
Public TCP :8443  -> NAT -> server TCP :443
Public UDP :8443  -> NAT -> server UDP :443
```

For Let's Encrypt HTTP-01, public TCP/80 must additionally reach the server during certificate validation and renewal.

## Failure domains

- Xray failure does not stop Hysteria2.
- Hysteria2 failure does not stop Xray.
- nginx and Hysteria2 share certificate identity but remain separate processes.
- TCP filtering does not automatically imply UDP failure.
- UDP filtering does not automatically imply TCP failure.
- Docker handles ordinary process restarts.
- systemd watchdog checks listeners and containers.
- complete host/provider failure still requires another server for true high availability.
