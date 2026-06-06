# VPN Pool (vpnpool) — VLESS subscription manager with auto‑failover for OpenWrt

> **OpenWrt app that turns an auto‑updating VLESS/Reality subscription into an
> always‑working VPN** — like **v2RayTun / Happ, but on your router**. It pings
> all nodes, **automatically switches to a working VLESS server** when the current
> one dies, and routes your LAN (whole‑network or per‑device, selected sites or
> everything) through **sing‑box**. Manage everything from a clean LuCI dashboard.

<p align="center">
  <a href="https://github.com/roman-png/VPNpool/actions/workflows/build.yml"><img alt="Build .ipk" src="https://github.com/roman-png/VPNpool/actions/workflows/build.yml/badge.svg"></a>
  <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg">
  <img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10-blue">
  <img alt="Engine" src="https://img.shields.io/badge/engine-sing--box-success">
</p>

**Keywords:** OpenWrt VLESS, VLESS Reality OpenWrt, sing-box subscription, sing-box
failover, auto switch VPN router, v2RayTun for router, Happ for router, podkop
alternative, passwall alternative, vless vmess trojan shadowsocks subscription,
xtls-rprx-vision reality, urltest auto failover, обход блокировок роутер OpenWrt,
автопереключение VLESS, подписка VLESS на роутер, антизапрет sing-box.

---

## 🇬🇧 What it does

- 📡 **Auto‑updating subscription** — paste a subscription URL (base64 list **or**
  sing‑box JSON). Multiple sources supported (e.g. auto‑updating raw config files
  from a repo). **Multi‑client User‑Agent probing**: tries several client UAs and
  keeps the response with the most nodes, so it keeps working if the provider
  changes format.
- 🔀 **Automatic ping + failover** — sing‑box `urltest` health‑checks every node and
  **switches to a working VLESS server automatically** when the active one stops
  responding. Manual override and manual "ping all" too.
- 🧭 **Selective routing** — proxy **only chosen lists/domains** (rest direct) **or
  everything except them** (full‑VPN with exceptions). Community domain lists from
  [itdoginfo/allow‑domains](https://github.com/itdoginfo/allow-domains) as auto‑updating
  **sing‑box SRS rule‑sets** (Telegram, Russia‑inside, YouTube, Meta, Twitter/X,
  Discord, …) plus your own domains.
- 👥 **Per‑client routing** — route the whole LAN, **exclude** specific devices
  (they bypass the VPN), or allow **only** specific devices.
- 🧩 **Protocols** — VLESS (Reality + `xtls‑rprx‑vision`), VMess, Trojan, Shadowsocks,
  plus sing‑box JSON configs.
- 🛡️ **IPv6 leak guard** (fail‑closed), **Clash API bound to loopback** (not exposed
  on the LAN), **kill‑switch‑style** fail‑closed behaviour.
- 🤝 **Coexists** with [podkop](https://github.com/itdoginfo/podkop) and zapret
  (auto‑detected, non‑colliding marks/tables/ports) — or runs **standalone**.
- 🔔 **Telegram alerts** — node failover, subscription expiry, start/stop.
- 🖥️ **LuCI dashboard** (5 tabs, auto **RU/EN**): live node pings, traffic & connection
  stats, on/off, manual select, sources, routing, settings, diagnostics (incl. a real
  **"test exit via VPN"** check), backup/restore.

## 🇷🇺 Что это

**vpnpool** — приложение для OpenWrt: аналог **v2RayTun/Happ прямо на роутере**.
Берёт **автообновляемую подписку VLESS** (base64 или sing‑box JSON, несколько
источников, перебор клиентских UA), **сам пингует узлы и переключается на рабочий
VLESS‑сервер**, когда текущий перестаёт отвечать, и маршрутизирует трафик сети через
**sing‑box** — выборочно (только нужные списки/домены) или всё, кроме них; для всей
сети или **по устройствам**. Списки сообществ (Telegram, Россия, YouTube и т.д.) —
авто‑SRS из [itdoginfo/allow‑domains](https://github.com/itdoginfo/allow-domains).
Поддержка VLESS/VMess/Trojan/Shadowsocks, защита от IPv6‑утечки, уведомления в
Telegram, веб‑интерфейс LuCI (5 вкладок, авто RU/EN). **Уживается с podkop/zapret**
или работает самостоятельно.

---

## 📸 Screenshots

| Dashboard | Routing | Diagnostics |
|---|---|---|
| ![Dashboard](docs/screenshots/dashboard.png) | ![Routing](docs/screenshots/routing.png) | ![Diagnostics](docs/screenshots/diagnostics.png) |

> Add your screenshots under `docs/screenshots/`.

## 🚀 Install

### Option A — prebuilt `.ipk` (recommended)

1. Download the `.ipk` for your architecture from the
   [latest release](https://github.com/roman-png/VPNpool/releases) (CI builds for
   aarch64 / mipsel / x86_64).
2. Copy to the router and install:

```sh
opkg install vpnpool_*.ipk luci-app-vpnpool_*.ipk
```

`sing-box`, `jq`, `curl`, `ucode` and the needed kernel modules are pulled in as
dependencies. Then open **LuCI → Services → VPN Pool**.

> Not sure of your arch? Run `opkg print-architecture` on the router.

### Option B — build from source (OpenWrt SDK)

```sh
# inside an OpenWrt SDK for your target
git clone https://github.com/roman-png/VPNpool package/vpnpool-src
./scripts/feeds update -a && ./scripts/feeds install -a
make package/vpnpool/compile V=s
make package/luci-app-vpnpool/compile V=s
# .ipk appear under bin/packages/<arch>/...
```

### Option C — manual (no opkg)

Copy the trees from `package/vpnpool/files/` and `package/luci-app-vpnpool/files/`
to `/` on the router, `chmod +x /etc/init.d/vpnpool /usr/libexec/vpnpool/* /usr/libexec/rpcd/vpnpool`,
install deps (`opkg install sing-box jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full`),
then `/etc/init.d/rpcd restart`.

## ⚙️ Quick start

1. **Sources** tab → paste your subscription URL → **Update now**.
2. **Routing** tab → pick mode (proxy selected / proxy all‑except) → choose community
   lists and/or add domains.
3. **Dashboard** → **Turn ON**. Watch live pings; the green ★ is the active node.
4. **Diagnostics** → **Test exit via VPN** to confirm your real exit IP/country.

CLI equivalent:

```sh
uci set vpnpool.main.subscription_url='https://example.com/sub'
uci set vpnpool.main.enabled='1'; uci commit vpnpool
/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart
```

## 🧠 How it works

```
LuCI (5 tabs) ── ubus/rpcd ── vpnpoold (ucode + shell, procd)
                                  │ fetch (multi-UA) → parse → generate → sing-box check
                                  ▼
                          sing-box (the engine)
   inbound: tproxy 127.0.0.1:1603  +  local mixed SOCKS/HTTP :1605 (test/apps)
   outbound: urltest "auto" (ping + failover) + selector + nodes + direct
   route: sniff SNI → community SRS / domains → proxy (or direct in exclude mode)
                                  ▲
   nftables (table inet vpnpool): mark LAN 80/443 → fwmark 0x400000 → table 142 →
   tproxy; yields to podkop; IPv6 fail-closed; per-client include/exclude
```

The control plane (subscription, parsing, config generation, watchdog, UI) is ours;
the data plane is **sing‑box**, exactly like v2RayTun/Happ wrap an engine. See
[PLAN.md](PLAN.md) for the full design and engineering notes.

## 🆚 Compared to podkop / passwall / homeproxy

| | **vpnpool** | podkop | passwall2 | homeproxy |
|---|---|---|---|---|
| Engine | sing‑box | sing‑box | xray/sing‑box | sing‑box |
| Auto‑updating subscription | ✅ multi‑source, multi‑UA | partial | ✅ | ✅ |
| **Auto ping + failover** | ✅ urltest + watchdog | manual select | ✅ | ✅ |
| Community SRS lists | ✅ (itdoginfo) | ✅ | own | own |
| Per‑client routing | ✅ | — | ✅ | partial |
| VPN‑exit self‑test | ✅ | ✅ | partial | — |
| Telegram alerts | ✅ | — | — | — |
| Coexists with podkop | ✅ (by design) | n/a | — | — |
| Auto RU/EN UI | ✅ | RU/EN | RU/EN | EN/ZH |

## 🔐 Notes

- **DNS:** routing is done by **SNI sniffing**, so DNS games aren't required. On a
  fresh OpenWrt this just works with the system resolver. If you previously ran
  podkop and remove it, restore dnsmasq's normal upstream (podkop points it at its
  own `127.0.0.42` fake‑IP resolver).
- **GitHub reachability:** community SRS rule‑sets are downloaded from GitHub
  releases; if blocked, set `download_detour` to the proxy (roadmap toggle).
- **Security:** the Clash API is bound to `127.0.0.1` only.

## 🗺️ Roadmap

- Near‑instant active‑probe failover (below the urltest interval)
- DoH‑over‑proxy DNS for fully leak‑free selective routing
- Full IPv6 tproxy (proxy mode, not just block)
- Clash YAML subscription parsing; node search/filter

## 🤝 Contributing

Issues and PRs welcome. The whole thing is ucode + shell + a little LuCI JS — no
compilation. See [PLAN.md](PLAN.md).

## 📄 License

[MIT](LICENSE) © 2026 roman‑png
