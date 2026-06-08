# VPN Pool (vpnpool) — менеджер VLESS‑подписок с авто‑переключением для OpenWrt

<p align="right"><a href="README.md">English 🇬🇧</a> · <b>Русский</b></p>

> **Приложение для OpenWrt, которое превращает автообновляемую подписку VLESS/Reality
> в всегда рабочий VPN** — как **v2RayTun / Happ, только на вашем роутере**. Пингует
> все узлы, **автоматически переключается на рабочий VLESS‑сервер**, когда текущий
> отваливается, и маршрутизирует трафик сети (вся сеть или по устройствам, выбранные
> сайты или всё) через **sing‑box**. Всё управление — из аккуратного веб‑интерфейса LuCI.

<p align="center">
  <a href="https://github.com/roman-png/VPNpool/actions/workflows/build.yml"><img alt="Build .ipk" src="https://github.com/roman-png/VPNpool/actions/workflows/build.yml/badge.svg"></a>
  <img alt="License: GPL-3.0" src="https://img.shields.io/badge/License-GPL--3.0-blue.svg">
  <img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10-blue">
  <img alt="Engine" src="https://img.shields.io/badge/engine-sing--box-success">
</p>

**Ключевые слова:** OpenWrt VLESS, VLESS Reality OpenWrt, подписка sing-box, авто
переключение VLESS, v2RayTun на роутер, Happ на роутер, аналог podkop, аналог passwall,
vless vmess trojan shadowsocks подписка, xtls-rprx-vision reality, urltest failover,
обход блокировок роутер OpenWrt, антизапрет sing-box.

---

## Что это умеет

- 📡 **Автообновляемая подписка** — вставьте URL подписки (список base64 **или**
  JSON sing‑box). Поддержка нескольких источников (например, автообновляемые raw‑файлы
  конфигов из репозитория). **Перебор клиентских User‑Agent**: пробует несколько UA и
  оставляет ответ с наибольшим числом узлов — работает, даже если провайдер сменил формат.
- 🔀 **Авто‑пинг + переключение** — sing‑box `urltest` проверяет каждый узел и
  **сам переключается на рабочий VLESS‑сервер**, когда активный перестаёт отвечать.
  Есть и ручной выбор, и ручной «пинг всех».
- 🎛️ **Настраиваемый авто‑пул** — на Дашборде нажмите **⚙ Настроить** у строки АВТО и
  выберите, **какие именно узлы участвуют в авто‑переключении**. Невыбранные остаются
  доступны для ручного выбора, но автоматически никогда не выбираются.
- 🧭 **Выборочная маршрутизация** — проксировать **только выбранные списки/домены**
  (остальное напрямую) **или всё, кроме них** (полный VPN с исключениями). Списки
  сообществ из [itdoginfo/allow‑domains](https://github.com/itdoginfo/allow-domains)
  как автообновляемые **SRS rule‑set'ы sing‑box** (Telegram, Россия, YouTube, Meta,
  Twitter/X, Discord, …) плюс ваши домены.
- 👥 **Маршрутизация по устройствам** — вся сеть, **исключить** конкретные устройства
  (идут мимо VPN) или разрешить **только** определённые устройства.
- 🧩 **Протоколы** — VLESS (Reality + `xtls‑rprx‑vision`), VMess, Trojan, Shadowsocks,
  а также готовые JSON‑конфиги sing‑box.
- 🛡️ **Защита от утечки IPv6** (fail‑closed), **Clash API только на loopback** (не виден
  в LAN), поведение в духе **kill‑switch**.
- 🤝 **Уживается** с [podkop](https://github.com/itdoginfo/podkop) и zapret
  (авто‑определение, непересекающиеся марки/таблицы/порты) — или работает **автономно**.
- 🔔 **Уведомления в Telegram** — переключение узла, истечение подписки, старт/стоп.
- 🖥️ **Веб‑интерфейс LuCI** (5 вкладок, авто **RU/EN**): живые пинги узлов, статистика
  трафика и соединений, вкл/выкл, ручной выбор, источники, маршрутизация, настройки,
  диагностика (включая реальную проверку **«выход через VPN»**), бэкап/восстановление.

---

## 📸 Скриншоты

| Дашборд | Источники |
|---|---|
| ![Дашборд](docs/screenshots/dashboard.jpg) | ![Источники](docs/screenshots/sources.jpg) |
| **Маршрутизация** | **Настройки** |
| ![Маршрутизация](docs/screenshots/routing.jpg) | ![Настройки](docs/screenshots/settings.jpg) |

---

## 🧰 Поддерживаемое и рекомендуемое железо

Само vpnpool крошечное и **не зависит от архитектуры**. Реальное требование — это
**sing‑box**, бинарь ~38 МБ.

- **Минимум:** любой роутер на **OpenWrt 23.05 / 24.10** с **≥ 128 МБ ОЗУ**. Под
  хранилище нужно место для sing‑box (~38 МБ). Роутеры с **16 МБ флеш** тоже подойдут —
  см. [Роутеры с малым объёмом флеш (16 МБ)](#-роутеры-с-малым-объёмом-флеш-16-мб),
  там sing‑box ставится в ОЗУ.
- **Рекомендуется:** **≥ 256 МБ флеш** (или USB/extroot) и **≥ 512 МБ ОЗУ**, например:
  - **Cudy TR3000**, **GL.iNet** Flint/Beryl, любой **MediaTek Filogic** (MT7981/MT7986),
  - платы **Qualcomm IPQ807x**,
  - **x86 / x86_64** мини‑ПК или ВМ,
  - **Raspberry Pi 4** с OpenWrt.

> **Про архитектуру:** наши два пакета поставляются как `_all` (один файл работает на
> **любом** CPU). Архитектура важна только для *зависимостей* (sing‑box, kmod'ы),
> которые opkg сам подтянет из штатных фидов OpenWrt под **ваше** устройство.
> Узнать свою архитектуру: `opkg print-architecture`.

### 💾 Объём установки

| Компонент | Размер на диске |
|---|---|
| `vpnpool` + `luci-app-vpnpool` (наш код) | **~128 КБ** |
| `sing-box` (движок) | **~38 МБ** (ipk ~14 МБ) |
| `jq` / `curl` / `ucode` / kmod'ы | несколько сотен КБ |
| **Итого со всеми зависимостями** | **~40 МБ** |

---

## 🚀 Установка

### Вариант A — одной строкой (рекомендуется)

Ставит (или обновляет) последний релиз. Скачивает готовые пакеты из GitHub Releases
и подтягивает зависимости из штатных фидов OpenWrt. Ваш `/etc/config/vpnpool`
(подписка, Telegram, маршрутизация) при обновлении сохраняется.

```sh
sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

Если ваш BusyBox `wget` не поддерживает `<(...)`:

```sh
wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh
sh /tmp/vpnpool-install.sh
```

### Вариант B — готовые `.ipk` из Releases

Наши пакеты — это `_all` файлы без привязки к архитектуре, **для любого роутера
скачиваются одни и те же два файла**:

1. Возьмите `vpnpool_*_all.ipk` и `luci-app-vpnpool_*_all.ipk` из
   [последнего релиза](https://github.com/roman-png/VPNpool/releases/latest).
2. Скопируйте на роутер и установите:

```sh
opkg update
opkg install ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk
```

`sing-box`, `jq`, `curl`, `ucode` и нужные модули ядра подтянутся как зависимости.
Затем откройте **LuCI → Сервисы → VPN Pool**.

### Вариант C — opkg‑фид (обновление через `opkg update`)

[opkg‑фид на GitHub Pages](https://roman-png.github.io/VPNpool) **подписан** нашим
usign‑ключом (отпечаток `807479500e0ce219`). Один раз установите публичный ключ,
чтобы opkg мог проверить подпись фида, затем добавьте фид и ставьте/обновляйте как
обычный пакет — **проверка подписи остаётся включённой**:

```sh
# 1. устанавливаем наш публичный ключ (проверка подписи opkg остаётся включённой)
wget -O /etc/opkg/keys/807479500e0ce219 https://roman-png.github.io/VPNpool/vpnpool-feed.pub
# 2. добавляем фид и ставим
echo "src/gz vpnpool https://roman-png.github.io/VPNpool" >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-vpnpool
```

<details>
<summary>Запасной вариант: без ключа (отключает проверку подписи глобально)</summary>

Если не ставить ключ, opkg отклонит фид (для него он без подписи) и удалит список
пакетов. Можно вместо этого отключить проверку подписи opkg — но учтите, что это
выключит проверку **для всех фидов, включая официальные OpenWrt**, поэтому способ
с ключом предпочтительнее.

```sh
# закомментировать строку check_signature (значение 0 НЕ помогает — нужно убрать строку)
sed -i '/^[[:space:]]*option[[:space:]]\+check_signature/s/^/# /' /etc/opkg.conf
opkg update
# ...позже, чтобы вернуть проверку:
sed -i 's/^#[[:space:]]*\(option[[:space:]]\+check_signature\)/\1/' /etc/opkg.conf
```

</details>

### Вариант D — сборка из исходников (OpenWrt SDK)

```sh
# внутри OpenWrt SDK под вашу платформу
git clone https://github.com/roman-png/VPNpool package/vpnpool-src
./scripts/feeds update -a && ./scripts/feeds install -a
make package/vpnpool/compile V=s
make package/luci-app-vpnpool/compile V=s
# .ipk появятся в bin/packages/<arch>/...
```

---

## 📟 Роутеры с малым объёмом флеш (16 МБ)

sing‑box (~38 МБ) не влезает в 16 МБ флеш, а наши пакеты влезают (~128 КБ). Приём
(та же идея, что у podkop): держать vpnpool во флеш, а **sing‑box (пере)устанавливать
в ОЗУ (`/tmp`) при каждой загрузке**, по событию поднятия WAN‑интерфейса.

OpenWrt уже задаёт назначение установки в ОЗУ в `/etc/opkg.conf` (`dest ram /tmp`),
поэтому `opkg install -d ram …` кладёт бинарь в `/tmp`.

### Одной строкой (16 МБ флеш)

Тот же установщик, что и выше, но с `VPNPOOL_RAM_SINGBOX=1`:

```sh
VPNPOOL_RAM_SINGBOX=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

…или, если ваш `wget` не поддерживает подстановку процессов:

```sh
wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh && VPNPOOL_RAM_SINGBOX=1 sh /tmp/vpnpool-install.sh
```

Он ставит zram‑swap, лёгкие зависимости и наши пакеты во флеш (`--nodeps`, без
sing‑box), создаёт hotplug‑хук на поднятие WAN и сразу ставит sing‑box в ОЗУ. Дальше
задайте подписку в **LuCI → Services → VPN Pool** и выполните `/etc/init.d/vpnpool
start`. При каждой перезагрузке хук переустанавливает sing‑box в ОЗУ и запускает
vpnpool автоматически. Если ваш WAN называется не `wan`, поправьте `INTERFACE` в
`/etc/hotplug.d/iface/99-vpnpool-singbox-ram`.

> **Обновление на малой флеш:** запустите тот же one‑liner повторно. **Не** используйте
> `opkg upgrade` здесь — он разрешает зависимость `sing-box` относительно флеш и
> попытается затянуть ~38 МБ бинарь в ROM (установка специально идёт с `--nodeps`).

<details>
<summary>Ручные шаги (что делает one‑liner под капотом)</summary>

**1. Установите zram‑swap** (даёт маленькому роутеру больше полезной памяти под `opkg`):

```sh
opkg update
opkg install zram-swap
/etc/init.d/zram enable
/etc/init.d/zram start
```

**2. Установите vpnpool, но БЕЗ sing‑box** (он не влезет во флеш). Мелкие зависимости
ставим обычно, а наши пакеты — с `--nodeps`:

```sh
opkg update
opkg install jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full ca-bundle
# скачайте два _all .ipk (через страницу релиза или шаг загрузки из install.sh), затем:
opkg install --nodeps ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk
```

**3. НЕ ставьте vpnpool в автозапуск при загрузке** — sing‑box ещё не будет существовать.
Его запустит hotplug‑хук ниже, уже после установки sing‑box:

```sh
/etc/init.d/vpnpool disable
```

**4. Создайте хук загрузки**, который ставит sing‑box в ОЗУ и запускает vpnpool при
поднятии WAN (срабатывает при каждой перезагрузке, нужен интернет):

```sh
cat > /etc/hotplug.d/iface/99-vpnpool-singbox-ram <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" -a "$INTERFACE" = "wan" ] && {
    logger -t vpnpool "WAN up: installing sing-box into RAM"
    opkg update
    opkg install -d ram --force-reinstall --force-overwrite sing-box
    ln -sf /tmp/usr/bin/sing-box /usr/bin/sing-box
    /etc/init.d/vpnpool start
    logger -t vpnpool "sing-box installed in RAM, vpnpool started"
}
EOF
chmod +x /etc/hotplug.d/iface/99-vpnpool-singbox-ram
```

**5. Перезагрузитесь (или переподключите WAN) и проверьте:**

```sh
logread -e vpnpool        # должно быть "sing-box installed in RAM, vpnpool started"
sing-box version          # подтверждает, что симлинк из ОЗУ резолвится
```

</details>

> **Нюансы:** sing‑box (~14 МБ ipk) скачивается в ОЗУ при каждой загрузке, поэтому
> роутеру нужен рабочий интернет на старте и достаточно свободной ОЗУ (~128 МБ+).
> Если ваш WAN называется иначе (`wan6`, `wwan`) — поправьте проверку `INTERFACE`.
>
> **Проверено на:** Xiaomi Mi Router 4A Gigabit (MediaTek MT7621, 16 МБ флеш /
> 128 МБ ОЗУ, OpenWrt 24.10) — чистая установка one‑liner'ом, перезагрузка и живой
> VPN‑выход отработали успешно.
>
> **Только один хук загрузки.** sing‑box в ОЗУ должен ставить ровно один WAN‑up хук.
> Два хука, одновременно выполняющие `opkg install -d ram sing-box` на роутере со
> 128 МБ ОЗУ, вызывают взаимный OOM и портят бинарь (симптом: `sing-box: Bus error` /
> `Permission denied`). One‑liner удаляет старые `*vpnpool*` iface‑хуки перед записью
> своего — просто не добавляйте второй вручную.

---

## ⚙️ Быстрый старт

1. Вкладка **Источники** → вставьте URL подписки → **Обновить сейчас**.
2. Вкладка **Маршрутизация** → выберите режим (проксировать выбранное / всё, кроме) →
   отметьте списки сообществ и/или добавьте домены.
3. **Дашборд** → **Включить**. Смотрите живые пинги; зелёная ★ — активный узел.
   Кнопкой **⚙ Настроить** у строки АВТО выберите, какие узлы авто‑переключаются.
4. **Диагностика** → **Проверить выход через VPN** — подтвердите реальный выходной IP/страну.

Эквивалент в CLI:

```sh
uci set vpnpool.main.subscription_url='https://example.com/sub'
uci set vpnpool.main.enabled='1'; uci commit vpnpool
/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart
```

---

## 🧠 Как это работает

```
LuCI (5 вкладок) ── ubus/rpcd ── vpnpoold (ucode + shell, procd)
                                   │ fetch (мульти-UA) → разбор → генерация → проверка sing-box
                                   ▼
                           sing-box (движок)
   inbound: tproxy 127.0.0.1:1603  +  локальный mixed SOCKS/HTTP :1605 (тест/приложения)
   outbound: urltest "auto" (пинг + переключение) + selector + узлы + direct
   route: sniff SNI → SRS сообществ / домены → proxy (или direct в режиме «кроме»)
                                   ▲
   nftables (table inet vpnpool): метим LAN 80/443 → fwmark 0x400000 → table 142 →
   tproxy; уступаем podkop; IPv6 fail-closed; include/exclude по устройствам
```

Control‑plane (подписка, разбор, генерация конфига, watchdog, UI) — наш; data‑plane —
**sing‑box**, ровно как v2RayTun/Happ оборачивают движок.

---

## 🆚 Сравнение с podkop / passwall / homeproxy

| | **vpnpool** | podkop | passwall2 | homeproxy |
|---|---|---|---|---|
| Движок | sing‑box | sing‑box | xray/sing‑box | sing‑box |
| Автообновляемая подписка | ✅ мульти‑источник, мульти‑UA | частично | ✅ | ✅ |
| **Авто‑пинг + переключение** | ✅ urltest + watchdog | ручной выбор | ✅ | ✅ |
| **Выбор узлов для авто‑переключения** | ✅ | — | — | — |
| SRS‑списки сообществ | ✅ (itdoginfo) | ✅ | свои | свои |
| Маршрутизация по устройствам | ✅ | — | ✅ | частично |
| Самопроверка выхода через VPN | ✅ | ✅ | частично | — |
| Уведомления в Telegram | ✅ | — | — | — |
| Уживается с podkop | ✅ (by design) | n/a | — | — |
| Авто RU/EN интерфейс | ✅ | RU/EN | RU/EN | EN/ZH |

---

## 🔐 Замечания

- **DNS:** маршрутизация по **SNI‑sniff**, поэтому игры с DNS не нужны. На свежем
  OpenWrt всё работает со штатным резолвером. Если раньше стоял podkop и вы его убрали —
  верните обычный upstream в dnsmasq (podkop направляет его на свой fake‑IP резолвер
  `127.0.0.42`).
- **Доступность GitHub:** SRS rule‑set'ы скачиваются из GitHub‑релизов; если GitHub
  заблокирован — сначала пустите его через прокси.
- **Безопасность:** Clash API слушает только `127.0.0.1`.

## 🗺️ Планы

- Почти мгновенное переключение по активной пробе (быстрее интервала urltest)
- DNS через DoH‑по‑прокси для полностью безутечной выборочной маршрутизации
- Полный IPv6 tproxy (режим проксирования, а не только блок)
- Разбор подписок Clash YAML; поиск/фильтр узлов

## 🤝 Участие

Issues и PR приветствуются. Весь проект — это ucode + shell + немного LuCI JS, без
компиляции.

## 📄 Лицензия

[GPL‑3.0‑only](LICENSE) © 2026 roman‑png
