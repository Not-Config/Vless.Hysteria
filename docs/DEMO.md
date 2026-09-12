# Classroom demo

This is a compact sequence for demonstrating reproducible deployment on a clean Ubuntu/Debian VM or VPS.

## 1. Clone and install

```bash
git clone https://github.com/Not-Config/Vless.Hysteria.git
cd Vless.Hysteria
sudo ./install.sh
```

During the interactive setup, specify the public IP/DNS name and public ports. On a directly attached VPS, the normal choice is TCP/443 for VLESS and UDP/443 for Hysteria2.

## 2. Show generated state

```bash
sudo /opt/vless-hysteria/status.sh
```

Expected result:

```text
Xray container:      OK
Hysteria2 container: OK
TCP/443:             LISTEN
UDP/443:             LISTEN
Watchdog timer:      OK
```

## 3. Show that configuration is parameterized

```bash
sudo /opt/vless-hysteria/configure.sh
```

Public ports, listen ports, REALITY target/SNI and Hysteria2 TLS/masquerade values can be changed without rebuilding the project.

## 4. Create a user

```bash
sudo /opt/vless-hysteria/user.sh add teacher
```

The command automatically:

- generates a new VLESS UUID;
- generates a Hysteria2 password;
- updates both server configs;
- validates Xray configuration;
- recreates the affected stack;
- prints ready-to-import `vless://` and `hy2://` links.

## 5. Demonstrate recovery

Kill Xray:

```bash
sudo docker kill vpn-xray
```

Docker should restore it automatically because the Compose policy is `restart: unless-stopped`.

Then show the second recovery layer:

```bash
sudo systemctl status vless-hysteria-watchdog.timer
sudo journalctl -u vless-hysteria-watchdog.service --no-pager
```

## 6. Reboot test

```bash
sudo reboot
```

After reconnecting:

```bash
sudo /opt/vless-hysteria/status.sh
```

Both containers and the watchdog should recover without manual startup.

## 7. Diagnostics

```bash
sudo /opt/vless-hysteria/diagnostics.sh
```

This prints system/network/container information and recent logs while deliberately omitting passwords, UUIDs, REALITY keys, short IDs and certificate pins.

## What this demonstrates

The important part of the exercise is not a manually configured one-off VPN host. It is a reproducible deployment with separated configuration, automatic credential generation, user management, container isolation, health recovery, diagnostics, backup and straightforward migration to another VPS.
