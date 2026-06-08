# SPDX-License-Identifier: GPL-2.0-only
# OpenWrt package: vpnpool — VLESS/Reality subscription manager with auto-failover
include $(TOPDIR)/rules.mk

PKG_NAME:=vpnpool
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=roman-png
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/vpnpool
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=VLESS/Reality subscription manager with auto-failover (sing-box control plane)
  URL:=https://github.com/roman-png/VPNpool
  DEPENDS:=+sing-box +jq +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +ip-full
  PKGARCH:=all
endef

define Package/vpnpool/description
  vpnpool is a control plane over sing-box for OpenWrt: an auto-updating subscription
  (base64 / sing-box JSON, multi-source, multi-client User-Agent probing) plus manual
  VLESS/VMess/Trojan/Shadowsocks nodes, automatic ping (urltest) and failover to a
  working node, whole-LAN or per-client selective routing (community SRS lists +
  custom domains, include/exclude modes), an IPv6 leak guard, and Telegram alerts.
  Coexists with podkop/zapret. Configure via LuCI (luci-app-vpnpool) or uci.
endef

define Package/vpnpool/conffiles
/etc/config/vpnpool
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/vpnpool/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/etc/init.d/vpnpool
	chmod 0755 $(1)/usr/libexec/vpnpool/*
endef

define Package/vpnpool/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	mkdir -p /etc/vpnpool
	/etc/init.d/vpnpool enable >/dev/null 2>&1
}
exit 0
endef

define Package/vpnpool/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/vpnpool stop >/dev/null 2>&1
	/etc/init.d/vpnpool disable >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,vpnpool))
