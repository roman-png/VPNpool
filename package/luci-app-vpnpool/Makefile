# SPDX-License-Identifier: GPL-3.0-only
# OpenWrt package: luci-app-vpnpool — LuCI dashboard for vpnpool
#
# Built with LuCI's luci.mk (from the luci feed), so the translations in po/<lang>/vpnpool.po
# become the standard packages luci-i18n-vpnpool-<lang> (po2lmo -> /usr/lib/lua/luci/i18n/
# vpnpool.<lang>.lmo). po/templates/vpnpool.pot and po/ru/vpnpool.po are kept in sync with
# the sources by stand/tests/ui-i18n.sh.
#
# Our files live in files/ (not luci.mk's htdocs/ + root/ layout), so the install recipe is
# our own: it is declared `override` BEFORE luci.mk, whose own (non-override) definition of
# Package/luci-app-vpnpool/install is then ignored by make. Our postinst is kept by luci.mk
# (it only defines one when none exists).
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vpnpool
PKG_VERSION:=1.5.0
PKG_RELEASE:=1
PKG_MAINTAINER:=roman-png
PKG_LICENSE:=GPL-3.0-only

LUCI_TITLE:=LuCI dashboard for VPN Pool (vpnpool)
LUCI_DEPENDS:=+vpnpool +luci-base
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/roman-png/VPNpool
LUCI_MAINTAINER:=roman-png

define Package/luci-app-vpnpool/description
  Five-tab LuCI web UI for vpnpool: Overview (status, traffic and per-client stats),
  Nodes (one "Add" for links, subscription addresses, AmneziaWG settings, files and QR
  pictures with a check of every line; groups by subscription with expiry, quota and
  "updated"; Connect / back to automatic choice; favourites, hidden nodes, speed and
  service tests, share link with offline QR, export, bulk actions), Routes (selective/exclude modes, community SRS lists, custom domains, per-client
  routing by DHCP name/MAC), Settings (failover, service-based node check, kill-switch
  and DNS guard, anti-DPI, adaptive routing, schedule, Telegram, backup/restore) and
  Diagnostics (service state, coexistence, VPN-exit test, logs). Translations come as
  luci-i18n-vpnpool-<lang>; the language follows the LuCI setting.
endef

override define Package/luci-app-vpnpool/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	# view/vpnpool/_*.js = stand-only pages (component showcase), not for routers
	rm -f $(1)/www/luci-static/resources/view/vpnpool/_*.js
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

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
