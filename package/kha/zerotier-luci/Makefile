include $(TOPDIR)/rules.mk

PKG_NAME:=zerotier-luci
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/zerotier-luci
  SECTION:=utils
  CATEGORY:=KHA
  TITLE:=LuCI page for ZeroTier (VPN > ZeroTier)
  DEPENDS:=+zerotier +rpcd +rpcd-mod-ucode +ucode-mod-uci +ucode-mod-ubus \
	+ucode-mod-fs +luci-base
  PKGARCH:=all
endef

define Package/zerotier-luci/description
 LuCI "VPN > ZeroTier" page: node address and online state, joined
 networks with their assigned addresses and interfaces, peers, start /
 stop / restart, and an editor for /etc/config/zerotier (enable, port,
 networks to join and their allow* flags). Backed by the rpcd ucode
 plugin luci.zerotier. The upstream LuCI feed has no ZeroTier app.
 Part of both image variants (config.seed).
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/zerotier-luci/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
endef

define Package/zerotier-luci/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,zerotier-luci))
