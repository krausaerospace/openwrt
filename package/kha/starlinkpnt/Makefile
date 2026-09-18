include $(TOPDIR)/rules.mk

PKG_NAME:=starlinkpnt
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

# Payload is scripts + prebuilt musllinux wheels: never strip/patch anything.
RSTRIP:=:
STRIP:=:

define Package/starlinkpnt
  SECTION:=utils
  CATEGORY:=KHA
  TITLE:=Starlink->MAVLink position bridge with LuCI page
  DEPENDS:=@TARGET_bcm27xx @aarch64 +python3 +python3-pip +rpcd +rpcd-mod-ucode \
	+ucode-mod-uci +ucode-mod-ubus +ucode-mod-fs +luci-base
endef
# NOTE: no PKGARCH:=all -- the bundled wheels are aarch64 musllinux binaries.

define Package/starlinkpnt/description
 Starlink dish position -> MAVLink bridge (/root/starlinkpnt), its procd
 service, uci config, starlink-* helpers, offline wheelhouse, the LuCI
 "Starlink PNT" page and the /root/status.sh section. Selected only by the
 "pnt" image variant (config-pnt.seed).
endef

define Package/starlinkpnt/conffiles
/etc/config/starlink_mavlink
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

# Files that must be 0755 on the device; everything else is 0644, dirs 0755.
STARLINKPNT_EXEC:= \
	/etc/init.d/starlink_mavlink \
	/etc/uci-defaults/98-starlink-legacy-net \
	/etc/uci-defaults/99-starlink-mavlink \
	/usr/sbin/starlink-install-deps \
	/usr/sbin/starlink-start \
	/usr/sbin/starlink-stop \
	/usr/sbin/starlink-gps-aux \
	/root/starlinkpnt/starlink_mavlink.py

define Package/starlinkpnt/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	find $(1) -type d -name __pycache__ -prune -exec rm -rf {} +
	find $(1) -type f -name '*.pyc' -delete
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(addprefix $(1),$(STARLINKPNT_EXEC))
endef

define Package/starlinkpnt/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,starlinkpnt))
