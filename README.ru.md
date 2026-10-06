# VPNpool — менеджер подписки VLESS / Reality с автопереключением для OpenWrt

<p align="right"><a href="README.md">English</a> · <b>Русский 🇷🇺</b></p>

<p align="center">
  <a href="https://github.com/roman-png/VPNpool/actions/workflows/build.yml"><img alt="Сборка .ipk + .apk" src="https://github.com/roman-png/VPNpool/actions/workflows/build.yml/badge.svg"></a>
  <a href="https://github.com/roman-png/VPNpool/releases/latest"><img alt="Последний релиз" src="https://img.shields.io/github/v/release/roman-png/VPNpool?label=release"></a>
  <img alt="OpenWrt 23.05 / 24.10 / 25.12 (opkg + apk)" src="https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.12-blue">
  <img alt="Движок: sing-box" src="https://img.shields.io/badge/engine-sing--box-success">
  <img alt="Протоколы: VLESS VMess Trojan Shadowsocks AmneziaWG" src="https://img.shields.io/badge/protocols-VLESS%20%C2%B7%20VMess%20%C2%B7%20Trojan%20%C2%B7%20SS%20%C2%B7%20AmneziaWG-informational">
  <img alt="Лицензия: GPL-3.0" src="https://img.shields.io/badge/License-GPL--3.0-blue.svg">
</p>

**Как v2RayTun или Happ — только на роутере.** vpnpool держит всю вашу подписку VLESS /
Reality как пул, проверяет каждый узел по тем сервисам, которые нужны *вам*, и сам
переключается на рабочий. Узлы AmneziaWG живут в том же пуле. Управление — из LuCI,
Telegram-бота или обычным `uci`.

<p align="center">
  <img alt="Дашборд vpnpool в LuCI: список узлов с живыми пингами и активный узел" src="docs/screenshots/dashboard.jpg" width="820">
</p>

```sh
sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

<sub>Одна команда для любой OpenWrt: `.apk` на 25.12+, `.ipk` на 23.05 / 24.10 — формат установщик выбирает сам. Другие варианты — в разделе [Установка](#-установка).</sub>

---

## ✨ Главное

| | |
|---|---|
| 🎯 **Проверка по делу** | Узел «рабочий», только если открывает *ваши* сервисы (например, YouTube), а не просто пингуется |
| 🔀 **Автопереключение** | urltest + сквозной сторож: упавший активный узел заменяется сам |
| 🚦 **Без «чёрной дыры»** | LAN никогда не уходит в мёртвый туннель — нет рабочих узлов, интернет идёт напрямую |
| 📡 **Подписки** | Автообновление, несколько подписок в одном пуле, перебор User-Agent клиентов |
| 🧩 **Протоколы** | VLESS (Reality + Vision), VMess, Trojan, Shadowsocks, JSON sing-box, **AmneziaWG** |
| 🧭 **Маршрутизация** | Только выбранные сайты или всё, кроме них; 26 готовых списков; правила по устройствам |
| 🛡️ **Защита от утечек** | IPv6-заслон, kill-switch, защита DNS, анти-DPI фрагментацией TLS |
| 🤖 **Telegram** | Уведомления и бот с кнопками; работает, даже где Telegram заблокирован |
| 📟 **Маленькие роутеры** | Работает на 16 МБ флеш — sing-box живёт в ОЗУ |
| 🤝 **Соседство** | С podkop и zapret: свои метки, таблицы и порты |

---

## 📸 Скриншоты

| Дашборд | Источники |
|---|---|
| ![Вкладка «Дашборд» vpnpool: живые пинги узлов, активный узел, трафик](docs/screenshots/dashboard.jpg) | ![Вкладка «Источники» vpnpool: подписки, ручные узлы и AmneziaWG](docs/screenshots/sources.jpg) |
| **Маршрутизация** | **Настройки** |
| ![Вкладка «Маршрутизация» vpnpool: выборочный режим, списки доменов, правила по устройствам](docs/screenshots/routing.jpg) | ![Вкладка «Настройки» vpnpool: failover, проверка узлов, анти-DPI, Telegram](docs/screenshots/settings.jpg) |

---

## 🚀 Установка

**Нужно:** OpenWrt **25.12+** (apk) или **23.05 / 24.10** (opkg), **≥ 128 МБ ОЗУ**,
~40 МБ свободной флеш под sing-box — или [16 МБ флеш с sing-box в ОЗУ](#-роутеры-с-16-мб-флеш).
Наши пакеты не зависят от архитектуры; sing-box и модули ядра берутся из фидов вашего роутера.

| Вариант | Команда |
|---|---|
| **Обычный** | `sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)` |
| **+ AmneziaWG** | `VPNPOOL_AWG=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)` |
| **16 МБ флеш** | `VPNPOOL_RAM_SINGBOX=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)` |

Та же команда **обновляет** установленный vpnpool; `/etc/config/vpnpool` сохраняется. Если
`wget` не умеет `<(...)`: `wget -O /tmp/i.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh && sh /tmp/i.sh`.

<details>
<summary><b>Параметры установщика</b></summary>

| Переменная | Что делает |
|---|---|
| `VPNPOOL_AWG=1` | Меняет sing-box на [форк с AmneziaWG](https://github.com/hoaxisr/amnezia-box) (пребилды aarch64 / mipsel, сверка sha256) и закрепляет его от обновлений: `opkg flag hold` или точная версия в `/etc/apk/world` на apk |
| `VPNPOOL_RAM_SINGBOX=1` | 16 МБ флеш: sing-box в ОЗУ, переустанавливается при каждой загрузке |
| `VPNPOOL_VERSION=v1.5.0` | Конкретный релиз вместо `latest` (`.apk` — начиная с v1.5.0) |
| `VPNPOOL_PKG_DIR=/tmp/vpnpool` | Поставить файлы пакетов, уже скопированные в этот каталог, — без скачивания с GitHub |

Загрузка повторяется до 4 раз и откатывается на [зеркало GitHub Pages](https://roman-png.github.io/VPNpool).
⚠ podkop использует тот же `/usr/bin/sing-box` — с вариантом AWG он тоже будет работать на форке.

</details>

<details>
<summary><b>Ручная установка из Releases</b></summary>

В каждом [релизе](https://github.com/roman-png/VPNpool/releases/latest) есть оба формата:

```sh
# OpenWrt 25.12+ (apk)
apk update && apk add --allow-untrusted ./vpnpool-*.apk ./luci-app-vpnpool-*.apk
# OpenWrt 23.05 / 24.10 (opkg)
opkg update && opkg install ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk
```

`--allow-untrusted` нужен, потому что отдельный файл не покрыт подписью фида.

</details>

<details>
<summary><b>Подписанный фид пакетов</b> — обновляется вместе с системой</summary>

```sh
# OpenWrt 25.12+ (apk)
wget -O /etc/apk/keys/vpnpool-apk.pem https://roman-png.github.io/VPNpool/apk/vpnpool-apk.pem
echo "https://roman-png.github.io/VPNpool/apk/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
apk update && apk add luci-app-vpnpool

# OpenWrt 23.05 / 24.10 (opkg, ключ usign 807479500e0ce219)
wget -O /etc/opkg/keys/807479500e0ce219 https://roman-png.github.io/VPNpool/vpnpool-feed.pub
echo "src/gz vpnpool https://roman-png.github.io/VPNpool" >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-vpnpool
```

Проверка подписи остаётся включённой. Пакет, поставленный из *файла*, закреплён за ним,
поэтому `apk upgrade` / `opkg upgrade` его не обновят — перезапустите установщик или
подключите этот фид.

</details>

<details>
<summary><b>Сборка из исходников (OpenWrt SDK)</b></summary>

```sh
# внутри OpenWrt SDK: 25.12 -> .apk, 24.10 -> .ipk (Makefile'ы одни и те же)
git clone https://github.com/roman-png/VPNpool package/vpnpool-src
./scripts/feeds update -a && ./scripts/feeds install -a
make package/vpnpool/compile package/luci-app-vpnpool/compile V=s
```

CI собирает оба формата под aarch64_cortex-a53, x86_64 и mipsel_24kc и прикладывает к релизам.

</details>

---

## ⚙️ Быстрый старт

1. **Источники** → вставьте URL подписки → **Обновить сейчас**.
2. **Настройки → Проверка узлов** → перечислите сервисы, которые должны работать (по умолчанию `www.youtube.com`).
3. **Маршрутизация** → выберите режим и списки / домены для прокси.
4. **Дашборд** → **Включить**. Зелёная ★ — активный узел.
5. **Диагностика** → **Проверить выход через VPN** — покажет IP и страну выхода.

```sh
# то же из консоли
uci set vpnpool.main.subscription_url='https://example.com/sub'
uci set vpnpool.main.enabled='1'; uci commit vpnpool
/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart
```

---

## 🧩 Возможности

**Подписки и узлы**
- Автообновляемая подписка (base64 или JSON sing-box); перебор 9 User-Agent клиентов, пока какой-то не вернёт узлы
- Несколько подписок в одном пуле; офлайн-кэш, если панель недоступна
- Ручные узлы, вставка пачкой или импорт `.txt`, импорт из списка ссылок с выбором нужного
- ⭐ Сохранённые узлы переживают истечение подписки; автоснимок доступных узлов
- Ссылка на узел + **QR без интернета**, экспорт подпиской; трафик и срок подписки
- Поиск, фильтр и сортировка для подписок на сотни узлов

**Проверка и автопереключение**
- 🎯 Один критерий «рабочего» узла: открывает **все** указанные сервисы — по нему работают urltest, failover и сторож
- 🔀 Автопереключение; 📌 предпочтительный узел с возвратом; ⚙ выбор узлов для авто-пула
- 🩺 Сквозной сторож перезапускает зависший sing-box; мёртвые хосты отсеиваются заранее
- 🚦 Безопасная маршрутизация: правила поднимаются только после реальной проверки, повтор каждые 15 с
- ⚡ Тест скорости и 🎬 проверка доступа по узлу (YouTube / ChatGPT / Netflix / Instagram / Telegram / Google)

**AmneziaWG** — обфусцированный WireGuard, который проходит DPI мобильных операторов
- Импорт `.conf` или ссылки AmneziaVPN `vpn://` — расшифровывается на роутере, наружу ничего не уходит
- Все поля AWG (Jc/Jmin/Jmax, S1–S4, H1–H4 с диапазонами, I1–I5, PSK, MTU)
- Тот же пул, та же проверка сервисов и автопереключение, что у VLESS
- Нужен форк sing-box с AWG (`VPNPOOL_AWG=1`); на стоковом sing-box интерфейс AWG скрыт

**Маршрутизация**
- Через VPN **только** выбранные списки/домены — или **всё, кроме** них
- 26 автообновляемых списков ([itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains)) + свои домены
- Правила по устройствам: выбор по имени из DHCP, привязка по MAC
- Адаптивная маршрутизация: сама находит сайты, заблокированные напрямую, и пускает их через VPN
- Анти-DPI: фрагментация TLS ClientHello, выкл / вкл / агрессивно

**Безопасность и управление**
- IPv6-заслон, kill-switch и защита DNS по желанию; Clash API только на loopback
- Каждый конфиг проходит `sing-box check`; битый узел отбрасывается, битая сборка откатывается
- Живой трафик по узлам и устройствам; расписание включения и обновления
- Уведомления в Telegram + двусторонний бот (кнопки `/menu`), ходит через VPN
- Вкладка диагностики, резервная копия / восстановление, интерфейс RU/EN автоматически

---

## 📟 Роутеры с 16 МБ флеш

sing-box (~38 МБ) не помещается, наши пакеты (~128 КБ) — да. С `VPNPOOL_RAM_SINGBOX=1`
vpnpool остаётся во флеш, а sing-box кладётся в ОЗУ при каждом поднятии WAN — роутеру нужен
интернет при загрузке и ~128 МБ ОЗУ. Обновление — повторным запуском той же команды.

<details>
<summary><b>Как это устроено и ручные шаги</b></summary>

- **opkg (≤ 24.10):** пакеты ставятся с `--nodeps`, sing-box — `opkg install -d ram` (`dest ram /tmp`).
- **apk (25.12+):** ни `--nodeps`, ни `-d ram` нет, поэтому зависимость закрывает пустая
  заглушка `apk add --virtual sing-box`, а настоящий бинарь берётся из фида через
  `apk fetch` + `apk extract` в `/tmp/usr/bin/` (`apk fetch` сверяет файл с подписанным индексом фида).

```sh
# 1. мелкие зависимости + наши пакеты без sing-box во флеш
#    apk:
apk add jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full luci-base ca-bundle kmod-tun kmod-inet-diag zram-swap
apk add --virtual sing-box
apk add --allow-untrusted ./vpnpool-*.apk ./luci-app-vpnpool-*.apk
#    opkg:
opkg install jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full luci-base ca-bundle zram-swap
opkg install --nodeps ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk

# 2. без автозапуска — vpnpool запустит хук, когда sing-box окажется в ОЗУ
/etc/init.d/vpnpool disable
```

```sh
# 3. хук загрузки (вариант для apk; на opkg замените строки apk на
#    "opkg update" + "opkg install -d ram --force-reinstall --force-overwrite sing-box")
cat > /etc/hotplug.d/iface/99-vpnpool-singbox-ram <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" -a "$INTERFACE" = "wan" ] && {
    apk update
    d=/tmp/vpnpool-sb; rm -rf "$d"; mkdir -p "$d/x" /tmp/usr/bin
    apk fetch -o "$d" sing-box && apk extract --allow-untrusted --destination "$d/x" "$d"/sing-box-[0-9]*.apk \
        && mv -f "$d/x/usr/bin/sing-box" /tmp/usr/bin/sing-box
    rm -rf "$d"; chmod +x /tmp/usr/bin/sing-box
    ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
    /etc/init.d/vpnpool start
    logger -t vpnpool "sing-box in RAM, vpnpool started"
}
EOF
chmod +x /etc/hotplug.d/iface/99-vpnpool-singbox-ram
```

Хук должен быть **один**: два хука одновременно на роутере со 128 МБ портят бинарь
(`sing-box: Bus error`). С `VPNPOOL_AWG=1` хук качает форк с AWG и при неудаче откатывается
на стоковый sing-box. Проверено на Xiaomi Mi Router 4A Gigabit (16 МБ / 128 МБ, OpenWrt 24.10);
путь через apk — на официальном образе OpenWrt 25.12.4.

</details>

---

## 📚 Справочник

<details>
<summary><b>Как это работает</b></summary>

```
LuCI (5 вкладок) ── ubus/rpcd ── vpnpoold (ucode + shell, procd)
                                  │ загрузка (перебор UA) → разбор → сборка → sing-box check
                                  │ проверка сервисов (Clash delay API) → живые/мёртвые
                                  ▼
                          sing-box (движок)
   вход   : tproxy 127.0.0.1:1603  +  локальный SOCKS/HTTP :1605 (тесты, бот)
   выход  : urltest "auto" (пинг + failover) + селектор + узлы + direct
   endpoints[]: пиры AmneziaWG / WireGuard (sing-box >= 1.13)
   правила: SNI → списки SRS / домены → proxy (или direct в режиме «всё, кроме»)
                                  ▲
   nftables (table inet vpnpool): метка LAN 80/443 → fwmark 0x400000 → таблица 142 →
   tproxy; уступает podkop; IPv6 закрыт; включение/исключение устройств
```

Управляющая часть наша, передачу данных делает sing-box. Маршрутизация — по SNI, без
fake-IP и без перехвата dnsmasq.

</details>

<details>
<summary><b>Настройки (uci) — все параметры</b></summary>

Всё хранится в `/etc/config/vpnpool`, секция `config vpnpool 'main'`.

| Параметр | По умолчанию | Смысл |
|---|---|---|
| `enabled` | `0` | Запуск службы (переключатель в LuCI) |
| `mode` | `selective` | `selective` — через VPN только списки; `exclude` — всё, кроме них |
| `subscription_url` | — | Основная подписка (из неё берутся трафик и срок) |
| `subscription_interval` | `6h` | Период автообновления |
| `check_services` | `www.youtube.com` | **Главный** критерий рабочего узла, по хосту в строке |
| `health_url` | `http://cp.cloudflare.com/generate_204` | Запасная проверка, если `check_services` пуст |
| `failover_interval` / `failover_tolerance` | `60` / `50` | Интервал urltest (с) и допуск (мс) |
| `auto_switch` | `1` | `0` закрепляет селектор на первом узле |
| `selected_node` / `preferred_node` | — | Жёсткий ручной выбор / мягкий 📌 с возвратом |
| `dead_filter` / `dead_filter_strikes` / `dead_filter_tries` | `1` / `3` / `3` | Фильтр авто-пула по сервисам, провалов до исключения, повторов за цикл |
| `ipv6` | `block` | `block` — IPv6 закрыт; `off` — IPv6 не трогаем |
| `killswitch` / `dns_protect` | `0` / `0` | Закрытый IPv4 в режиме `exclude` / DNS LAN через туннель |
| `client_mode` | `all` | `all` / `exclude` / `include` по устройствам |
| `antidpi` | `off` | `off` / `on` (`tls_fragment`) / `aggressive` (+ `tls_record_fragment`) |
| `adaptive_routing` / `adaptive_max_per_run` | `0` / `8` | Поиск доменов, заблокированных напрямую |
| `auto_snapshot` / `auto_snapshot_max` | `0` / `20` | Автосохранение доступных узлов |
| `sched_enabled`, `sched_on`, `sched_off`, `sched_refresh` | `0`, — | Расписание на день (ЧЧ:ММ) |
| `telegram_enabled`, `telegram_token`, `telegram_chat` | `0`, — | Уведомления |
| `telegram_control` / `telegram_via_proxy` | `0` / `1` | Двусторонний бот / Telegram через туннель |
| `speedtest_url` / `speedtest_min_mem_kb` | Cloudflare / `8192` | Адрес теста скорости / запас свободной памяти |
| `dns_strategy` | `prefer_ipv4` | Порядок разрешения имён для проверок sing-box |
| `fwmark` / `route_table` / `route_priority` | `0x400000` / `142` / `106` | Непересекающиеся ресурсы маршрутизации |
| `tproxy_port` / `test_port` / `clash_api` | `1603` / `1605` / `127.0.0.1:9091` | Входы и управляющий API |
| `lan_if` / `coexist` / `log_level` | авто / `auto` / `warn` | Устройство LAN, уступка podkop, уровень лога sing-box |

Списки, которые ведёт приложение: `source`, `extra_sub`, `manual_node`, `imported_node`,
`saved_node`, `active_saved`, `excluded_node`, `auto_member`, `keep_auto`, `client`,
`client_dev`, `probe_ua`; в `config routing 'routing'` — `community`, `domain`, `auto_domain`.
Узлы AmneziaWG — файлы `/etc/vpnpool/awg/*.conf`.

</details>

<details>
<summary><b>Сравнение с podkop / passwall2 / homeproxy</b></summary>

| | **vpnpool** | podkop | passwall2 | homeproxy |
|---|---|---|---|---|
| Автопинг + переключение | ✅ urltest + сторож | вручную | ✅ | ✅ |
| Проверка узлов по реальным сервисам | ✅ | — | только пинг | только пинг |
| Безопасная маршрутизация | ✅ | — | — | — |
| Предпочтительный узел с возвратом | ✅ | — | — | — |
| AmneziaWG в том же пуле | ✅ `.conf` + `vpn://` | — | — | — |
| Трафик подписки, сохранённые узлы, тесты скорости / доступа | ✅ | — | — | — |
| Двусторонний Telegram-бот | ✅ | — | — | — |
| Адаптивная маршрутизация, анти-DPI | ✅ | — | — | — |
| Готовые списки SRS | ✅ 26 | ✅ | свои | свои |
| Правила по устройствам | ✅ имя DHCP / MAC | — | ✅ | частично |
| Соседство с podkop | ✅ | — | — | — |

</details>

<details>
<summary><b>Частые вопросы</b></summary>

- **Это VPN-сервис?** Нет — подписка, сервер или конфиг AmneziaWG ваши.
- **Чем отличается от podkop?** podkop маршрутизирует выборочно, но узел выбираете вы; vpnpool выбирает и переключает узлы сам. Они работают рядом.
- **Нужен другой sing-box?** Только для AmneziaWG (`VPNPOOL_AWG=1`).
- **200 узлов на дешёвом роутере?** Нормально: мёртвые хосты отсеиваются, проверки идут по очереди, тяжёлые тесты смотрят на свободную память.
- **Подписка истекла / все узлы лежат?** LAN остаётся на прямом подключении; маршрутизация вернётся в течение 15 с после ответа узла.
- **Без LuCI?** Да — `uci` и Telegram-бот.
- **zapret?** Уживается, виден в диагностике; vpnpool им не управляет.

</details>

<details>
<summary><b>Если что-то не работает</b></summary>

| Симптом | Что делать |
|---|---|
| В логе *«keeping LAN on DIRECT»* | Ни один узел не прошёл проверку — проверьте подписку и *Настройки → Проверка узлов* |
| Всё пингуется, сайты не открываются | Узел достаёт до CDN, но не до ваших сервисов — смотрите список **«Вне авто-пула»** |
| Нет раздела AmneziaWG | Стоковый sing-box — переустановите с `VPNPOOL_AWG=1` |
| `sing-box: Bus error` после перезагрузки (16 МБ) | Два хука загрузки — оставьте один |
| Не скачиваются списки доменов | Они берутся с GitHub Releases — сначала пустите GitHub через прокси |
| Бот отвечает через раз | Работают два поллера — остановите ручной `tgbot.sh` |
| `no .apk assets in release` | Этот релиз старше поддержки apk — `.apk` есть с v1.5.0 |
| `UNTRUSTED signature` при `apk add ./файл.apk` | Добавьте `--allow-untrusted` или подключите подписанный фид |

```sh
logread -e vpnpool                       # лог
uci show vpnpool                         # конфигурация
/etc/init.d/vpnpool restart              # перезапуск
kill -USR2 $(cat /var/run/vpnpool.pid)   # заново скачать подписку и пересобрать
```

Ограничения: ECH (зашифрованный SNI) не распознаётся; анти-DPI — только фрагментация TLS, против ТСПУ используйте zapret.

</details>

---

## 🗺️ Планы

Более быстрое переключение по активной проверке · DNS/FakeIP с DoH через прокси · полный
IPv6 tproxy · подписки Clash YAML · цепочки узлов · AmneziaWG для других архитектур

## 🛠️ Разработка

ucode + shell + немного LuCI JS — компилировать нечего. В `package/` — два пакета, в
`stand/` — Docker-стенд на настоящем rootfs OpenWrt, `scripts/deploy.sh` выкладывает файлы
на роутер по SSH, `tools/router-smoke-test.sh` проверяет живой роутер без изменений.
Issues и PR приветствуются.

## 📄 Лицензия

[GPL-3.0-only](LICENSE) © 2026 roman-png

<sub>OpenWrt VLESS Reality · менеджер подписки sing-box · автопереключение VPN на роутере ·
v2RayTun / Happ для роутера · альтернатива podkop / passwall / homeproxy · AmneziaWG OpenWrt ·
OpenWrt 25.12 apk · обход блокировок роутер OpenWrt · подписка VLESS на роутер · AmneziaWG на роутер</sub>
