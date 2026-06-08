# VPN Pool (vpnpool) — VLESS subscription manager with auto‑failover for OpenWrt

<p align="right"><b>English</b> · <a href="README.ru.md">Русский 🇷🇺</a></p>

> **OpenWrt app that turns an auto‑updating VLESS/Reality subscription into an
> always‑working VPN** — like **v2RayTun / Happ, but on your router**. It pings
> all nodes, **automatically switches to a working VLESS server** when the current
> one dies, and routes your LAN (whole‑network or per‑device, selected sites or
> everything) through **sing‑box**. Manage everything from a clean LuCI dashboard.

<p align="center">
  <a href="https://github.com/roman-png/VPNpool/actions/workflows/build.yml"><img alt="Build .ipk" src="https://github.com/roman-png/VPNpool/actions/workflows/build.yml/badge.svg"></a>
  <img alt="License: GPL-2.0" src="https://img.shields.io/badge/License-GPL--2.0-blue.svg">
  <img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10-blue">
  <img alt="Engine" src="https://img.shields.io/badge/engine-sing--box-success">
</p>

**Keywords:** OpenWrt VLESS, VLESS Reality OpenWrt, sing-box subscription, sing-box
failover, auto switch VPN router, v2RayTun for router, Happ for router, podkop
alternative, passwall alternative, vless vmess trojan shadowsocks subscription,
xtls-rprx-vision reality, urltest auto failover, обход блокировок роутер OpenWrt,
автопереключение VLESS, подписка VLESS на роутер, антизапрет sing-box.

---

## What it does

- 📡 **Auto‑updating subscription** — paste a subscription URL (base64 list **or**
  sing‑box JSON). Multiple sources supported (e.g. auto‑updating raw config files
  from a repo). **Multi‑client User‑Agent probing**: tries several client UAs and
  keeps the response with the most nodes, so it keeps working if the provider
  changes format.
- 🔀 **Automatic ping + failover** — sing‑box `urltest` health‑checks every node and
  **switches to a working VLESS server automatically** when the active one stops
  responding. Manual override and manual "ping all" too.
- 🎛️ **Configurable auto‑pool** — on the Dashboard, click **⚙ Configure** next to the
  AUTO row to pick **exactly which nodes take part in automatic switching**.
  Unchecked nodes stay available for manual selection but are never auto‑picked.
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

---

## 📸 Screenshots

| Dashboard | Sources |
|---|---|
| ![Dashboard](docs/screenshots/dashboard.jpg) | ![Sources](docs/screenshots/sources.jpg) |
| **Routing** | **Settings** |
| ![Routing](docs/screenshots/routing.jpg) | ![Settings](docs/screenshots/settings.jpg) |

---

## 🧰 Supported & recommended hardware

vpnpool itself is tiny and **architecture‑independent**. The real requirement is
**sing‑box**, which is a ~38 MB binary.

- **Minimum:** any router on **OpenWrt 23.05 / 24.10** with **≥ 128 MB RAM**. For
  storage you need room for sing‑box (~38 MB). Routers with **16 MB flash** can still
  run it — see [Routers with small flash (16 MB)](#-routers-with-small-flash-16-mb)
  to install sing‑box into RAM.
- **Recommended:** **≥ 256 MB flash** (or USB/extroot) and **≥ 512 MB RAM**, e.g.:
  - **Cudy TR3000**, **GL.iNet** Flint/Beryl, any **MediaTek Filogic** (MT7981/MT7986),
  - **Qualcomm IPQ807x** boards,
  - **x86 / x86_64** mini‑PC or VM,
  - **Raspberry Pi 4** running OpenWrt.

> **Architecture note:** our two packages ship as `_all` (one file works on **every**
> CPU). Architecture only matters for the *dependencies* (sing‑box, kmods), which
> opkg pulls from the standard OpenWrt feeds for **your** device automatically.
> Check your arch with `opkg print-architecture` if you ever need it.

### 💾 Footprint

| Component | Installed size |
|---|---|
| `vpnpool` + `luci-app-vpnpool` (our code) | **~128 KB** |
| `sing-box` (the engine) | **~38 MB** (ipk ~14 MB) |
| `jq` / `curl` / `ucode` / kmods | a few hundred KB |
| **Total with all dependencies** | **~40 MB** |

---

## 🚀 Install

### Option A — one line (recommended)

Installs (or upgrades) the latest release. Downloads the prebuilt packages from
GitHub Releases and pulls dependencies from the standard OpenWrt feeds. Your
`/etc/config/vpnpool` (subscription, Telegram, routing) is preserved on upgrade.

```sh
sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

If your BusyBox `wget` doesn't support `<(...)`:

```sh
wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh
sh /tmp/vpnpool-install.sh
```

### Option B — prebuilt `.ipk` from Releases

Our packages are arch‑independent `_all` files — **download the same two files for
any router**:

1. Grab `vpnpool_*_all.ipk` and `luci-app-vpnpool_*_all.ipk` from the
   [latest release](https://github.com/roman-png/VPNpool/releases/latest).
2. Copy them to the router and install:

```sh
opkg update
opkg install ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk
```

`sing-box`, `jq`, `curl`, `ucode` and the needed kernel modules are pulled in as
dependencies. Then open **LuCI → Services → VPN Pool**.

### Option C — opkg feed (update with `opkg update`)

The [GitHub Pages opkg feed](https://roman-png.github.io/VPNpool) is **signed**
with our usign key (fingerprint `807479500e0ce219`). Install the public key once
so opkg can verify the feed, then add it and install/upgrade like any package —
**signature checking stays on**:

```sh
# 1. install our public key (keeps opkg signature verification enabled)
wget -O /etc/opkg/keys/807479500e0ce219 https://roman-png.github.io/VPNpool/vpnpool-feed.pub
# 2. add the feed and install
echo "src/gz vpnpool https://roman-png.github.io/VPNpool" >> /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-vpnpool
```

<details>
<summary>Fallback: install without the key (disables signature checking globally)</summary>

If you don't install the key, opkg rejects the unsigned-to-it feed and drops the
package list. You can instead disable opkg's signature check — but note this turns
verification **off for every feed, including the official OpenWrt ones**, so the
key method above is preferred.

```sh
# comment out the check_signature line (NOTE: setting it to 0 is NOT enough)
sed -i '/^[[:space:]]*option[[:space:]]\+check_signature/s/^/# /' /etc/opkg.conf
opkg update
# ...later, to re-enable verification:
sed -i 's/^#[[:space:]]*\(option[[:space:]]\+check_signature\)/\1/' /etc/opkg.conf
```

</details>

### Option D — build from source (OpenWrt SDK)

```sh
# inside an OpenWrt SDK for your target
git clone https://github.com/roman-png/VPNpool package/vpnpool-src
./scripts/feeds update -a && ./scripts/feeds install -a
make package/vpnpool/compile V=s
make package/luci-app-vpnpool/compile V=s
# .ipk appear under bin/packages/<arch>/...
```

---

## 📟 Routers with small flash (16 MB)

sing‑box (~38 MB) does not fit in 16 MB of flash, but our packages do (~128 KB).
The trick (same idea podkop uses): keep vpnpool in flash and **(re)install sing‑box
into RAM (`/tmp`) on every boot**, triggered when the WAN interface comes up.

OpenWrt already defines a RAM install destination in `/etc/opkg.conf`
(`dest ram /tmp`), so `opkg install -d ram …` lands the binary under `/tmp`.

**1. Install zram‑swap** (gives the small router more usable memory for `opkg`):

```sh
opkg update
opkg install zram-swap
/etc/init.d/zram enable
/etc/init.d/zram start
```

**2. Install vpnpool itself, but WITHOUT sing‑box** (it won't fit in flash). Install
the small dependencies normally, then our packages with `--nodeps`:

```sh
opkg update
opkg install jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full ca-bundle
# get the two _all .ipk (e.g. via the release page or install.sh's download step), then:
opkg install --nodeps ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk
```

**3. Do NOT autostart vpnpool at boot** — sing‑box won't exist yet. The hotplug hook
below starts it after sing‑box is in place:

```sh
/etc/init.d/vpnpool disable
```

**4. Create the boot hook** that installs sing‑box into RAM and starts vpnpool when
the WAN comes up (runs on every reboot, needs internet):

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

**5. Reboot (or replug WAN) and verify:**

```sh
logread -e vpnpool        # should show "sing-box installed in RAM, vpnpool started"
sing-box version          # confirms the RAM symlink resolves
```

> **Trade‑offs:** sing‑box (~14 MB ipk) is re‑downloaded into RAM on every boot, so
> the router needs working internet at startup and enough free RAM (~128 MB+). If
> your WAN is named differently (e.g. `wan6`, `wwan`), adjust the `INTERFACE` check.

---

## ⚙️ Quick start

1. **Sources** tab → paste your subscription URL → **Update now**.
2. **Routing** tab → pick mode (proxy selected / proxy all‑except) → choose community
   lists and/or add domains.
3. **Dashboard** → **Turn ON**. Watch live pings; the green ★ is the active node.
   Use **⚙ Configure** on the AUTO row to choose which nodes auto‑switch.
4. **Diagnostics** → **Test exit via VPN** to confirm your real exit IP/country.

CLI equivalent:

```sh
uci set vpnpool.main.subscription_url='https://example.com/sub'
uci set vpnpool.main.enabled='1'; uci commit vpnpool
/etc/init.d/vpnpool enable; /etc/init.d/vpnpool restart
```

---

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
the data plane is **sing‑box**, exactly like v2RayTun/Happ wrap an engine.

---

## 🆚 Compared to podkop / passwall / homeproxy

| | **vpnpool** | podkop | passwall2 | homeproxy |
|---|---|---|---|---|
| Engine | sing‑box | sing‑box | xray/sing‑box | sing‑box |
| Auto‑updating subscription | ✅ multi‑source, multi‑UA | partial | ✅ | ✅ |
| **Auto ping + failover** | ✅ urltest + watchdog | manual select | ✅ | ✅ |
| **Pick which nodes auto‑switch** | ✅ | — | — | — |
| Community SRS lists | ✅ (itdoginfo) | ✅ | own | own |
| Per‑client routing | ✅ | — | ✅ | partial |
| VPN‑exit self‑test | ✅ | ✅ | partial | — |
| Telegram alerts | ✅ | — | — | — |
| Coexists with podkop | ✅ (by design) | n/a | — | — |
| Auto RU/EN UI | ✅ | RU/EN | RU/EN | EN/ZH |

---

## 🔐 Notes

- **DNS:** routing is done by **SNI sniffing**, so DNS games aren't required. On a
  fresh OpenWrt this just works with the system resolver. If you previously ran
  podkop and remove it, restore dnsmasq's normal upstream (podkop points it at its
  own `127.0.0.42` fake‑IP resolver).
- **GitHub reachability:** community SRS rule‑sets are downloaded from GitHub
  releases; if blocked, route GitHub through the proxy first.
- **Security:** the Clash API is bound to `127.0.0.1` only.

## 🗺️ Roadmap

- Near‑instant active‑probe failover (below the urltest interval)
- DoH‑over‑proxy DNS for fully leak‑free selective routing
- Full IPv6 tproxy (proxy mode, not just block)
- Clash YAML subscription parsing; node search/filter

## 🤝 Contributing

Issues and PRs welcome. The whole thing is ucode + shell + a little LuCI JS — no
compilation needed.

## 📄 License

[GPL‑2.0‑only](LICENSE) © 2026 roman‑png
