# vpnpool — план приложения (control-plane над sing-box) для OpenWRT

Рабочее имя: **vpnpool**. Аналог v2RayTun/Happ на роутере: автообновляемая подписка +
ручные VLESS-узлы + авто-пинг и авто-переключение на живой узел (failover).
Кодинг ещё не начат — это план и результаты разведки.

## Зафиксированные решения

- **Сосуществование** с podkop: поднимаем ОТДЕЛЬНЫЙ, независимый экземпляр sing-box.
  podkop и zapret не трогаем.
- **Выборочная** маршрутизация (selective), как сейчас у podkop.
- UI — **LuCI-приложение** (`luci-app-vpnpool`).
- Демон (control-plane) — **ucode + shell**, procd-служба. Python не нужен (его и нет).
- Движок — **sing-box 1.12.22**, уже установлен. Авто-пинг+переключение = нативный
  `urltest`-outbound (+ свой watchdog через Clash-API для near-instant).

## Железо/ОС (снято вживую с роутера)

| Параметр | Значение |
|---|---|
| Модель | Cudy TR3000 256MB v1 (MediaTek Filogic MT7981) |
| CPU | aarch64 Cortex-A53 ×2, AES/SHA в железе |
| OpenWRT | 24.10.4, ядро 6.6.110, пакетник opkg |
| RAM | 497 МБ (свободно ~358) |
| Флеш | overlay 190 МБ, свободно ~157 МБ |
| Движок | sing-box 1.12.22 (with_clash_api, with_gvisor, with_quic, with_utls) |
| Доступно в фидах | xray-core, v2ray-core, v2rayA, luci-app-v2raya, hev-socks5-* |
| Инструменты | ucode, jq, curl, wget, uclient-fetch, nft, ubus; python3 — НЕТ |
| Сеть | TUN есть; nftables fw4 + nft_tproxy загружен; WAN = pppoe-wan |
| Уже стоит | luci-app-podkop 0.7.14, zapret + zapret2 |

Доступ к роутеру: с Windows-машины недоступен напрямую. Ходим
Windows → Mac (Tailscale `roman@100.78.108.47`, ключ `~/.ssh/mac-mcp-key`) →
`ssh root@192.168.10.1` (без пароля).

## Результаты разведки (§ заняты podkop/zapret — что нам нельзя пересекать)

**podkop** (через tproxy, НЕ TUN; полностью владеет DNS):
- inbound sing-box: `type tproxy`, слушает `127.0.0.1:1602`.
- fwmark `0x100000` (mask `0x100000`); второй mark `0x200000` (bypass/return).
- ip rule приоритет 105 → routing table `podkop` (`default dev lo`, доставка в tproxy).
- nft-таблица `PodkopTable`, сеты: `localv4`, `podkop_subnets`, `interfaces` (br-lan).
  Маркирует трафик к `podkop_subnets` и к `198.18.0.0/15` (fakeip) → tproxy 1602.
- Clash-API (external_controller): `192.168.10.1:9090`.
- DNS: dnsmasq `noresolv=1`, единственный upstream `server=127.0.0.42`
  (собственный резолвер podkop с **fakeip 198.18.0.0/15**).
- `/tmp/dnsmasq.d/` пуст — podkop НЕ наполняет nftset через dnsmasq, он гонит весь DNS
  в свой резолвер. → план «dnsmasq наполняет наш nftset» в лоб не годится.

**zapret2** (DPI-bypass на ПРЯМОМ трафике):
- хуки `forward`(prio filter-1) и `postrouting`(prio srcnat-1/+1), NFQUEUE.
- mark `0x20000000`, ct mark `0x40000000`; обрабатывает первые N пакетов tcp 80/443
  и udp 443 на `oifname @wanif`, кроме `@nozapret`.
- ⚠️ Наши ИСХОДЯЩИЕ к VLESS-серверам идут на 443 через WAN → попадут под zapret.
  Нужно увести их из-под zapret (внести серверы/диапазон в `@nozapret` или ставить на
  наш bypass-mark `0x40000000`), иначе риск поломки Reality-handshake.

### Наша непересекающаяся раскладка ресурсов

| Ресурс | podkop | zapret | **vpnpool (наш)** |
|---|---|---|---|
| fwmark | 0x100000 / 0x200000 | 0x20000000 / ct 0x40000000 | **0x400000** |
| routing table | podkop (rule pri 105) | — | **vpnpool (rule pri 106)** |
| tproxy-порт | 127.0.0.1:1602 | — | **127.0.0.1:1603** |
| nft-таблица | PodkopTable | zapret2 | **vpnpool** |
| Clash-API | 192.168.10.1:9090 | — | **192.168.10.1:9091** |
| sing-box config | /etc/sing-box/config.json | — | **/etc/vpnpool/sing-box.json** |
| DNS / fakeip | dnsmasq→127.0.0.42, 198.18/15 | — | **без fakeip, маршрут по SNI-sniff** |

## Архитектура

```
LuCI (luci-app-vpnpool): URL подписки · список узлов · живые пинги · активный узел ·
                         тумблер on/off · ручной выбор · добавить vless://
        │ uci / ubus / JSON
vpnpoold (ucode+shell, procd):
   fetcher(curl) → parser(vless/base64/json/yaml) → generator(sing-box.json)
   → applier(sing-box check + атомарная замена + откат) → watchdog(Clash-API:9091)
        │ reload
sing-box #2 (наш): inbound tproxy 127.0.0.1:1603 (+sniff)
   route: sniff SNI → наши домены ⇒ urltest{vless 1..N}; иначе ⇒ direct
   outbound urltest = авто-пинг(generate_204)+авто-switch; selector = ручной override
        │
nft table vpnpool: «уступи podkop» (если есть mark 0x100000 → return),
   иначе mark 0x400000 → ip rule pri106 → table vpnpool → tproxy 1603
   + наши исходящие к VLESS-серверам помечаем bypass для zapret
```

### Принцип selective-сосуществования

Так как podkop захватил DNS+fakeip, мы НЕ полагаемся на DNS-сеты. Вместо этого:
1. nft-цепочка vpnpool в prerouting **уступает** podkop: пакет с его маркой `0x100000`
   → `return` (его трафик не трогаем).
2. Оставшийся кандидатный трафик (tcp/udp 80/443 с br-lan) маркируем `0x400000` и через
   ip rule pri106 / table vpnpool доставляем в наш tproxy 1603.
3. Наш sing-box **снифит SNI/host** и сам решает: домен из нашего списка ⇒ `urltest`
   (VLESS), всё прочее ⇒ `direct` (уходит наружу штатно). DNS-игры не нужны.

Минус подхода — домены под ECH/шифрованным SNI снифом не определить (редкий кейс,
фиксируем как известное ограничение).

## Подписка (подтверждено вживую)

- URL: `https://vpn.ecobuy.ltd/s/JiGdoQjh` (бренд «🐟 Щука VPN»), сервер за QRATOR.
- Формат: **base64-блоб (без переносов) → 16 строк, все `vless://` Reality +
  `xtls-rprx-vision` + `type=tcp`** (`fp` разный: ios/edge/safari).
- ⚠️ Капризен к User-Agent: дефолт/`sing-box`/`clash` UA → пусто/HTTP 500;
  рабочий — «клиентский» (напр. `v2rayNG/1.8.x`). Fetcher обязан слать такой UA.
- Заголовок ответа `subscription-userinfo: expire=<unixts>` и `profile-title:
  base64:<...>` → показываем в UI срок действия и имя профиля.

## Парсер (приоритет — под этот провайдер)

- ОСНОВНОЕ: **base64-декод → split по строкам → `vless://`** с полным Reality-набором
  (`security=reality, pbk, sid, sni, fp, flow, spx, type`), URL-decode `#name` (эмодзи).
- По возможности (не приоритет, провайдер их не отдаёт): `vmess://`/`ss://`,
  sing-box JSON, Clash YAML.
- Любой формат → единая модель узла → outbound. Невалидные узлы отбрасываем с логом.

## Списки доменов (selective)

- Старт: берём как у podkop (community `telegram`, `russia_inside` + его `user_domains`).
- Обязательно **редактируемые** через uci/LuCI (добавить/убрать домены и категории).

## urltest (авто-пинг + переключение)

- `urltest`-outbound объединяет все VLESS; health-check HTTP `generate_204` ЧЕРЕЗ прокси;
  `interval` 30–60 с, `tolerance`, `interrupt_exist_connections: true`.
- `selector`-outbound для ручного override из UI.
- watchdog опрашивает Clash-API (:9091) → near-instant switch + лог/уведомление
  (Telegram-плагин уже подключён — опционально).

## Структура репозитория (правим на Windows, деплой на роутер)

```
V2RAYWRT/
├── README.md
├── PLAN.md
├── package/
│   ├── vpnpool/                 # демон, ucode-модули, procd init, uci-defaults
│   │   ├── files/etc/init.d/vpnpool
│   │   ├── files/etc/config/vpnpool
│   │   ├── files/usr/libexec/vpnpool/{parser.uc,generator.uc,fetch.sh,watchdog.uc,route.sh}
│   │   └── Makefile
│   └── luci-app-vpnpool/        # LuCI-приложение
├── scripts/deploy.sh            # scp через Mac, рестарт, хвост логов
└── test/                        # офлайн-тесты парсера на примерах подписок
```

## Этапы (с критерием приёмки на роутере)

| # | Этап | Готово, когда |
|---|---|---|
| 0 | ✅ Бэкап конфигов podkop/dhcp/network/firewall/sing-box/nft ruleset | **СДЕЛАНО** — `/root/vpnpool-backup-20260605-205941` (+ симлинк `vpnpool-backup-latest`) |
| 1 | ✅ uci-схема + procd-скелет vpnpool | **СДЕЛАНО** — служба стартует/гаснет/респавнит, podkop цел, своих nft/rule нет |
| 2 | ✅ Парсер подписки (ucode) | **СДЕЛАНО** — 16/16 узлов, уник. теги, `sing-box check` OK. Dedup по полной ссылке (НЕ по uuid — он общий!) |
| 3 | ✅ Генератор sing-box #2 (ucode) + `sing-box check` | **СДЕЛАНО** — 19 outbounds (urltest×16 + selector + 16 + direct), tproxy :1603, clash :9091, `check`/`format` OK |
| 4 | ✅ Маршрутизация (nft vpnpool + ip rule + tproxy 1603), scoped-тест | **СДЕЛАНО** — A/B на `ifconfig.co`: RU(direct)→FR(VPN, узел 🇩🇪); контроль остался RU; podkop цел; снос чистый |
| 5 | ✅ «Живой» демон (fetch/build/route/supervise) + failover | **СДЕЛАНО** — whole-LAN selective работает; блок активного узла → urltest сам переключил за ~30–40с, трафик восстановился; чистый stop/disable; podkop цел |
| 6 | ✅ Авто-обновление подписки + откат битого конфига | **СДЕЛАНО** — битая подписка → конфиг не меняется (rollback); недоступный URL → откат на кэш |
| 7 | 🟡 luci-app-vpnpool (JS-дашборд) | **Бэкенд готов и проверен** (ubus vpnpool: status/select/toggle/refresh/url/domains/nodes — все ок, живые пинги, JS отдаётся uhttpd 200). UI-файл задеплоен; ждёт ВИЗУАЛЬНОЙ проверки в браузере (Services → VPN Pool) |
| 8 | README, install/uninstall, бэкап/restore | штатная установка/удаление |

Доводки на потом (не блокеры): refresh в демоне перезапускает sing-box даже если конфиг
не изменился — добавить сравнение md5 и reload только при изменении; near-instant watchdog
(этап 5b); явный bypass zapret под нагрузкой.

### Зафиксированные уроки (диагностированные ошибки)

- **procd сам владеет pidfile** (`procd_set_param pidfile`): демон НЕ должен сам писать/удалять
  его — иначе `daemon.err procd: Failed to remove pidfile`.
- **VLESS-подписка: uuid общий для всех узлов** (это аккаунт), узлы различаются host/sni/sid.
  Dedup по uuid недопустим (схлопывает 8 разных узлов на одном IP в один). Уникальность узла =
  вся ссылка; уникальность sing-box `tag` обеспечиваем суффиксом `#N`.
- **Подписка динамическая**: между запросами меняются и IP, и состав узлов — тесты не должны
  предполагать стабильный список; сверяться с актуальной выгрузкой.
- **UA обязателен**: сервер за QRATOR отдаёт base64 только «клиентскому» UA (v2rayNG); на
  sing-box/clash/default UA — пусто/HTTP 500.
- **tproxy-inbound `network`** — одиночный enum (`tcp`|`udp`); значение `tcp,udp` валит
  `sing-box check`. Чтобы слушать оба протокола — поле опускаем (дефолт = оба).
- **SSH-цепочка Win→Mac→роутер, stdin-гочи (диагностировано вживую):**
  (1) `ssh` ВНУТРИ цикла/скрипта читает stdin скрипта и «съедает» heredoc — для
  вложенных вызовов на Mac используй `ssh -n` (или `</dev/null`).
  (2) Но НЕ ставь `-n` на тот ssh, который ДОЛЖЕН принять heredoc/пайп: `-n`
  редиректит stdin из /dev/null → удалённый `sh -s` получает пустоту и молча ничего
  не делает. Правило: `-n` только на ssh, который НЕ должен потреблять stdin.
- **jq на OpenWrt собран без ONIGURUMA** — `test()/match()/sub()` недоступны; фильтруй
  без регэкспов (точное сравнение, `startswith`/`endswith`).
- **Clash-API: тип узла = `VLESS` (заглавными)**, имена — с эмодзи. Задержки бери из
  bulk `GET /proxies` → `.history|last.delay` (не адресуя по имени в пути; group-delay
  эндпоинт у sing-box пуст). Самоликвидация теста через `(sleep N; teardown)&` спасает,
  если управляющая сессия отвалится.
- **zapret НЕ сломал Reality-аплинки** в тесте (узел 🇩🇪 — 83 мс, проксирование работало)
  → явный `bypass zapret` пока не обязателен; держим в уме как страховку под нагрузкой.
- **Clash-API слушает `192.168.10.1:9091`** (LAN-IP, как задано), НЕ `127.0.0.1:9091` —
  на роутере опрашивать по LAN-IP.
- **Failover latency ~30–40с** (такт urltest `interval=60s`). Для near-instant —
  отдельный watchdog по Clash-API или короче `interval`. Базовое требование (само
  переключается на живой) выполнено; near-instant — опциональное улучшение (5b).
- **nft нормализует `priority -90` → `dstnat + 10`** (dstnat=-100). Наша цепочка идёт
  ПОСЛЕ podkop (mangle -150 / dstnat -100), поэтому yield по марке 0x100000 корректен.

- **Склейка списков ссылок требует явного разделителя-перевода строки.** `sub.raw`
  (декод base64) может НЕ заканчиваться `\n`; при дописывании ручных узлов первая ручная
  ссылка приклеивается к последней строке подписки → парсер (жадный `#.*$`) проглатывает
  ручной узел в «имя» предыдущего. Симптом: ручной узел есть в uci и в списке UI, но не
  появляется в таблице выбора (счётчик узлов не растёт). Фикс: в build.sh собирать
  `{ cat sub.raw; echo; uci get manual_node; }` — `echo` гарантирует разделение.
- **Живое применение правок из UI — через сигнал демону.** add/del узла и правка доменов
  меняют uci, но работающий sing-box их не видит. Бэкенд после `uci commit` шлёт демону
  `USR1` (`kill -USR1 $(cat /var/run/vpnpool.pid)`), демон по trap пересобирает конфиг из
  кэша+manual и горячо перезапускает sing-box. (USR1-trap в busybox ash работает: проверено
  прямым `kill -USR1`.)
- **LuCI JS: блок настроек НЕ перерисовывать поллингом** (затрёт ввод). Поллинг обновляет
  только статус/таблицу узлов; динамические списки (ручные узлы) — отдельный контейнер с id,
  обновляется по действию. `poll.start()` ставить явно.

## Этап 7+ — расширение до полноценного приложения (по запросу)

Решения: **5 вкладок** (Dashboard · Источники · Маршрутизация · Настройки · Диагностика),
порядок **бэкенд → списки → UI**. Между сессиями служба **выключена** (enabled '0').

- [x] **Бэкенд (чанк A):** мульти-источники подписки (uci `list source` + `subscription_url`,
  склейка с переводами строк, dedup); сеттеры `set_option` (failover_interval/tolerance,
  subscription_interval, auto_switch, mode); `add_source/del_source`, `del_subscription`;
  ручной `ping` (дёргает `/proxies/{enc}/delay` по каждому узлу); статус отдаёт sources/
  communities/settings. Демон: USR1=rebuild, USR2=refetch+rebuild; интервал перечитывается.
- [x] **Сообщества (чанк B):** списки itdoginfo через sing-box **remote SRS rule_set**.
  Подтверждено: SRS — **ассеты релиза** `https://github.com/itdoginfo/allow-domains/releases/latest/download/<name>.srs`
  (НЕ в дереве main!). 25 категорий (russia_inside, telegram, meta, youtube, …). В route:
  отдельное правило `{rule_set:[…], outbound:proxy}` + `cache_file` для персистентности.
  Скачивание `direct` (GitHub CDN 185.199.x доступен из RU), cache.db создаётся — проверено.
- [x] **Диагностика-бэкенд** (diag.sh): статус службы/sing-box, сосуществование podkop/zapret,
  выходной IP/страна (direct/ISP), WAN, версия, последние логи — проверено через ubus.
- [x] **Два режима маршрутизации** (uci `mode`): `selective` (проксировать выбранное) и
  `exclude` (проксировать всё, кроме выбранного) — оба проходят `sing-box check`.
- [x] **UI (чанк C): 5 вкладок** — Dashboard / Источники / Маршрутизация / Настройки /
  Диагностика (отдельные JS-вью + меню `firstchild`). Все отдаются (200). Ждёт визуальной
  проверки в браузере.

### Подписка: мульти-клиент / мульти-формат (по запросу)

- Провайдер «Щука VPN» (`vpn.ecobuy.ltd/s/…`) отдаёт **base64-список vless только клиентам
  v2rayNG/v2rayN** (HTTP 200); Happ/sing-box/Hiddify/Streisand/Shadowrocket → **HTTP 500**.
  «JSON» в приложении Happ — его внутренняя метка узла (хранит как sing-box JSON), а не формат
  ответа сервера. Набор узлов **меняется со временем** (динамические IP) — это «динамика».
- **fetch.sh теперь перебирает список UA**, для каждого ответа определяет формат
  (base64 / sing-box JSON / список), парсит, и берёт ответ с МАКСИМУМОМ узлов → провайдеро-
  независимо. Список UA в uci `probe_ua` (дефолт зашит).
- **parser.uc понимает sing-box JSON** (`{outbounds:[…]}`/массив) — берёт только proxy-типы
  (vless/vmess/trojan/ss/hysteria/tuic…), пропуская selector/urltest/direct/block/dns.
  Мультифайловый режим: парсит все источники + ручные узлы за один проход с глобальным
  dedup и уникальными тегами. build.sh склеивает источники из `sources/*.raw` + `manual.links`.

### Язык (по запросу) — финальный подход

- **Контент:** свой i18n (`resources/vpnpool/i18n.js`) — **авто по `navigator.language`**
  (ru* → русский, иначе English), без ручного переключателя. Каждая вью делает
  `var _ = i18n.tr` (переопределяет глобальный `_`), поэтому все `_()` переводятся без
  переписывания. Модуль ОБЯЗАН возвращать класс (`baseclass.extend`) — LuCI инстанцирует
  его в синглтон; plain-object → `factory yields invalid constructor`.
- **Вкладки:** заданы прямо в `menu.d` (по-русски). JS вкладки НЕ трогает.
  *Почему так:* клиентский перевод вкладок дерётся с ре-рендером меню LuCI (SPA) →
  мерцание; а LuCI сам переводит общие слова (Settings/Routing/…) через `base.ru`,
  ломая консистентность. `po2lmo` на роутере нет — родной `.lmo` не собрать. Поэтому
  заголовки вкладок просто захардкожены в меню (система у пользователя русская).
- **Safari агрессивно кэширует** JS LuCI — после правок вью делать Cmd+Option+E; «Sources
  на английском» был именно старый кэш Safari (в Chrome всё верно).

### Уроки расширения

- **itdoginfo SRS живут в GitHub Releases, не в репозитории.** `git/trees` их не покажет;
  брать из `releases/latest` (assets) или по `releases/latest/download/<name>.srs`.
- **`sing-box check` НЕ скачивает remote rule_set** (проходит мгновенно) — значит build с
  remote-сообществами не зависит от сети; загрузка SRS происходит в рантайме.
- **rule_set и domain_suffix — РАЗНЫЕ route-правила** (внутри одного правила матчеры по И).
- **busybox без `timeout`** — для таймаута фоновый процесс + `sleep`/`kill`, либо `curl -m`.
- **Мульти-источник: каждый источник заканчивать `echo`** (как и manual) — иначе склейка
  ссылок (тот же баг, что с trailing newline).

### Архитектура подтверждена end-to-end (этапы 0–5)

Демон сам делает: fetch подписки (base64→vless) → parser → generator → `sing-box check`
→ запуск sing-box → whole-LAN selective tproxy (coexist с podkop) → supervise + периодический
refresh. urltest даёт авто-пинг и failover. Управление сейчас через uci/CLI; остаётся UI
(LuCI), доводка авто-обновления (этап 6) и упаковка (этап 8).

## Дев-процесс и безопасность

- Редактируем на Windows → `scp` через Mac-bridge → тест на роутере, хвост логов.
- Перед стартом — бэкап `/etc/config/{podkop,dhcp,network}`, `/etc/sing-box/config.json`,
  `nft list ruleset`.
- Applier с откатом: роутер ни на одном шаге не остаётся без интернета.
- Каждый этап откатывается независимо.

## Риски

- DNS у podkop (fakeip): наш selective — по SNI-sniff; ECH/шифр.SNI не покрываем.
- zapret NFQUEUE на исходящих 443: вывести наши VLESS-аплинки из-под zapret.
- Два tproxy-перехвата: строгий порядок «уступи podkop» (mark 0x100000 → return).
- urltest переключает по тактам health-check: короткий interval + watchdog для скорости.
- Reality+vision в urltest: health-check открывает тест-соединения на узлы — норм.

## Что выяснить перед кодом — статус

- [x] fwmark/таблица/порт/Clash-API/нфт-сеты podkop — сняты (см. раскладку).
- [x] zapret-хуки и марки — сняты.
- [x] DNS-механизм podkop (dnsmasq→127.0.0.42, fakeip) — снят.
- [x] Включать свой `external_controller` :9091 (да, для watchdog/LuCI пингов).
- [x] Списки доменов: старт — как у podkop, сделать редактируемыми (uci/LuCI).
- [x] Подписка и её формат: base64-список vless reality, UA v2rayNG, expire-заголовок.

## Готовая альтернатива (на случай build-vs-buy)

В фидах есть `v2rayA` (`luci-app-v2raya`) — фактически готовый «v2RayTun для роутера»
(подписки, веб-UI, тесты задержки, переключение). Оставлено как запасной вариант;
основной путь — своё приложение vpnpool по плану выше.
