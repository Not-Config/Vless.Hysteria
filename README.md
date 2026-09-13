# Vless.Hysteria

Небольшой проект для быстрого развёртывания VPN-сервера на Ubuntu или Debian.

Он автоматически поднимает:

- **VLESS** по TCP;
- **Hysteria2** по UDP/QUIC;
- небольшой обычный веб-сайт через nginx.

Главная идея проекта — развернуть одинаковую конфигурацию почти одной командой и не собирать всё вручную перед каждой демонстрацией.

## Быстрая установка

```bash
git clone https://github.com/Not-Config/Vless.Hysteria.git
cd Vless.Hysteria
sudo ./install.sh
```

Скрипт установит Docker, Certbot, скачает контейнеры, сгенерирует ключи и пользователей, соберёт конфиги, запустит сервисы и выведет готовые клиентские ссылки.

Рабочая директория после установки:

```text
/opt/vless-hysteria/
```

## Два режима VLESS

Во время установки можно выбрать `VLESS_MODE`.

### `reality`

Это прежний режим проекта:

```text
TCP/443 -> Xray -> VLESS + REALITY + XTLS Vision
UDP/443 -> Hysteria2
```

Для REALITY настраиваются `REALITY_SNI`, `REALITY_DEST` и TLS ClientHello fingerprint. REALITY-target должен быть настоящим TLS 1.3-сайтом. Скрипт проверяет TLS 1.3 перед запуском.

Этот режим удобен для экспериментов с тем, как сеть классифицирует соединение по destination IP, SNI и TLS-профилю. Один только SNI не гарантирует прохождение фильтра: оператор может учитывать IP, ASN и другие признаки.

### `web-xhttp`

Это основной web-режим проекта. Старый `web-grpc` автоматически мигрируется в него при загрузке существующей конфигурации.

```text
                    TCP/443
                       |
                     nginx
                    /     \
                   /       \
          обычный сайт    /api/v1/stream/*
                              |
                       XHTTP stream-up
                           HTTP/2
                              |
                            Xray
                              |
                            VLESS
```

Xray слушает только локальный backend-порт, по умолчанию `127.0.0.1:10000`. nginx принимает HTTPS и маршрутизирует путь `/api/v1/stream/...` в Xray, остальные URL открывают обычный сайт.

XHTTP используется вместо отдельного gRPC transport, потому что актуальный Xray помечает gRPC transport deprecated и рекомендует XHTTP. Для TLS/H2 XHTTP по умолчанию ориентирован на `stream-up`; в проекте этот режим фиксируется явно. На внешнем соединении остаётся обычный TLS с реальным сертификатом сайта.

Основные параметры:

```text
VLESS_MODE=web-xhttp
VLESS_XHTTP_BACKEND_PORT=10000
VLESS_XHTTP_PATH=/api/v1/stream
```

Для клиента генерируется VLESS-ссылка с `type=xhttp`, `mode=stream-up`, `path`, `host`, `sni` и `alpn=h2`.

## Один домен и один сертификат для сайта и Hysteria2

nginx и Hysteria2 используют один и тот же каталог сертификата. Есть два режима:

```text
TLS_CERT_MODE=selfsigned
```

подходит для лаборатории. Hysteria2 получает `pinSHA256`, а для `web-xhttp` при необходимости используется `allowInsecure=1`.

Для публичного сервера можно выбрать:

```text
TLS_CERT_MODE=letsencrypt
```

Тогда `HY2_SNI` и `WEB_DOMAIN` должны быть одинаковым реальным доменом, например:

```text
HY2_SNI=vpn.example.com
WEB_DOMAIN=vpn.example.com
TLS_CERT_MODE=letsencrypt
ACME_EMAIL=admin@example.com
```

Перед выпуском сертификата домен уже должен указывать на публичный IP сервера, а входящий `TCP/80` должен доходить до этого сервера. Certbot использует HTTP-01.

После получения сертификата одна и та же публично доверенная TLS-пара используется одновременно:

```text
                       vpn.example.com
                              |
                +-------------+-------------+
                |                           |
             TCP/443                     UDP/443
                |                           |
              nginx                     Hysteria2
                |                           |
          обычный HTTPS              QUIC / HTTP/3
          + VLESS XHTTP                  |
                |                    masquerade
                +-----------+-----------+
                            |
                      один и тот же сайт
```

В режиме Let's Encrypt клиентская ссылка Hysteria2 не привязывается к SHA-256 конкретного сертификата, поэтому обычное продление сертификата не ломает клиента. Для VLESS `web-xhttp` также не добавляется `allowInsecure`.

Проект устанавливает отдельный systemd timer, который раз в сутки запускает проверку продления Certbot. Если сертификат реально изменился, Hysteria2 и nginx автоматически перечитывают его после пересоздания контейнеров.

Проверить таймер:

```bash
systemctl status vless-hysteria-cert-renew.timer
```

## Hysteria2

Hysteria2 работает на UDP/443 и использует обычный QUIC/HTTP/3 без Salamander.

По умолчанию её `masquerade` указывает на локальный сайт nginx:

```text
Hysteria2 HTTP/3 request
        |
        v
http://127.0.0.1:8080/
        |
        v
обычная веб-страница
```

Таким образом, обычный HTTP/3-запрос получает реальный контент. В сочетании с одним доменом и публично доверенным сертификатом TCP/HTTPS и UDP/HTTP3 относятся к одному и тому же сайту.

Это не гарантирует прохождение «белого списка»: сеть может независимо фильтровать UDP/QUIC, destination IP, ASN и другие признаки. Такой режим нужен для согласованной и проверяемой конфигурации.

TCP/443 и UDP/443 могут использовать один номер порта одновременно, потому что это разные транспортные протоколы.

## Управление

Проверить состояние:

```bash
sudo /opt/vless-hysteria/status.sh
```

Добавить пользователя:

```bash
sudo /opt/vless-hysteria/user.sh add user
```

Показать ссылки:

```bash
sudo /opt/vless-hysteria/user.sh links user
```

Список пользователей:

```bash
sudo /opt/vless-hysteria/user.sh list
```

Удалить пользователя:

```bash
sudo /opt/vless-hysteria/user.sh remove user
```

Изменить режим или параметры:

```bash
sudo /opt/vless-hysteria/configure.sh
```

Диагностика:

```bash
sudo /opt/vless-hysteria/diagnostics.sh
```

Резервная копия:

```bash
sudo /opt/vless-hysteria/backup.sh
```

Обновить контейнеры:

```bash
sudo /opt/vless-hysteria/update.sh
```

## Если сервер находится за роутером

Например:

```text
Внешний TCP/8443 -> сервер TCP/443
Внешний UDP/8443 -> сервер UDP/443
```

Внешние порты задаются отдельно от внутренних, поэтому схема с NAT поддерживается.

Для Let's Encrypt HTTP-01 отдельно требуется, чтобы публичный `TCP/80` попадал именно на этот сервер. Если это невозможно, оставьте `selfsigned` или используйте другой способ получения сертификата вне текущего установщика.

## Где лежат настройки

Обычные параметры:

```text
/opt/vless-hysteria/.env
```

Секреты и данные пользователей:

```text
/opt/vless-hysteria/secrets.env
/opt/vless-hysteria/users.json
```

Они не должны публиковаться в GitHub.

Общий сертификат nginx/Hysteria2:

```text
/opt/vless-hysteria/hysteria/certs/server.crt
/opt/vless-hysteria/hysteria/certs/server.key
```

При `letsencrypt` это рабочая копия сертификата из `/etc/letsencrypt/live/<domain>/`.

Веб-страница находится здесь:

```text
/opt/vless-hysteria/web/html/index.html
```

Её можно заменить своей статической страницей.

## Watchdog

Watchdog раз в минуту проверяет Xray, Hysteria2, nginx и соответствующие TCP/UDP listeners. Если сервис остановился, он пытается его запустить заново.

```bash
systemctl status vless-hysteria-watchdog.timer
```

Проект предназначен для учебного и лабораторного развёртывания. Для публичного использования стоит дополнительно настроить firewall и резервные узлы.
