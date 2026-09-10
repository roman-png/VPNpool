# VPNpool — VLESS / Reality subscription manager with auto-failover for OpenWrt (sing-box + AmneziaWG)

<p align="right"><b>English</b> · <a href="README.ru.md">Русский 🇷🇺</a></p>

> **An OpenWrt app that turns an auto-updating VLESS / Reality subscription into an
> always-working VPN** — like **v2RayTun or Happ, but on your router**. It health-checks
> every node against the services *you* care about, **switches to a working server
> automatically** when the active one dies, and routes your LAN (whole-network or
> per-device, selected sites or everything) through **sing-box**. **AmneziaWG**
> (obfuscated WireGuard) nodes join the same pool. Everything is managed from a clean
> LuCI dashboard, a Telegram bot, or plain `uci`.

<p align="center">
  <a href="https://github.com/roman-png/VPNpool/actions/workflows/build.yml"><img alt="Build .ipk" src="https://github.com/roman-png/VPNpool/actions/workflows/build.yml/badge.svg"></a>
  <a href="https://github.com/roman-png/VPNpool/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/roman-png/VPNpool?label=release"></a>
  <img alt="License: GPL-3.0" src="https://img.shields.io/badge/License-GPL--3.0-blue.svg">
  <img alt="OpenWrt 23.05 / 24.10" src="https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10-blue">
  <img alt="Engine: sing-box" src="https://img.shields.io/badge/engine-sing--box-success">
  <img alt="Protocols: VLESS VMess Trojan Shadowsocks AmneziaWG" src="https://img.shields.io/badge/protocols-VLESS%20%C2%B7%20VMess%20%C2%B7%20Trojan%20%C2%B7%20SS%20%C2%B7%20AmneziaWG-informational">
</p>

---

## Contents

- [Why vpnpool](#why-vpnpool)
- [Features](#features)
  - [Subscriptions and nodes](#subscriptions-and-nodes)
  - [Health check, failover and self-healing](#health-check-failover-and-self-healing)
  - [AmneziaWG (obfuscated WireGuard)](#amneziawg-obfuscated-wireguard)
  - [Routing](#routing)
  - [Security and leak protection](#security-and-leak-protection)
  - [Monitoring, control and automation](#monitoring-control-and-automation)
  - [The LuCI app: five tabs](#the-luci-app-five-tabs)
- [Screenshots](#-screenshots)
- [Supported hardware](#-supported--recommended-hardware)
- [Install](#-install)
- [Routers with small flash (16 MB)](#-routers-with-small-flash-16-mb)
- [Quick start](#️-quick-start)
- [How it works](#-how-it-works)
- [Configuration reference (uci)](#️-configuration-reference-uci)
- [Compared to podkop / passwall / homeproxy](#-compared-to-podkop--passwall--homeproxy)
- [FAQ](#-faq)
- [Troubleshooting](#-troubleshooting)
- [Limitations and notes](#-limitations-and-notes)
- [Roadmap](#️-roadmap)
- [Development](#-development)

---

## Why vpnpool

Phone clients (v2RayTun, Happ, Hiddify) ping a whole subscription and hop to a working
server by themselves. Router packages usually don't: you paste one node, and when that
node dies the whole house is offline until you log into LuCI.

vpnpool is the missing control plane. It keeps the **entire subscription** alive as a
pool, decides which nodes are actually usable **by opening the sites you listed**
(not by ping alone), keeps the pool healthy in the background, and never leaves the LAN
pointed at a dead tunnel.

---

## Features

### Subscriptions and nodes

- 📡 **Auto-updating subscription** — paste a subscription URL (base64 list **or**
  sing-box JSON). **Multi-client User-Agent probing**: nine client UAs are tried and the
  **first one that returns usable nodes wins** (the next UA is only tried on an empty
  answer), so panels that serve only "real" clients keep working without hammering them.
  If the fetch fails completely, the offline cache is reused — and you get a Telegram
  warning once that cache is 3+ days old.
- 🧩 **Multiple subscriptions** — extra full subscriptions are merged into the same pool
  (adding one reports how many nodes it brought, or the HTTP code if it failed).
- 🔎 **Import from a source list** — point vpnpool at any link list, it fetches it
  read-only in the background, pings the servers, and shows a **pick-what-you-want
  modal** (All reachable / All / None) before anything is imported. Saved sources can be
  re-fetched with ⟳.
- ✍️ **Manual nodes and bulk import** — add a single `vless://` link, paste a batch of
  links / a base64 subscription, or load a `.txt` file.
- 🧩 **Protocols** — VLESS (Reality + `xtls-rprx-vision`), VMess, Trojan, Shadowsocks and
  ready-made sing-box JSON configs (their Hysteria/TUIC outbounds are picked up too), plus
  [AmneziaWG](#amneziawg-obfuscated-wireguard).
- 💾 **Saved nodes** — star (⭐) any node to keep it in a **separate persistent archive**
  that survives subscription expiry. Saved nodes that are no longer in the live
  subscription get their own **"Saved (inactive)"** list, and one button puts them back
  into the active pool. Optional **auto-snapshot** keeps a bounded fallback set of
  currently reachable nodes (your manual ⭐ picks are never evicted). Deleting nodes —
  even in bulk — never touches this archive.
- 🗑️ **Node management** — checkboxes + bulk delete (one rebuild for the whole
  selection), per-row delete, deactivate. Deleting a subscription node hides it so it
  won't come back on refresh; deleting the **whole subscription** removes its nodes and
  **auto-activates your saved ones** so the router stays connected.
- 🔗 **Share and export** — per-node share link + **offline QR** (move a node to your
  phone), and export of saved / manual / all nodes as a base64 subscription. The QR is
  rendered **client-side**, so node secrets never leave the router.
- 📊 **Subscription data quota** — parses the panel's `subscription-userinfo` header and
  shows **used / total GB** with a progress bar and the expiry date (plus a Telegram
  alert when less than 10% is left).
- 🔎 **Search, filter, sort** — find a node by name or server, show only reachable ones,
  sort by ping / name / traffic. Useful once a subscription has hundreds of nodes.

### Health check, failover and self-healing

- 🎯 **Service-accurate node check** — you list **which services must actually work**
  (`www.youtube.com`, one per line, in *Settings → Node check*) and **that is the single
  criterion** of a usable node. Every node is probed end-to-end through the Clash delay
  API against *your* services and is kept in auto-switching only if it opens **every**
  one of them. This drops the "**pings fine, service dead**" nodes — expired-account
  placeholders, over-quota or geo-blocked exits — that TCP-ping and even reach a CDN but
  can't carry the traffic you care about. The **same service set** drives urltest,
  failover and the watchdog, so the whole stack agrees on what "working" means.
  A node is demoted only after failing several checks in a row (anti-flap, configurable
  strikes and per-check retries), stays selectable manually, and the pool is never
  emptied. An empty list falls back to a generic connectivity check.
- 🔀 **Automatic ping + failover** — sing-box `urltest` health-checks the pool and
  switches to a working node when the active one stops responding. Manual override and a
  manual "ping all" are there too.
- 🩺 **Tunnel self-heal watchdog** — the supervisor probes the tunnel end-to-end (not just
  the sing-box PID); if it stays dead while the WAN is up (after a warm-up grace,
  confirmed over several probes), sing-box is restarted and the stale urltest cache is
  wiped.
- 🚦 **Fail-safe routing (1.4.3)** — the LAN is **never** redirected into a tunnel that
  isn't proven to work. On start vpnpool waits for a real end-to-end probe; if no node
  answers (empty or expired subscription, all exits dead), the nft rules are **not
  installed at all** — the LAN keeps working on a direct connection, the log says so
  plainly, and a Telegram notice is sent. A background retry every 15 s brings routing up
  the moment a node becomes reachable. The same check gates every config reload.
- 🧹 **Dead-node prefilter** — unreachable servers are TCP-probed in batches at build time
  and kept out of the urltest pool, so a churning subscription full of dead hosts can't
  pile up hung probe sockets and stall pinging of the live nodes (they stay available for
  manual selection).
- 📌 **Preferred node with switch-back** — pin a favourite node right on the Dashboard
  (📌 on any node row): it is used while it is reachable, control goes to auto if it dies,
  and it **switches back** when it recovers (anti-flap hysteresis on top of urltest
  tolerance). Applied live — no tunnel bounce. The pin auto-clears if the tag disappears
  from the subscription or lands in the dead set.
- 🎛️ **Configurable auto-pool** — **⚙ Configure** next to the AUTO row picks exactly which
  nodes take part in automatic switching. Unchecked nodes remain available for manual
  selection but are never auto-picked. Demoted and excluded nodes live in their own
  **"Out of the auto-pool"** list with one-click **↩ Return to auto** (a forced node is
  badged ★ and can be handed back to the filter later).
- 🌐 **IPv4-first DNS strategy** — sing-box's own health probes resolve IPv4 first
  (`dns_strategy`, default `prefer_ipv4`), so a router that receives AAAA records without
  IPv6 transit through the nodes doesn't show a false "0 ping" on working nodes.
- ⚡ **Per-node real speed test** — on-demand throughput in Mbit/s, not just ping (with a
  free-memory guard so it can't OOM a 16 MB router).
- 🎬 **Per-node unlock test** — check what each node actually opens (YouTube / ChatGPT /
  Netflix / Instagram / Telegram / Google) and see the badges right in the node row.

### AmneziaWG (obfuscated WireGuard)

AmneziaWG survives mobile-carrier DPI in Russia where TLS/Reality handshakes get reset,
so vpnpool treats it as a **first-class pool member**, not a separate mode:

- **Import** an AmneziaWG `.conf` **or an AmneziaVPN `vpn://` link** on the **Sources**
  tab. `vpn://` is decoded **on the router** (a pure-ucode RFC 1951 inflate, because
  OpenWrt has no zlib CLI) — no Amnezia app, no online decoder, nothing leaves the box.
- **All AWG fields are honoured**: `Jc/Jmin/Jmax`, `S1–S4`, the `H1–H4` magic headers
  (including AWG 2.x `lo-hi` ranges), `I1–I5`, `PresharedKey`, `PersistentKeepalive`,
  `MTU` (defaults to 1280 when S3/S4 are set), multiple `Address` entries.
- **One pool, one logic** — an AWG node joins the same `urltest` auto-switching, the same
  service check and the same watchdog as VLESS nodes. It is only exempt from the TCP
  prefilter (that probe speaks HTTPS and can't see a UDP endpoint), so a healthy AWG node
  is never dropped for the wrong reason.
- Nodes are stored as individual files under `/etc/vpnpool/awg/*.conf`, get their own
  **"AmneziaWG nodes"** section on Sources and an **AmneziaWG** group on the Dashboard,
  and are deleted reliably by tag.
- In the generated config they become top-level **`endpoints[]`** (WireGuard is not an
  outbound in sing-box ≥ 1.13).
- ⚙️ **Requires the AWG sing-box fork** — install with `VPNPOOL_AWG=1` (see
  [Install](#-install)). On a stock sing-box **the whole AmneziaWG UI stays hidden**
  (the daemon caches the binary's capability and reports it to the UI), so a standard
  install shows no dead controls.

### Routing

- 🧭 **Selective routing** — proxy **only the chosen lists/domains** (everything else
  direct) **or everything except them** (full VPN with exceptions). **26 community domain
  lists** from [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) are
  used as auto-updating **sing-box SRS rule-sets** (Telegram, Russia-inside, YouTube,
  Meta, Twitter/X, Discord, …), plus your own domains.
- 👥 **Per-client routing** — route the whole LAN, **exclude** specific devices (they
  bypass the VPN) or allow **only** specific devices. Pick devices **by name from the
  DHCP lease list** — they are matched by **MAC**, so a profile survives DHCP IP changes
  and offline devices stay in the list; static or unknown hosts can still be added as raw
  IPv4.
- 🧠 **Adaptive routing** — vpnpool watches which hosts go direct, compares direct vs
  proxy for the new ones, and auto-routes through the VPN exactly those that are blocked
  for a direct connection (RST/timeout) — the proxy list maintains itself for *your* ISP.
  Plus a one-click "this site is blocked" field.
- 🛡️ **Anti-DPI, three levels** — **off / on** (sing-box `tls_fragment`: split the TLS
  ClientHello so plaintext-SNI DPI can't match it) **/ aggressive**
  (`tls_record_fragment` as well). Defeats *basic* filtering only; against robust
  censorship (TSPU-class DPI) run [zapret](https://github.com/bol-van/zapret) alongside —
  vpnpool coexists with it and reports it in Diagnostics.
- 🤝 **Coexists** with [podkop](https://github.com/itdoginfo/podkop) and zapret —
  non-colliding fwmark, routing table, tproxy port, nft table and Clash API port, and the
  nft chain explicitly yields traffic already marked by podkop. Or run it standalone.

### Security and leak protection

- 🛡️ **IPv6 leak guard** (fail-closed: LAN IPv6 forwarding is rejected while the tunnel is
  IPv4-only), opt-in **kill-switch** (fail-closed IPv4 in full-tunnel mode: if sing-box
  dies, marked traffic dies with it instead of leaking), opt-in **DNS-leak guard** (LAN
  port 53 goes through the tunnel).
- 🔐 **Clash API bound to loopback** (`127.0.0.1:9091`), never exposed to the LAN.
- 🔁 **Config rollback** — every generated config goes through `sing-box check`; a broken
  subscription or a single malformed node can't take the tunnel down (the offending
  `outbound[N]`/`endpoint[N]` is dropped and the build retried, and an unusable result
  falls back to the previous config).

### Monitoring, control and automation

- 📈 **Live per-node and per-client traffic** — how much goes through each node and each
  LAN device (with DHCP hostnames), plus connection counts and current up/down speed.
- 🤖 **Two-way Telegram bot** — an **inline button menu** (`/menu`): tap to switch node,
  run a speed test, toggle routing, see status / quota / clients. Slash commands work too
  (`/status /nodes /switch /speedtest /quota /saved /clients /on /off /refresh /help`),
  locked to your chat id and tunnelled through the VPN so it works where
  `api.telegram.org` is blocked. It runs as **its own supervised procd service**, and
  `/on` `/off` only toggle *routing* — the tunnel (and therefore the bot) stays up.
- 🔔 **Telegram alerts** — failover, subscription expiry and quota, start/stop, routing
  up/down, stale offline cache.
- ⏰ **Scheduler** — turn the VPN on/off and refresh the subscription on a daily timetable
  (rendered into a marked block in the root crontab).
- 🧪 **Diagnostics** — service state, coexistence with podkop/zapret, WAN and direct
  egress IP/country, SRS rule-set cache, resources, the last 40 log lines, and a real
  **"test exit via VPN"** check that tries several IP-echo endpoints (one blocking a
  datacenter exit can't produce a false failure).
- 💾 **Backup / restore** of the whole configuration from the Settings tab.

### The LuCI app: five tabs

Auto **RU/EN** interface (by browser language), mobile-friendly, 5 s polling on the
dashboard:

| Tab | What's on it |
|---|---|
| **Dashboard** | On/off, active node, traffic and connections, subscription expiry + data quota bar, ping-all, import/export, search/sort/filter, the node table (AUTO row + ⚙ auto-pool, 📌 preferred, ⭐ save, 🔗 link+QR, unlock badges, speed), bulk selection and delete, "Saved (inactive)", "Out of the auto-pool", per-client traffic |
| **Sources** | Main subscription + auto-update interval, extra subscriptions, source probing with a pick-nodes modal, manual nodes and bulk import, **AmneziaWG nodes** (when the AWG fork is installed), saved-node archive |
| **Routing** | Routing mode, 26 community lists, custom domains, per-client mode with the DHCP device picker and extra IPv4 addresses |
| **Settings** | Failover interval/tolerance/auto-switch, node check (services, dead-filter, strikes, retries), kill-switch and DNS guard, anti-DPI and adaptive routing, auto-snapshot, schedule, Telegram, backup/restore, read-only technical values |
| **Diagnostics** | Service, coexistence, network and direct egress, VPN-exit test, rule-set cache, resources, recent logs |

---

## 📸 Screenshots

| Dashboard — live node pings, active node, traffic | Sources — subscriptions, manual and AmneziaWG nodes |
|---|---|
| ![vpnpool Dashboard tab in LuCI: node list with live pings and the active node](docs/screenshots/dashboard.jpg) | ![vpnpool Sources tab: subscription URL, extra sources, manual nodes](docs/screenshots/sources.jpg) |
| **Routing — selective mode, community lists, per-client** | **Settings — failover, node check, Telegram** |
| ![vpnpool Routing tab: selective routing, community domain lists, per-client rules](docs/screenshots/routing.jpg) | ![vpnpool Settings tab: failover, service check, anti-DPI, Telegram](docs/screenshots/settings.jpg) |

---

## 🧰 Supported & recommended hardware

vpnpool itself is tiny and **architecture-independent**. The real requirement is
**sing-box**, a ~38 MB binary.

- **Minimum:** any router on **OpenWrt 23.05 / 24.10** with **≥ 128 MB RAM** and room for
  sing-box (~38 MB). Routers with **16 MB flash** can still run it — see
  [Routers with small flash](#-routers-with-small-flash-16-mb) to install sing-box into RAM.
- **Recommended:** **≥ 256 MB flash** (or USB/extroot) and **≥ 512 MB RAM**, e.g.:
  - **Cudy TR3000**, **GL.iNet** Flint / Beryl, any **MediaTek Filogic** (MT7981/MT7986),
  - **Qualcomm IPQ807x** boards,
  - **x86 / x86_64** mini-PC or VM,
  - **Raspberry Pi 4** running OpenWrt.
- **AmneziaWG** additionally needs the AWG sing-box fork, prebuilt for **aarch64** and
  **mipsel** only (other architectures keep the stock binary and hide the AWG UI).

> **Architecture note:** our two packages ship as `_all` (one file works on **every**
> CPU). Architecture only matters for the *dependencies* (sing-box, kmods), which opkg
> pulls from the standard OpenWrt feeds for **your** device automatically. Check yours
> with `opkg print-architecture`.

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

Installs (or upgrades) the latest release: prebuilt packages from GitHub Releases,
dependencies from the standard OpenWrt feeds. Your `/etc/config/vpnpool` (subscription,
Telegram, routing) is preserved on upgrade.

**Standard** — VLESS / VMess / Trojan / Shadowsocks on stock sing-box:

```sh
sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

**With AmneziaWG** — additionally replaces sing-box with the AmneziaWG fork
([hoaxisr/amnezia-box](https://github.com/hoaxisr/amnezia-box); the binary is checked
against the release's `checksums.txt`, and the installer warns if that file can't be
fetched) and pins it with `opkg flag hold` so an `opkg upgrade` can't silently swap it
back:

```sh
VPNPOOL_AWG=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

If your BusyBox `wget` doesn't support `<(...)`, fetch first, then run (prefix the same
env var for the AmneziaWG variant):

```sh
wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh
sh /tmp/vpnpool-install.sh
```

**Installer environment variables:**

| Variable | Effect |
|---|---|
| `VPNPOOL_AWG=1` | Use the AmneziaWG sing-box fork instead of stock (aarch64 / mipsel prebuilds; other architectures keep stock with a warning) |
| `VPNPOOL_RAM_SINGBOX=1` | 16 MB-flash mode: install sing-box into RAM on every boot (see below) |
| `VPNPOOL_VERSION=v1.4.3` | Install a specific release tag instead of `latest` |

> ⚠ **podkop shares `/usr/bin/sing-box`.** If podkop is installed, the AWG variant makes
> it run on the fork too. It works, but it is a shared binary — keep it in mind when
> debugging either package.

> The installer retries downloads four times and falls back to the
> [GitHub Pages mirror](https://roman-png.github.io/VPNpool) when installing `latest`.

### Option B — prebuilt `.ipk` from Releases

Our packages are arch-independent `_all` files — **the same two files work on any router**:

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

The [GitHub Pages opkg feed](https://roman-png.github.io/VPNpool) is **signed** with our
usign key (fingerprint `807479500e0ce219`). Install the public key once, then add the feed
and install/upgrade like any package — **signature checking stays on**:

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

If you don't install the key, opkg rejects the (to it) unsigned feed and drops the package
list. You can instead disable opkg's signature check — but that turns verification **off
for every feed, including the official OpenWrt ones**, so the key method above is
preferred.

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

CI builds the same packages for `aarch64_cortex-a53`, `x86_64` and `mipsel_24kc` on every
push and attaches them to releases.

---

## 📟 Routers with small flash (16 MB)

sing-box (~38 MB) does not fit in 16 MB of flash, but our packages do (~128 KB). The trick
(the same idea podkop uses): keep vpnpool in flash and **(re)install sing-box into RAM
(`/tmp`) on every boot**, triggered when the WAN interface comes up. OpenWrt already
defines a RAM destination in `/etc/opkg.conf` (`dest ram /tmp`), so `opkg install -d ram …`
lands the binary under `/tmp`.

### One-liner (16 MB flash)

```sh
VPNPOOL_RAM_SINGBOX=1 sh <(wget -O - https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh)
```

…or, if your `wget` lacks process substitution:

```sh
wget -O /tmp/vpnpool-install.sh https://raw.githubusercontent.com/roman-png/VPNpool/main/install.sh && VPNPOOL_RAM_SINGBOX=1 sh /tmp/vpnpool-install.sh
```

It installs zram-swap and the lightweight dependencies, installs our packages with
`--nodeps` (no sing-box in flash), disables autostart, writes the WAN-up boot hook, and
installs sing-box into RAM right away. Then set your subscription in
**LuCI → Services → VPN Pool** and run `/etc/init.d/vpnpool start`. On every reboot the
hook reinstalls sing-box into RAM and starts vpnpool automatically. If your WAN isn't
named `wan`, edit `INTERFACE` in `/etc/hotplug.d/iface/99-vpnpool-singbox-ram`.

> **Updating on small flash:** re-run the same one-liner. Do **not** use `opkg upgrade`
> here — it resolves the `sing-box` dependency against flash and would try to pull the
> ~38 MB binary into ROM (the install deliberately uses `--nodeps` to avoid that).

> **AmneziaWG on small flash:** `VPNPOOL_AWG=1` combines with `VPNPOOL_RAM_SINGBOX=1` —
> the WAN-up hook then fetches the AWG fork into RAM (sha256-checked) and **falls back to
> the stock sing-box from the feed** if the download or the checksum fails, so the router
> still comes up with a working tunnel.

<details>
<summary>Manual steps (what the one-liner does under the hood)</summary>

**1. Install zram-swap** (gives the small router more usable memory for `opkg`):

```sh
opkg update
opkg install zram-swap
/etc/init.d/zram enable
/etc/init.d/zram start
```

**2. Install vpnpool itself, but WITHOUT sing-box** (it won't fit in flash). Install the
small dependencies normally, then our packages with `--nodeps`:

```sh
opkg update
opkg install jq curl ucode ucode-mod-fs ucode-mod-uci kmod-nft-tproxy ip-full luci-base ca-bundle
# get the two _all .ipk (release page or install.sh's download step), then:
opkg install --nodeps ./vpnpool_*_all.ipk ./luci-app-vpnpool_*_all.ipk
```

**3. Do NOT autostart vpnpool at boot** — sing-box won't exist yet. The hotplug hook below
starts it after sing-box is in place:

```sh
/etc/init.d/vpnpool disable
```

**4. Create the boot hook** that installs sing-box into RAM and starts vpnpool when the
WAN comes up (runs on every reboot, needs internet):

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

</details>

> **Trade-offs:** sing-box (~14 MB ipk) is re-downloaded into RAM on every boot, so the
> router needs working internet at startup and enough free RAM (~128 MB+).
>
> **Tested on:** Xiaomi Mi Router 4A Gigabit (MediaTek MT7621, 16 MB flash / 128 MB RAM,
> OpenWrt 24.10) — fresh one-liner install, reboot, and live VPN exit all OK.
>
> **Keep a single boot hook.** Only one WAN-up hook may install sing-box into RAM. Two
> hooks racing `opkg install -d ram sing-box` on a 128 MB router OOM each other and
> corrupt the binary (symptom: `sing-box: Bus error` / `Permission denied`). The one-liner
> removes stale `*vpnpool*` iface hooks before writing its own — just don't add a second
> one by hand.

---

## ⚙️ Quick start

1. **Sources** tab → paste your subscription URL → **Update now**.
2. **Settings → Node check** → list the services that must really work (default:
   `www.youtube.com`). This is what "a working node" means for the whole stack.
3. **Routing** tab → pick the mode (proxy selected / proxy all-except) → choose community
   lists and/or add domains.
4. **Dashboard** → **Turn ON**. Watch live pings; the green ★ is the active node. Use
   **⚙ Configure** on the AUTO row to choose which nodes may be auto-picked.
5. **Diagnostics** → **Test exit via VPN** to confirm your real exit IP and country.

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
                                  │ fetch (multi-UA) → parse → build → sing-box check
                                  │ service check (Clash delay API) → dead/alive sets
                                  ▼
                          sing-box (the engine)
   inbound : tproxy 127.0.0.1:1603  +  local mixed SOCKS/HTTP :1605 (tests, bot, apps)
   outbound: urltest "auto" (ping + failover) + selector + nodes + direct
   endpoints[]: AmneziaWG / WireGuard peers (sing-box >= 1.13)
   route   : sniff SNI → community SRS / domains → proxy (or direct in exclude mode)
                                  ▲
   nftables (table inet vpnpool): mark LAN 80/443 → fwmark 0x400000 → table 142 →
   tproxy; yields to podkop; IPv6 fail-closed; per-client include/exclude
                                  ▲
   fail-safe: routing goes up ONLY after an end-to-end probe succeeds; otherwise the
   LAN stays on a direct connection and is retried every 15 s
```

The control plane (subscription, parsing, config generation, health checks, watchdog, UI)
is ours; the data plane is **sing-box** — exactly like v2RayTun/Happ wrap an engine.

Routing is done by **SNI sniffing**, so no DNS games, no fake-IP pool and no dnsmasq
takeover are needed.

---

## ⚙️ Configuration reference (uci)

Everything the UI does is plain `uci` in `/etc/config/vpnpool` (section
`config vpnpool 'main'`), so the app is fully scriptable.

<details>
<summary><b>All options with defaults</b></summary>

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `0` | Start the daemon (the LuCI on/off switch) |
| `mode` | `selective` | `selective` = proxy only the lists; `exclude` = proxy everything except them |
| `subscription_url` | — | Main subscription (quota/expiry come from this one) |
| `subscription_interval` | `6h` | Auto-refresh period |
| `check_services` | `www.youtube.com` | **The** criterion of a working node (one host per line); drives urltest, failover, dead-filter and watchdog |
| `health_url` | `http://cp.cloudflare.com/generate_204` | Fallback probe when `check_services` is empty |
| `failover_interval` | `60` | urltest interval, seconds |
| `failover_tolerance` | `50` | urltest tolerance, ms |
| `auto_switch` | `1` | 0 pins the selector to the first node instead of `auto` |
| `selected_node` / `preferred_node` | — | Hard manual pick / soft 📌 pin with switch-back |
| `dead_filter` | `1` | End-to-end service filter for the auto-pool |
| `dead_filter_strikes` | `3` | Consecutive failed cycles before a node is demoted |
| `dead_filter_tries` | `3` | Retries per service inside one cycle |
| `ipv6` | `block` | `block` = fail-closed IPv6 leak guard; `off` = don't touch IPv6 |
| `killswitch` | `0` | Fail-closed IPv4 in `exclude` mode |
| `dns_protect` | `0` | Send LAN port 53 through the tunnel |
| `client_mode` | `all` | `all` / `exclude` / `include` per-client routing |
| `antidpi` | `off` | `off` / `on` (`tls_fragment`) / `aggressive` (+ `tls_record_fragment`) |
| `adaptive_routing` | `0` | Auto-detect direct-blocked domains and route them |
| `adaptive_max_per_run` | `8` | Cap of new domains per adaptive scan |
| `auto_snapshot` / `auto_snapshot_max` | `0` / `20` | Auto-save a bounded set of reachable nodes |
| `sched_enabled`, `sched_on`, `sched_off`, `sched_refresh` | `0`, — | Daily on/off/refresh timetable (HH:MM) |
| `telegram_enabled`, `telegram_token`, `telegram_chat` | `0`, — | Alerts |
| `telegram_control` | `0` | Two-way bot (its own procd instance) |
| `telegram_via_proxy` | `1` | Reach Telegram through the tunnel |
| `speedtest_url` | Cloudflare `__down?bytes=10000000` | Speed-test target |
| `speedtest_min_mem_kb` | `8192` | Free-memory guard for speed/unlock tests |
| `dns_strategy` | `prefer_ipv4` | Resolution strategy for sing-box probes |
| `fwmark` / `route_table` / `route_priority` | `0x400000` / `142` / `106` | Non-colliding routing resources |
| `tproxy_port` / `test_port` / `clash_api` | `1603` / `1605` / `127.0.0.1:9091` | Inbounds and control API |
| `lan_if` | auto | LAN device (autodetected via ubus, then `br-lan`) |
| `coexist` | `auto` | Yield traffic already marked by podkop |
| `log_level` | `warn` | sing-box log level |

Lists maintained by the app: `source`, `extra_sub`, `manual_node`, `imported_node`,
`saved_node`, `active_saved`, `excluded_node`, `auto_member`, `keep_auto`, `client`,
`client_dev`, `probe_ua`. Section `config routing 'routing'` holds `community`, `domain`
and `auto_domain` lists. AmneziaWG nodes are files: `/etc/vpnpool/awg/*.conf`.

</details>

---

## 🆚 Compared to podkop / passwall / homeproxy

| | **vpnpool** | podkop | passwall2 | homeproxy |
|---|---|---|---|---|
| Engine | sing-box | sing-box | xray/sing-box | sing-box |
| Auto-updating subscription | ✅ multi-source, multi-UA | partial | ✅ | ✅ |
| **Auto ping + failover** | ✅ urltest + watchdog | manual select | ✅ | ✅ |
| **Node check by real services** | ✅ your service list is the criterion | — | ping only | ping only |
| **Fail-safe routing (never route into a dead tunnel)** | ✅ | — | — | — |
| **Preferred node + switch-back** | ✅ | — | — | — |
| **Pick which nodes auto-switch** | ✅ | — | — | — |
| **AmneziaWG nodes in the same pool** | ✅ (`.conf` + `vpn://`) | — | — | — |
| **Subscription data quota** | ✅ used/total + bar | — | — | — |
| **Saved nodes (survive expiry)** | ✅ | — | — | — |
| **Per-node speed test** | ✅ throughput | — | — | — |
| **Per-node unlock test (YT/AI/NF…)** | ✅ | — | — | — |
| **Per-node & per-client stats** | ✅ live | — | partial | partial |
| **On/off + refresh scheduler** | ✅ | — | — | — |
| **Share link + offline QR / export** | ✅ | — | — | — |
| **Multiple full subscriptions** | ✅ | — | partial | ✅ |
| **Two-way Telegram control bot** | ✅ tunnelled, inline menu | — | — | — |
| **Adaptive routing (auto-detect blocks)** | ✅ | — | — | — |
| **Anti-DPI TLS fragmentation** | ✅ off/on/aggressive | — | — | — |
| **Kill-switch + DNS-leak guard** | ✅ opt-in | partial | ✅ | partial |
| Community SRS lists | ✅ 26 (itdoginfo) | ✅ | own | own |
| Per-client routing | ✅ by DHCP name/MAC | — | ✅ | partial |
| VPN-exit self-test | ✅ multi-endpoint | ✅ | partial | — |
| Coexists with podkop | ✅ by design | n/a | — | — |
| Auto RU/EN UI | ✅ | RU/EN | RU/EN | EN/ZH |

---

## ❓ FAQ

**Is this a VPN provider?** No. vpnpool is a *client* control plane: you bring your own
VLESS/Reality subscription, your own server or an AmneziaWG config.

**How is it different from podkop?** podkop is excellent at *selective routing* but you
pick the node yourself. vpnpool keeps the whole subscription as a pool, verifies nodes
against real services, and switches automatically. They coexist on one router by design.

**Do I need to replace my sing-box?** Only for AmneziaWG. Everything else runs on the
stock `sing-box` package from the OpenWrt feeds.

**Why don't I see the AmneziaWG section?** Because the running sing-box has no AWG
support. Reinstall with `VPNPOOL_AWG=1` (aarch64 / mipsel prebuilds available); the UI
appears once the fork is detected.

**Can I use an AmneziaVPN `vpn://` link directly?** Yes — paste it on the Sources tab.
It is decoded on the router itself; you don't need the Amnezia app.

**My subscription has 200 nodes. Will a cheap router survive?** Yes. Unreachable hosts are
TCP-prefiltered out of the pool, service probes run sequentially (not in parallel — that
saturates sing-box on tiny routers), and heavy tests have a free-memory guard.

**What happens if the subscription expires or every node dies?** The LAN keeps working on
a direct connection: routing is never brought up against a tunnel that fails the
end-to-end probe, and it goes up on its own within 15 s of a node becoming reachable.

**Does it work on a 16 MB router?** Yes, with `VPNPOOL_RAM_SINGBOX=1` — sing-box lives in
RAM and is reinstalled on every boot.

**Will it break my ISP-blocked-site setup with zapret?** No. vpnpool uses its own fwmark,
routing table, nft table and ports, yields to podkop-marked traffic, and shows both in
Diagnostics. It does **not** manage or bundle zapret (that orchestration was removed in
1.2.0 — vpnpool is a proxy control plane, zapret is a separate direct-DPI tool).

**Can I control it without LuCI?** Yes — everything is `uci` plus the Telegram bot
(`/menu` gives buttons for node switching, speed tests and routing on/off).

---

## 🔧 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Log says *"keeping LAN on DIRECT"*, no traffic through VPN | No node passed the end-to-end service check. Check the subscription (expired? empty?) and *Settings → Node check*; routing rises automatically when a node answers |
| Everything pings, but sites don't open | The node reaches a CDN but not your services. That's exactly what the service check demotes — look at **"Out of the auto-pool"** |
| The AmneziaWG section is missing | Stock sing-box; install with `VPNPOOL_AWG=1` |
| `sing-box: Bus error` after reboot on 16 MB | Two WAN-up hooks raced to install sing-box into RAM; keep exactly one |
| Community lists don't download | The SRS assets come from GitHub Releases. If GitHub is blocked, route it through the proxy first |
| Node list looks stale after removing podkop | Restore dnsmasq's normal upstream — podkop points it at its own `127.0.0.42` fake-IP resolver |
| Bot answers every other message | Only one poller may run. It is a separate procd instance now; make sure no manual copy of `tgbot.sh` is running |

Useful commands:

```sh
logread -e vpnpool                 # service log
uci show vpnpool                   # current configuration
/etc/init.d/vpnpool restart        # full restart
kill -USR1 $(cat /var/run/vpnpool.pid)   # rebuild config from cache (hot)
kill -USR2 $(cat /var/run/vpnpool.pid)   # refetch subscription + rebuild
```

---

## 🔐 Limitations and notes

- **ECH / encrypted SNI** can't be classified by SNI sniffing — such domains follow the
  default path for your routing mode.
- **Anti-DPI here is TLS fragmentation only.** It defeats basic filtering, not TSPU-class
  DPI; use zapret alongside for that.
- **Security:** the Clash API listens on `127.0.0.1` only; node secrets never leave the
  router (QR codes are rendered in the browser from data the router already has).
- **AmneziaWG needs a forked sing-box**, which podkop would then share.

## 🗺️ Roadmap

- Near-instant active-probe failover (below the urltest interval)
- Full sing-box DNS/FakeIP with DoH-over-proxy for fully leak-free selective routing
  (the current DNS guard covers LAN clients that query public resolvers directly)
- Full IPv6 tproxy (proxy mode, not just block)
- Clash YAML subscription parsing
- Multi-hop / chain proxy (entry in one country, exit in another)
- AmneziaWG prebuilds for more architectures

## 🛠️ Development

The whole thing is ucode + shell + a little LuCI JS — no compilation needed.

- `package/vpnpool/files/usr/libexec/vpnpool/` — daemon, parser, generator, health checks
- `package/luci-app-vpnpool/files/www/luci-static/resources/view/vpnpool/` — the five tabs
- `stand/` — a Docker debug stand (real OpenWrt rootfs, uci/ubus/ucode + sing-box) that
  mounts the shipped files read-only, so you can run the daemon off-router
- `scripts/deploy.sh` — deploy the package tree to a router over SSH (optional jump host)
- `tools/router-smoke-test.sh` — read-only, non-destructive verification on a live router

Issues and PRs welcome.

## 📄 License

[GPL-3.0-only](LICENSE) © 2026 roman-png

---

<sub>**Keywords:** OpenWrt VLESS, VLESS Reality OpenWrt, sing-box subscription manager,
sing-box failover, auto switch VPN router, v2RayTun for router, Happ for router, podkop
alternative, passwall alternative, homeproxy alternative, vless vmess trojan shadowsocks
subscription, xtls-rprx-vision reality, urltest auto failover, AmneziaWG OpenWrt,
AmneziaWG router, amnezia vpn:// config, WireGuard obfuscation OpenWrt, tproxy selective
routing, kill switch OpenWrt VPN, Telegram bot router VPN, обход блокировок роутер
OpenWrt, автопереключение VLESS, подписка VLESS на роутер, антизапрет sing-box,
AmneziaWG на роутер.</sub>
