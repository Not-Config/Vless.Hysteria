# Architecture

## Goal

The stack keeps TCP-based VLESS and UDP-based Hysteria2 independent while sharing one Linux host and one Docker deployment.

TCP and UDP can both use port `443` because they are different transport protocols.

## VLESS modes

### REALITY mode

```text
Internet
   |
TCP public port
   |
   v
+-----------+
| Xray-core |
| VLESS     |
| REALITY   |
+-----------+
```

Xray owns the public TCP listener directly. It uses `xtls-rprx-vision`, a configurable REALITY SNI/target and a configurable ClientHello fingerprint.

### Web + gRPC mode

```text
                         TCP public port
                               |
                               v
                           +-------+
                           | nginx |
                           +-------+
                           /       \
                          /         \
                 normal HTTPS     /api/v1/stream/*
                    website              |
                                         v
                                  gRPC over h2c
                                         |
                                         v
                                      +------+
                                      | Xray |
                                      | VLESS|
                                      +------+
```

nginx owns the public TCP listener and terminates TLS. Normal paths are served as a static website. Only the configured gRPC path is proxied to Xray on a localhost-only backend port.

The generated lab certificate is shared by nginx and Hysteria2. It is self-signed for portability. A public deployment should use a certificate from a publicly trusted CA.

This mode can also be used to study allow-list behavior when the website uses a domain controlled by the operator that is actually allowed by the tested network. A matching SNI alone is not assumed to guarantee passage because filtering can also consider the destination IP, ASN and other signals.

## Hysteria2

```text
Internet
   |
UDP public port
   |
   v
+-------------+
| Hysteria2   |
| QUIC/HTTP3  |
+-------------+
   |
   | unauthenticated HTTP/3 request
   v
local nginx website on 127.0.0.1:8080
```

Hysteria2 uses standard QUIC/HTTP/3 without Salamander. Its default masquerade proxies to the local website so active HTTP/3 requests receive real content instead of a fixed proxy error page.

## Components

### Xray-core

Provides VLESS authentication and either:

- REALITY + XTLS Vision on the public TCP listener; or
- a localhost-only gRPC backend behind nginx.

### nginx

Provides the camouflage website. In `reality` mode it only listens on the local website port used by Hysteria2. In `web-grpc` mode it additionally owns the public HTTPS listener and routes the configured gRPC path to Xray.

### Hysteria2

Provides QUIC/UDP transport, per-user authentication, normal HTTP/3-compatible behavior and certificate pinning for the generated lab certificate.

### Docker Compose

The three containers use host networking and `restart: unless-stopped`. Generated runtime configuration is mounted read-only.

### systemd watchdog

The watchdog checks once per minute that Xray, Hysteria2 and nginx are running and that the mode-specific listeners exist. In `web-grpc` mode it checks both the public nginx TCP listener and Xray's local gRPC backend.

## Runtime state

```text
/opt/vless-hysteria/
├── .env
├── secrets.env
├── users.json
├── compose.yml
├── xray/config.json
├── hysteria/config.yaml
├── hysteria/certs/
└── web/
    ├── nginx.conf
    └── html/index.html
```

The source repository contains templates, not generated credentials.

## NAT model

Public ports in client links are separate from server listen ports.

```text
Public TCP :8443 -> NAT -> server TCP :443
Public UDP :8443 -> NAT -> server UDP :443
```

## Failure domains

- Xray failure does not stop Hysteria2.
- Hysteria2 failure does not stop the TCP path.
- TCP filtering does not automatically imply UDP failure.
- UDP filtering does not automatically imply TCP failure.
- Docker and the watchdog recover ordinary process/listener failures.
- Complete host/provider failure still requires another server for real high availability.
