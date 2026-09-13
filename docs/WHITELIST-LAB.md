# White-list transport lab

Этот документ фиксирует отдельный лабораторный эксперимент. Он не меняет основной `reality`/`web-xhttp` стек и не предполагает, что конкретный транспорт гарантированно проходит фильтрацию.

## Откуда взялась гипотеза

Полученный рабочий клиентский профиль использует отдельный VLESS outbound со следующей формой:

- VLESS;
- TCP на нестандартном высоком порту;
- gRPC;
- `security=none`;
- короткий `serviceName`;
- без TLS, REALITY, SNI и отдельного Host/authority.

В том же профиле большой список разрешённых доменов отправляется через `direct`, а остальной трафик — через VLESS proxy. Серверный конфиг исходного узла недоступен, поэтому серверная сторона восстанавливается только до минимально необходимой формы, которую однозначно задаёт клиент.

Цель эксперимента — проверить отдельно транспорт и отдельно вариант с TLS-камуфляжем. Огромный список `direct`-доменов пока не копируется: он относится к клиентской маршрутизации и мешал бы изолировать канал до VLESS-сервера.

## Эксперимент A: gRPC/h2c без TLS

Основной стек продолжает работать как раньше. Дополнительно запускается второй Xray-контейнер:

```text
TCP/20493
    |
VLESS
    |
gRPC / h2c
serviceName=ws
security=none
    |
freedom
```

По умолчанию используются:

```text
LAB_GRPC_LISTEN_PORT=20493
PUBLIC_LAB_GRPC_PORT=20493
LAB_GRPC_SERVICE=ws
```

Параметры выбраны для воспроизведения формы предоставленного тестового профиля, но не его чужих credentials или endpoint.

После `git pull`:

```bash
sudo install -d -m 0750 \
  /opt/vless-hysteria/templates \
  /opt/vless-hysteria/lab-grpc

sudo install -m 0644 \
  templates/xray-lab-grpc.json.tpl \
  /opt/vless-hysteria/templates/xray-lab-grpc.json.tpl

sudo install -m 0644 \
  compose.lab-grpc.yml \
  /opt/vless-hysteria/compose.lab-grpc.yml

sudo install -m 0750 \
  lab-grpc.sh \
  /opt/vless-hysteria/lab-grpc.sh
```

Запуск:

```bash
sudo /opt/vless-hysteria/lab-grpc.sh enable
```

Проверка:

```bash
sudo /opt/vless-hysteria/lab-grpc.sh status
```

Получить ссылку:

```bash
sudo /opt/vless-hysteria/lab-grpc.sh link default
```

Остановить:

```bash
sudo /opt/vless-hysteria/lab-grpc.sh disable
```

Если сервер находится за NAT, внешний `TCP/20493` должен доходить до `TCP/20493` этой VM. Если нужен другой внешний порт, например `30493 -> 20493`:

```bash
sudo /opt/vless-hysteria/lab-grpc.sh enable 20493 30493 ws
```

## Эксперимент B: отдельный REALITY listener с whitelist target

Второй эксперимент не заменяет gRPC/h2c listener. Он запускается параллельно отдельным Xray-контейнером и нужен для сравнения с транспортом без TLS.

```text
TCP/24443
    |
VLESS + XTLS Vision
    |
REALITY
    |
TLS camouflage target
```

По умолчанию preset `max` использует:

```text
web.max.ru:443
```

Также есть preset `smartcaptcha`:

```text
smartcaptcha.cloud.yandex.ru:443
```

Можно передать и произвольный hostname. Скрипт перед запуском проверяет, что выбранный target отвечает по TLS 1.3. Для lab REALITY генерируется отдельная X25519-пара и отдельный short ID; ключи основного REALITY-профиля не переиспользуются.

Установка в существующий runtime:

```bash
sudo install -d -m 0750 \
  /opt/vless-hysteria/templates \
  /opt/vless-hysteria/lab-reality

sudo install -m 0644 \
  templates/xray-lab-reality.json.tpl \
  /opt/vless-hysteria/templates/xray-lab-reality.json.tpl

sudo install -m 0644 \
  compose.lab-reality.yml \
  /opt/vless-hysteria/compose.lab-reality.yml

sudo install -m 0750 \
  lab-reality.sh \
  /opt/vless-hysteria/lab-reality.sh
```

Запуск с MAX:

```bash
sudo /opt/vless-hysteria/lab-reality.sh enable max
```

Запуск со SmartCaptcha:

```bash
sudo /opt/vless-hysteria/lab-reality.sh enable smartcaptcha
```

По умолчанию listener и public client port — `24443`. Если внешний NAT использует другой порт:

```bash
sudo /opt/vless-hysteria/lab-reality.sh enable max 24443 34443
```

Проверка:

```bash
sudo /opt/vless-hysteria/lab-reality.sh status
```

Получить отдельную клиентскую ссылку:

```bash
sudo /opt/vless-hysteria/lab-reality.sh link default
```

Остановить:

```bash
sudo /opt/vless-hysteria/lab-reality.sh disable
```

Важно: REALITY target/SNI — это отдельный параметр эксперимента, а не доказательство того, что сеть считает наш destination IP принадлежащим MAX/Yandex. Фильтр может учитывать IP/ASN, порт, SNI, TLS profile и другие признаки одновременно.

## Что сравниваем

Проверять нужно в одной и той же тестовой сети и по возможности с одного устройства:

| Профиль | Транспорт | Порт | TLS/REALITY | Результат |
| --- | --- | --- | --- | --- |
| основной `web-xhttp` | XHTTP stream-up/H2 | TCP/443 | обычный TLS | зафиксировать |
| `lab-grpc` | gRPC/h2c | TCP/20493 | нет | зафиксировать |
| `lab-reality max` | raw + Vision | TCP/24443 | REALITY, `web.max.ru` | зафиксировать |
| `lab-reality smartcaptcha` | raw + Vision | TCP/24443 | REALITY, SmartCaptcha | зафиксировать |
| Hysteria2 | QUIC/HTTP3 | UDP/443 | TLS | зафиксировать |

Сначала желательно проверить профили без ограничений, чтобы отделить ошибку конфигурации от поведения фильтра. Затем повторить тест в ограниченной сети.

## Как интерпретировать

Если `lab-grpc` на высоком TCP-порту работает, а обычный HTTPS/XHTTP нет, это подтверждает только зависимость результата от порта/транспортного профиля в конкретной тестовой сети. Это ещё не доказывает внутренний механизм фильтра.

Если `lab-reality` проходит, а `lab-grpc` нет, нужно отдельно менять target и порт, прежде чем связывать результат именно с SNI/REALITY.

Если работают любые произвольные TCP-порты до внешних адресов, гипотеза становится проще: ограничение может не применяться к части нестандартного TCP-трафика.

Если оба lab-профиля блокируются, нужно отдельно проверять порт, маршрут, NAT и только потом искать другие отличия предоставленного рабочего узла.

## Ограничения

`security=none` в `lab-grpc` оставлен намеренно, потому что именно так выглядит предоставленный клиентский профиль. Это экспериментальная конфигурация, а не рекомендуемый публичный режим.

REALITY-профиль тоже является лабораторным сравнением. Совпадение SNI с доменом из списка разрешённых ресурсов само по себе не гарантирует доступ: destination IP остаётся IP нашего сервера.
