# SPDX-License-Identifier: GPL-2.0-only
# OpenWrt package: luci-app-vpnpool — LuCI dashboard for vpnpool
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vpnpool
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=roman-png
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vpnpool
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI dashboard for VPN Pool (vpnpool)
  URL:=https://github.com/roman-png/VPNpool
  DEPENDS:=+vpnpool +luci-base
  PKGARCH:=all
endef

define Package/luci-app-vpnpool/description
  Five-tab LuCI web UI for vpnpool: Dashboard (status, live node pings, traffic, manual
  ping/select, on/off), Sources (subscription + extra sources + manual nodes), Routing
  (selective/exclude modes, community SRS lists, custom domains, per-client routing),
  Settings (failover, Telegram alerts, backup/restore) and Diagnostics (service state,
  coexistence, VPN-exit test, logs). Auto RU/EN UI.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/luci-app-vpnpool/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/usr/libexec/rpcd/vpnpool
endef

define Package/luci-app-vpnpool/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-vpnpool))
